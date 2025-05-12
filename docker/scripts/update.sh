#!/bin/bash
set -Eeuo pipefail

source /utils/logging.sh
trap 'handle_error "$LINENO" "$BASH_COMMAND"' ERR

# ===========================
# Пути по умолчанию
# ===========================
BASE_FILES="/mnt"
CONTAINER_FILES="/home/container"
GAME_DIRECTORY="./game/csgo"
OUTPUT_DIR="./game/csgo/addons"
TEMP_DIR="./temps"
ACCELERATOR_DUMPS_DIR="$OUTPUT_DIR/AcceleratorCS2/dumps"
VERSION_FILE="./game/versions.txt"

# ===========================
# Копирование папки bin
# ===========================
copy_bin() {
    log_message "Копируем /game/bin из $BASE_FILES в $CONTAINER_FILES (rsync --delete)..." "running"
    mkdir -p "$CONTAINER_FILES/game/bin"

    rsync -a --delete \
        --exclude='linuxsteamrt64/steamapps/' \
        "$BASE_FILES/game/bin/" \
        "$CONTAINER_FILES/game/bin/"

    rsync -av --ignore-existing \
        "$BASE_FILES/steamapps/" \
        "$CONTAINER_FILES/steamapps/"

    log_message "Копирование bin завершено." "success"
}

# ===========================
# Копирование только недостающих cfg
# ===========================
copy_cfg() {
    log_message "Копируем /game/csgo/cfg из $BASE_FILES в $CONTAINER_FILES (только недостающие)..." "running"
    mkdir -p "$CONTAINER_FILES/game/csgo/cfg"

    rsync -av --ignore-existing \
        "$BASE_FILES/game/csgo/cfg/" \
        "$CONTAINER_FILES/game/csgo/cfg/"

    log_message "Копирование cfg завершено." "success"
}

# ===========================
# Создание символьных ссылок (прочие файлы)
# ===========================
create_symlinks() {
    log_message "Создаём символьные ссылки из $BASE_FILES в $CONTAINER_FILES..." "running"

    # Перебираем все файлы внутри $BASE_FILES
    find "$BASE_FILES" -type f | while read -r file; do
        # Пропускаем bin/ и cfg/, они копируются отдельно
        if [[ $file == "$BASE_FILES/game/bin/"* ]]; then
            continue
        fi
        if [[ $file == "$BASE_FILES/game/csgo/cfg/"* ]]; then
            continue
        fi

        if [[ $file == "$BASE_FILES/steamapps/"* ]]; then
            continue
        fi

        # Относительный путь
        local relative_path="${file#$BASE_FILES/}"
        local symlink_path="$CONTAINER_FILES/$relative_path"

        mkdir -p "$(dirname "$symlink_path")"

        if [ ! -L "$symlink_path" ]; then
            ln -s "$file" "$symlink_path" && {
                log_message "Создана символическая ссылка: $symlink_path -> $file" "running"
            } || {
                # Если не удалось, пробуем удалить существующий файл и повторить
                log_message "Не удалось создать ссылку: $symlink_path -> $file. Пытаемся удалить существующий файл или ссылку..." "warning"
                if [ -e "$symlink_path" ]; then
                    rm -f "$symlink_path" && {
                        log_message "Удалён существующий файл или ссылка: $symlink_path" "running"
                        # Повторная попытка
                        ln -s "$file" "$symlink_path" && {
                            log_message "Символьная ссылка создана повторно: $symlink_path -> $file" "success"
                        } || {
                            log_message "Повторное создание ссылки не удалось: $symlink_path -> $file" "error"
                        }
                    } || {
                        log_message "Не удалось удалить существующий файл или ссылку: $symlink_path" "error"
                    }
                else
                    # Если файла/ссылки там нет, возможно недостаточно прав или иная ошибка
                    log_message "Файл/ссылка отсутствуют, но создать ссылку всё равно не удалось: $symlink_path -> $file" "error"
                fi
            }
        fi
    done
}

# ===========================
# Удаление битых символьных ссылок
# ===========================
remove_stale_symlinks() {
    log_message "Ищем и удаляем битые ссылки в $CONTAINER_FILES..." "running"

    find "$CONTAINER_FILES" -type l | while read -r symlink; do
        if [ ! -e "$symlink" ]; then
            rm "$symlink" && \
                log_message "Удалена битая ссылка: $symlink" "running"
        fi
    done
}

