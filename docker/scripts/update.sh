#!/bin/bash
source /utils/logging.sh

# Путь к базовым файлам и файлам в контейнере
BASE_FILES="/mnt"
CONTAINER_FILES="/home/container"

# Directories
GAME_DIRECTORY="./game/csgo"
OUTPUT_DIR="./game/csgo/addons"
TEMP_DIR="./temps"
ACCELERATOR_DUMPS_DIR="$OUTPUT_DIR/AcceleratorCS2/dumps"
VERSION_FILE="./game/versions.txt"

copy_bin() {
    log_message "Копирование папки game/bin из $BASE_FILES/game/bin в $CONTAINER_FILES/game/bin с заменой..." "running"
    # Убедиться, что папка назначения существует
    mkdir -p "$CONTAINER_FILES/game/bin"
    # Копировать содержимое с заменой
    rsync -a --delete "$BASE_FILES/game/bin/" "$CONTAINER_FILES/game/bin/"
    log_message "Копирование папки bin завершено." "success"
}

copy_cfg() {
    log_message "Копирование файлов game/csgo/cfg из $BASE_FILES/game/csgo/cfg в $CONTAINER_FILES/game/csgo/cfg..." "running"
    
    # Убедиться, что папка назначения существует
    mkdir -p "$CONTAINER_FILES/game/csgo/cfg"

    # Копировать только недостающие файлы и папки
    rsync -av --ignore-existing "$BASE_FILES/game/csgo/cfg/" "$CONTAINER_FILES/game/csgo/cfg/"

    # Проверить, завершилось ли копирование успешно
    if [[ $? -eq 0 ]]; then
        log_message "Копирование файлов из game/csgo/cfg завершено." "success"
    else
        log_message "Ошибка при копировании файлов из game/csgo/cfg." "error"
    fi
}

# Функция для создания символических ссылок
create_symlinks() {
    log_message "Создание символических ссылок из $BASE_FILES в $CONTAINER_FILES..." "running"
    find "$BASE_FILES" -type f | while read -r file; do
        # Пропустить папку bin, так как она копируется отдельно
        if [[ $file == "$BASE_FILES/game/bin/"* || $file == "$BASE_FILES/game/csgo/cfg/*" ]]; then
            continue
        fi

        # Путь к файлу относительно BASE_FILES
        relative_path="${file#$BASE_FILES/}"
        # Путь к символической ссылке
        symlink_path="$CONTAINER_FILES/$relative_path"

        # Создать все необходимые поддиректории
        mkdir -p "$(dirname "$symlink_path")"

        # Попытка создания символической ссылки
        if [ ! -L "$symlink_path" ]; then
            ln -s "$file" "$symlink_path" && {
                log_message "Создана ссылка: $symlink_path -> $file" "running"
            } || {
                log_message "Не удалось создать ссылку: $symlink_path -> $file. Попытка удаления существующего файла или ссылки." "warning"
                # Удаление существующего файла или ссылки
                if [ -e "$symlink_path" ]; then
                    rm -f "$symlink_path" && {
                        log_message "Удалён существующий файл или ссылка: $symlink_path" "running"
                        # Повторная попытка создания символической ссылки
                        ln -s "$file" "$symlink_path" && {
                            log_message "Создана ссылка (повторно): $symlink_path -> $file" "success"
                        } || {
                            log_message "Повторное создание ссылки не удалось: $symlink_path -> $file" "error"
                        }
                    } || {
                        log_message "Не удалось удалить существующий файл или ссылку: $symlink_path" "error"
                    }
                else
                    log_message "Файл или ссылка отсутствуют, но создание ссылки всё равно не удалось: $symlink_path -> $file" "error"
                fi
            }
        fi
    done
}

# Функция для удаления устаревших символических ссылок
remove_stale_symlinks() {
    log_message "Проверка и удаление устаревших символических ссылок в $CONTAINER_FILES..." "running"
    find "$CONTAINER_FILES" -type l | while read -r symlink; do
        # Проверить, существует ли целевой файл
        if [ ! -e "$symlink" ]; then
            rm "$symlink" && {
                log_message "Удалена устаревшая ссылка: $symlink" "running"
            } || {
                log_message "Не удалось удалить устаревшую ссылку: $symlink" "error"
                exit 1
            }
        fi
    done
}

get_current_version() {
    local addon="$1"
    if [ -f "$VERSION_FILE" ]; then
        grep "^$addon=" "$VERSION_FILE" | cut -d'=' -f2
    else
        echo ""
    fi
}

update_version_file() {
    local addon="$1"
    local new_version="$2"
    if grep -q "^$addon=" "$VERSION_FILE"; then
        sed -i "s/^$addon=.*/$addon=$new_version/" "$VERSION_FILE"
    else
        echo "$addon=$new_version" >> "$VERSION_FILE"
    fi
}

# Centralized download and extract function
handle_download_and_extract() {
    local url="$1"
    local output_file="$2"
    local extract_dir="$3"
    local file_type="$4"  # "zip" or "tar.gz"

    log_message "Downloading from: $url" "debug"

    # Download with timeout and retry
    local max_retries=3
    local retry=0
    while [ $retry -lt $max_retries ]; do
        if curl -fsSL -m 300 -o "$output_file" "$url"; then
            break
        fi
        ((retry++))
        log_message "Download attempt $retry failed, retrying..." "error"
        sleep 5
    done

    if [ $retry -eq $max_retries ]; then
        log_message "Failed to download after $max_retries attempts" "error"
        return 1
    fi

    if [ ! -s "$output_file" ]; then
        log_message "Downloaded file is empty" "error"
        return 1
    fi

    log_message "Extracting to $extract_dir" "debug"
    mkdir -p "$extract_dir"

    case $file_type in
        "zip")
            unzip -qq -o "$output_file" -d "$extract_dir" || {
                log_message "Failed to extract zip file" "error"
                return 1
            }
            ;;
        "tar.gz")
            tar -xzf "$output_file" -C "$extract_dir" || {
                log_message "Failed to extract tar.gz file" "error"
                return 1
            }
            ;;
    esac

    return 0
}

# Centralized version checking
check_version() {
    local addon="$1"
    local current="${2:-none}"
    local new="$3"

    if [ "$current" != "$new" ]; then
        log_message "New version of $addon available: $new (current: $current)" "running"
        return 0
    fi

    log_message "No new version of $addon available. Current: $current" "suceess"
    return 1
}

cleanup_and_update() {
    if [ "${CLEANUP_ENABLED:-0}" = "1" ]; then
        cleanup
    fi

    mkdir -p "$TEMP_DIR"

    if [ "${METAMOD_AUTOUPDATE:-0}" = "1" ] || ([ ! -d "$OUTPUT_DIR/metamod" ] && [ "${CSS_AUTOUPDATE:-0}" = "1" ]); then
        update_metamod
    fi

    if [ "${CSS_AUTOUPDATE:-0}" = "1" ]; then
        update_addon "roflmuffin/CounterStrikeSharp" "$OUTPUT_DIR" "css" "CSS"
    fi

    # Update the server configuration file if required
    if [ "${UPDATE_CFG_FILE:-0}" = "1" ]; then
        update_server_cfg
    fi

    # Clean up
    rm -rf "$TEMP_DIR"
}