# ===========================
# Работа с versions.txt
# ===========================
get_current_version() {
    local addon="$1"
    if [ -f "$VERSION_FILE" ]; then
        # Сохраняем результат grep в переменную line.
        # Если не найдено, то line будет пустой.
        local line
        line="$(grep "^$addon=" "$VERSION_FILE" || true)"

        if [ -n "$line" ]; then
            # Отрезаем всё до знака '='
            echo "${line#*=}"
        else
            echo ""
        fi
    else
        echo ""
    fi
}

update_version_file() {
    local addon="$1"
    local new_version="$2"

    if [ -f "$VERSION_FILE" ] && grep -q "^$addon=" "$VERSION_FILE"; then
        sed -i "s/^$addon=.*/$addon=$new_version/" "$VERSION_FILE"
    else
        echo "$addon=$new_version" >> "$VERSION_FILE"
    fi
}

# ===========================
# Универсальная загрузка и распаковка
# ===========================
handle_download_and_extract() {
    local url="$1"
    local output_file="$2"
    local extract_dir="$3"
    local file_type="$4" # "zip" | "tar.gz"

    log_message "Загрузка файла: $url" "debug"
    local max_retries=3
    local retry=0

    while [ $retry -lt $max_retries ]; do
        if curl -fsSL -m 300 -o "$output_file" "$url"; then
            break
        fi
        ((retry++))
        log_message "Не удалось скачать файл (попытка $retry). Повтор через 5 сек..." "error"
        sleep 5
    done

    if [ $retry -eq $max_retries ]; then
        log_message "Скачивание не удалось после $max_retries попыток" "error"
        return 1
    fi

    if [ ! -s "$output_file" ]; then
        log_message "Скачанный файл пуст!" "error"
        return 1
    fi

    log_message "Распаковка в $extract_dir..." "debug"
    mkdir -p "$extract_dir"

    case "$file_type" in
        "zip")
            unzip -qq -o "$output_file" -d "$extract_dir" || {
                log_message "Ошибка распаковки zip-файла: $url" "error"
                return 1
            }
            ;;
        "tar.gz")
            tar -xzf "$output_file" -C "$extract_dir" || {
                log_message "Ошибка распаковки tar.gz: $url" "error"
                return 1
            }
            ;;
    esac
    return 0
}

# ===========================
# Проверка, есть ли новая версия
# ===========================
check_version() {
    local addon="$1"
    local current="$2"
    local new="$3"

    if [ "$current" != "$new" ]; then
        log_message "Новая версия для $addon: $new (была $current)" "running"
        return 0
    fi
    log_message "У $addon актуальная версия: $current" "success"
    return 1
}