update_addon() {
    local repo="$1"
    local output_path="$2"
    local temp_subdir="$3"
    local addon_name="$4"
    local temp_dir="$TEMP_DIR/$temp_subdir"

    mkdir -p "$output_path" "$temp_dir"
    rm -rf "$temp_dir"/*

    local api_response=$(curl -s "https://api.github.com/repos/$repo/releases/latest")
    if [ -z "$api_response" ]; then
        log_message "Failed to get release info for $repo" "error"
        return 1
    fi

    local asset_url=$(echo "$api_response" | grep -oP '"browser_download_url": "\K[^"]+' | grep 'counterstrikesharp-with-runtime-build-.*-linux-.*\.zip')
    local new_version=$(echo "$api_response" | grep -oP '"tag_name": "\K[^"]+')
    local current_version=$(get_current_version "$addon_name")

    if ! check_version "$addon_name" "$current_version" "$new_version"; then
        return 0
    fi

    if [ -z "$asset_url" ]; then
        log_message "No suitable asset found for $repo" "error"
        return 1
    fi

    if handle_download_and_extract "$asset_url" "$temp_dir/download.zip" "$temp_dir" "zip"; then
        cp -r "$temp_dir/addons/." "$output_path" && \
        update_version_file "$addon_name" "$new_version" && \
        log_message "Update of $repo completed successfully" "success"
        return 0
    fi

    return 1
}

update_metamod() {
    if [ ! -d "$OUTPUT_DIR/metamod" ]; then
        log_message "Metamod not installed. Installing Metamod..." "running"
    fi

    local metamod_version=$(curl -sL https://mms.alliedmods.net/mmsdrop/2.0/ | grep -oP 'href="\K(mmsource-[^"]*-linux\.tar\.gz)' | tail -1)
    if [ -z "$metamod_version" ]; then
        log_message "Failed to fetch the Metamod version" "error"
        return 1
    fi

    local full_url="https://mms.alliedmods.net/mmsdrop/2.0/$metamod_version"
    local new_version=$(echo "$metamod_version" | grep -oP 'git\d+')
    local current_version=$(get_current_version "Metamod")

    if ! check_version "Metamod" "$current_version" "$new_version"; then
        return 0
    fi

    if handle_download_and_extract "$full_url" "$TEMP_DIR/metamod.tar.gz" "$TEMP_DIR/metamod" "tar.gz"; then
        cp -rf "$TEMP_DIR/metamod/addons/." "$OUTPUT_DIR/" && \
        update_version_file "Metamod" "$new_version" && \
        log_message "Metamod update completed successfully" "success"
        return 0
    fi

    return 1
}

update_server_cfg() {
    log_message "Updating server configuration..." "running"

    ROOT_CFG="/servUpConfig.cfg"
    # Server Configuration File
    SERVER_CFG="${GAME_DIRECTORY}/cfg/${CFG_FILE}"

    if [ ! -f "$ROOT_CFG" ]; then
        log_message "Configuration file servUpConfig.cfg not found. Skipping server configuration update." "error"
    else
        # Check if the server.cfg file exists
        if [ -f "$SERVER_CFG" ]; then
            # If file exists, update it
            while IFS= read -r line || [[ -n "$line" ]]; do
                # Trim whitespace from both ends of the line
                trimmed_line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

                # Skip empty lines and lines starting with //
                if [[ -n "$trimmed_line" && ! "$trimmed_line" =~ ^// ]]; then
                    # Get the first word of the trimmed line (command)
                    first_word=$(echo "$trimmed_line" | awk '{print $1}')
                    
                    # Check if the command (first word) exists in the current server.cfg
                    if ! grep -q "^$first_word\b" "$SERVER_CFG"; then
                        echo "$trimmed_line" >> "$SERVER_CFG"
                        log_message "Added line to server config: $trimmed_line" "success"
                    fi
                fi
            done < "$ROOT_CFG"
        else
            # If file does not exist, copy the entire config file
            cp "$ROOT_CFG" "$SERVER_CFG"
            log_message "Configuration file $SERVER_CFG created from servUpConfig.cfg." "success"
        fi
    fi
}

initialize_server_cfg() {
    ROOT_CFG="/servUpConfig.cfg"
    SERVER_CFG="${GAME_DIRECTORY}/cfg/${CFG_FILE}"

    # Проверяем, существует ли файл конфигурации или он пуст
    if [ ! -f "$SERVER_CFG" ] || [ ! -s "$SERVER_CFG" ]; then
        log_message "Initializing server configuration..." "running"
        cp "$ROOT_CFG" "$SERVER_CFG"
        log_message "Configuration file $SERVER_CFG created from servUpConfig.cfg." "success"

        # Меняем строки в соответствии с переменными
        if [ -f "$SERVER_CFG" ]; then
            # Замена строки для hostname
            sed -i "s/^hostname .*/hostname \"${HOST_NAME}\"/" "$SERVER_CFG"

            # Замена строки для sv_tags
            sed -i "s/^sv_tags .*/sv_tags \"${SERVER_TAGS}\"/" "$SERVER_CFG"
        fi
    fi
}

configure_metamod() {
    local GAMEINFO_FILE="/home/container/game/csgo/gameinfo.gi"
    local GAMEINFO_ENTRY="			Game	csgo/addons/metamod"

    if [ -f "${GAMEINFO_FILE}" ]; then
        if ! grep -q "Game[[:blank:]]*csgo\/addons\/metamod" "$GAMEINFO_FILE"; then # match any whitespace
            awk -v new_entry="$GAMEINFO_ENTRY" '
                BEGIN { found=0; }
                // {
                    if (found) {
                        print new_entry;
                        found=0;
                    }
                    print;
                }
                /Game_LowViolence/ { found=1; }
            ' "$GAMEINFO_FILE" > "$GAMEINFO_FILE.tmp" && mv "$GAMEINFO_FILE.tmp" "$GAMEINFO_FILE"
        fi
    fi
}