# ===========================
# Обновление Metamod / CSS и пр.
# ===========================
cleanup_and_update() {
    # Если включена очистка, запускаем
    if [ "${CLEANUP_ENABLED:-0}" = "1" ]; then
        cleanup
    fi

    mkdir -p "$TEMP_DIR"

    # Обновление Metamod (если включено)
    if [ "${METAMOD_AUTOUPDATE:-0}" = "1" ] || ([ ! -d "$OUTPUT_DIR/metamod" ] && [ "${CSS_AUTOUPDATE:-0}" = "1" ]); then
        update_metamod
    fi

    # Обновление CounterStrikeSharp (CSS)
    if [ "${CSS_AUTOUPDATE:-0}" = "1" ]; then
        update_addon "roflmuffin/CounterStrikeSharp" "$OUTPUT_DIR" "css" "CSS"
    fi

    # Обновляем server.cfg (если нужно)
    if [ "${UPDATE_CFG_FILE:-0}" = "1" ]; then
        update_server_cfg
    fi

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

    local api_response
    api_response="$(curl -s "https://api.github.com/repos/$repo/releases/latest")" || true
    if [ -z "$api_response" ]; then
        log_message "Не удалось получить инфо о релизе для $repo" "error"
        return 1
    fi

    local asset_url
    asset_url="$(echo "$api_response" | grep -oP '"browser_download_url": "\K[^"]+' | grep 'counterstrikesharp-with-runtime-linux-.*\.zip' || true)"
    local new_version
    new_version="$(echo "$api_response" | grep -oP '"tag_name": "\K[^"]+' || true)"
    local current_version
    current_version="$(get_current_version "$addon_name")"

    if ! check_version "$addon_name" "$current_version" "$new_version"; then
        return 0
    fi

    if [ -z "$asset_url" ]; then
        log_message "Не найдена ссылка на linux-сборку для $repo" "error"
        return 1
    fi

    if handle_download_and_extract "$asset_url" "$temp_dir/download.zip" "$temp_dir" "zip"; then
        cp -r "$temp_dir/addons/." "$output_path"
        update_version_file "$addon_name" "$new_version"
        log_message "$addon_name обновлён до версии $new_version" "success"
    fi
}

update_metamod() {
    if [ ! -d "$OUTPUT_DIR/metamod" ]; then
        log_message "Metamod не установлен. Устанавливаем..." "running"
    fi

    local metamod_version
    metamod_version="$(curl -sL https://mms.alliedmods.net/mmsdrop/2.0/ | grep -oP 'href="\K(mmsource-[^"]*-linux\.tar\.gz)' | tail -n1 || true)"
    if [ -z "$metamod_version" ]; then
        log_message "Не удалось определить последнюю версию Metamod" "error"
        return 1
    fi

    local full_url="https://mms.alliedmods.net/mmsdrop/2.0/$metamod_version"
    local new_version
    new_version="$(echo "$metamod_version" | grep -oP 'git\d+' || true)"
    local current_version
    current_version="$(get_current_version "Metamod")"

    if ! check_version "Metamod" "$current_version" "$new_version"; then
        return 0
    fi

    if handle_download_and_extract "$full_url" "$TEMP_DIR/metamod.tar.gz" "$TEMP_DIR/metamod" "tar.gz"; then
        cp -rf "$TEMP_DIR/metamod/addons/." "$OUTPUT_DIR/"
        update_version_file "Metamod" "$new_version"
        log_message "Metamod обновлён до $new_version" "success"
    fi
}

update_server_cfg() {
    log_message "Обновление server.cfg..." "running"

    local ROOT_CFG="/servUpConfig.cfg"
    local SERVER_CFG="${GAME_DIRECTORY}/cfg/${CFG_FILE:-server.cfg}"

    if [ ! -f "$ROOT_CFG" ]; then
        log_message "servUpConfig.cfg не найден, пропускаем обновление." "error"
        return
    fi

    if [ -f "$SERVER_CFG" ]; then
        # Дописываем новые строки
        while IFS= read -r line || [[ -n "$line" ]]; do
            local trimmed_line
            trimmed_line="$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
            [[ -z "$trimmed_line" ]] && continue
            [[ "$trimmed_line" =~ ^// ]] && continue

            local first_word
            first_word="$(echo "$trimmed_line" | awk '{print $1}')"
            if ! grep -q "^$first_word\b" "$SERVER_CFG"; then
                echo "$trimmed_line" >> "$SERVER_CFG"
                log_message "Добавлена строка в server.cfg: $trimmed_line" "debug"
            fi
        done < "$ROOT_CFG"
    else
        cp "$ROOT_CFG" "$SERVER_CFG"
        log_message "Создан $SERVER_CFG на основе servUpConfig.cfg" "success"
    fi
}

initialize_server_cfg() {
    local ROOT_CFG="/servUpConfig.cfg"
    local SERVER_CFG="${GAME_DIRECTORY}/cfg/${CFG_FILE:-server.cfg}"

    if [ ! -f "$SERVER_CFG" ] || [ ! -s "$SERVER_CFG" ]; then
        log_message "Инициализация server.cfg..." "running"
        cp "$ROOT_CFG" "$SERVER_CFG"
        log_message "Создан $SERVER_CFG на основе servUpConfig.cfg." "success"

        if [ -f "$SERVER_CFG" ]; then
            sed -i "s/^hostname .*/hostname \"${HOST_NAME:-ServUp-CS2}\"/" "$SERVER_CFG"
            sed -i "s/^sv_tags .*/sv_tags \"${SERVER_TAGS:-servup}\"/" "$SERVER_CFG"
        fi
    fi
}

configure_metamod() {
    local GAMEINFO_FILE="/home/container/game/csgo/gameinfo.gi"
    local GAMEINFO_ENTRY="			Game	csgo/addons/metamod"

    if [ -f "$GAMEINFO_FILE" ]; then
        if ! grep -q "Game[[:blank:]]*csgo\/addons\/metamod" "$GAMEINFO_FILE"; then
            awk -v new_entry="$GAMEINFO_ENTRY" '
                BEGIN { found=0; }
                {
                    if (found == 1) {
                        print new_entry
                        found=0
                    }
                    print $0
                }
                /Game_LowViolence/ { found=1 }
            ' "$GAMEINFO_FILE" > "${GAMEINFO_FILE}.tmp"

            mv "${GAMEINFO_FILE}.tmp" "$GAMEINFO_FILE"
        fi
    fi
}
