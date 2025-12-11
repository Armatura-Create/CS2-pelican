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
# Конфигурация типов аддонов
# ===========================

# Объявляем ассоциативные массивы для конфигурации
declare -A ADDON_FILE_PATTERNS=(
    ["css"]="counterstrikesharp-with-runtime-linux-.*\.zip"
    ["swiftly"]="swiftlys2-linux-v.*-with-runtimes\.zip"
    ["modsharp"]="modsharp.*linux\.zip"
)

declare -A ADDON_GAMEINFO_DIRS=(
    ["css"]=""                    # CSS не добавляется в gameinfo.gi
    ["swiftly"]="swiftlys2"       # Swiftly добавляется как csgo/addons/swiftlys2
    ["modsharp"]="modsharp"       # ModSharp добавляется как csgo/addons/modsharp
)

declare -A ADDON_REQUIRES_METAMOD=(
    ["css"]="1"        # CSS требует MetaMod
    ["swiftly"]="0"    # Swiftly standalone
    ["modsharp"]="0"   # ModSharp standalone
)

declare -A ADDON_INSTALL_DIRS=(
    ["css"]="counterstrikesharp"     # CSS устанавливается в addons/counterstrikesharp
    ["swiftly"]="swiftlys2"          # Swiftly устанавливается в addons/swiftlys2
    ["modsharp"]="modsharp"          # ModSharp устанавливается в addons/modsharp
)

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
        
        # КРИТИЧЕСКИ ВАЖНО: НЕ создаём ссылку для gameinfo.gi
        # Этот файл модифицируется (добавление MetaMod, Swiftly и т.д.)
        # и должен быть локальным в контейнере
        if [[ $file == "$BASE_FILES/game/csgo/gameinfo.gi" ]]; then
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

    # Обновление Metamod (только если включено)
    if [ "${METAMOD_AUTOUPDATE:-0}" = "1" ]; then
        update_metamod
    fi

    # Обновление CounterStrikeSharp (CSS)
    if [ "${CSS_AUTOUPDATE:-0}" = "1" ]; then
        update_addon_universal "roflmuffin/CounterStrikeSharp" "css" "CSS"
    fi

    # Обновление Swiftly (SwiftlyS2)
    if [ "${SWIFTLY_AUTOUPDATE:-0}" = "1" ]; then
        update_addon_universal "swiftly-solution/swiftlys2" "swiftly" "Swiftly"
    fi

    # Обновляем server.cfg (если нужно)
    if [ "${UPDATE_CFG_FILE:-0}" = "1" ]; then
        update_server_cfg
    fi
    
    # Проверяем порядок в gameinfo.gi
    verify_gameinfo_order

    rm -rf "$TEMP_DIR"
}

update_addon_universal() {
    local repo="$1"
    local addon_type="$2"      # css, swiftly, modsharp
    local addon_name="$3"      # CSS, Swiftly, ModSharp
    
    # Проверка валидности типа
    if [ -z "${ADDON_FILE_PATTERNS[$addon_type]}" ]; then
        log_message "Неизвестный тип аддона: $addon_type" "error"
        return 1
    fi
    
    local temp_dir="$TEMP_DIR/$addon_type"
    mkdir -p "$OUTPUT_DIR" "$temp_dir"
    rm -rf "$temp_dir"/*
    
    # 1. Получить информацию о релизе
    log_message "Проверка обновлений для $addon_name..." "running"
    
    local api_response
    api_response="$(curl -s "https://api.github.com/repos/$repo/releases/latest")" || true
    
    if [ -z "$api_response" ]; then
        log_message "Не удалось получить информацию о релизе для $repo" "error"
        return 1
    fi
    
    # 2. Извлечь версию
    local new_version
    new_version="$(echo "$api_response" | grep -oP '"tag_name": "\K[^"]+' || true)"
    
    if [ -z "$new_version" ]; then
        log_message "Не удалось определить версию для $addon_name" "error"
        return 1
    fi
    
    # 3. Проверить физическое наличие аддона и необходимость обновления
    local current_version
    current_version="$(get_current_version "$addon_name")"
    
    # Проверяем существование папки аддона
    local addon_install_dir="${ADDON_INSTALL_DIRS[$addon_type]}"
    local addon_full_path="$OUTPUT_DIR/$addon_install_dir"
    
    if [ ! -d "$addon_full_path" ]; then
        if [ -n "$current_version" ]; then
            log_message "$addon_name удалён вручную (версия: $current_version, но папка отсутствует). Переустанавливаю..." "warning"
        else
            log_message "$addon_name не установлен. Устанавливаю версию $new_version..." "running"
        fi
        # Принудительная установка - НЕ проверяем версию
    else
        # Папка существует - проверяем версию
        if ! check_version "$addon_name" "$current_version" "$new_version"; then
            return 0
        fi
    fi
    
    # 4. Найти подходящий asset
    local file_pattern="${ADDON_FILE_PATTERNS[$addon_type]}"
    local asset_url
    
    # Получаем список всех browser_download_url
    local all_urls
    all_urls="$(echo "$api_response" | grep -oP '"browser_download_url": "\K[^"]+')"
    
    # Ищем URL по паттерну
    asset_url="$(echo "$all_urls" | grep -E "$file_pattern" | head -n1 || true)"
    
    if [ -z "$asset_url" ]; then
        log_message "Не найден файл для $addon_name (паттерн: $file_pattern)" "error"
        log_message "Доступные файлы:" "debug"
        echo "$all_urls" | while read -r url; do
            log_message "  - $(basename "$url")" "debug"
        done
        return 1
    fi
    
    log_message "Найден файл: $(basename "$asset_url")" "debug"
    
    # 5. Скачать и распаковать
    if handle_download_and_extract "$asset_url" "$temp_dir/download.zip" "$temp_dir" "zip"; then
        # 6. Установить аддон
        # Ищем папку addons в архиве (может быть вложена)
        local addons_src
        addons_src="$(find "$temp_dir" -maxdepth 2 -type d -name 'addons' | head -n1)"
        
        if [ -n "$addons_src" ] && [ -d "$addons_src" ]; then
            # Для Swiftly: удаляем папку metamod из архива (она там может быть, но мы управляем MetaMod отдельно)
            if [ "$addon_type" = "swiftly" ] && [ -d "$addons_src/metamod" ]; then
                log_message "Удаляем metamod из архива Swiftly (управляется отдельно)" "debug"
                rm -rf "$addons_src/metamod"
            fi
            
            cp -r "$addons_src/." "$OUTPUT_DIR"
            log_message "Файлы $addon_name скопированы из $addons_src в $OUTPUT_DIR" "debug"
        else
            log_message "Структура архива не содержит папку addons/ (проверено до глубины 2)" "error"
            log_message "Содержимое $temp_dir:" "debug"
            find "$temp_dir" -maxdepth 2 -type d | while read -r dir; do
                log_message "  - $dir" "debug"
            done
            return 1
        fi
        
        # 7. Обновить версию
        update_version_file "$addon_name" "$new_version"
        
        # 8. Обновить gameinfo.gi (если нужно)
        local gameinfo_dir="${ADDON_GAMEINFO_DIRS[$addon_type]}"
        if [ -n "$gameinfo_dir" ]; then
            add_gameinfo_entry "$gameinfo_dir" "$addon_name"
        fi
        
        log_message "$addon_name обновлён до версии $new_version" "success"
        return 0
    else
        log_message "Ошибка при установке $addon_name" "error"
        return 1
    fi
}

update_metamod() {
    local branch="${1:-master}"  # stable/dev/master
    local page file_name url_primary tmp_tar current_version new_version
    tmp_tar="$TEMP_DIR/metamod.tar.gz"
    
    local metamod_installed=false
    if [ ! -d "$OUTPUT_DIR/metamod" ]; then
        log_message "Metamod не установлен" "running"
    else
        metamod_installed=true
    fi

    # 1) Страница загрузок
    local downloads_page="https://www.metamodsource.net/downloads.php?branch=${branch}"
    page="$(curl -fsSL "$downloads_page" || true)"
    if [ -z "$page" ]; then
        log_message "Страница загрузок недоступна: ${downloads_page}" "error"
        return 0
    fi

    # 2) Парсим все linux-архивы и берём с максимальным gitNNNN
    file_name="$(
        printf '%s' "$page" \
        | grep -oE 'mmsource-[^"]*-linux\.tar\.gz' \
        | tr -d '\r' \
        | awk '{fn=$0; if (match($0,/git[0-9]+/)) {g=substr($0,RSTART+3,RLENGTH-3); print g" "fn}}' \
        | sort -nr | head -n1 | awk '{ $1=""; sub(/^ /,""); print }'
    )"

    if [ -z "$file_name" ]; then
        log_message "Не удалось найти ссылку на linux-архив на странице ${downloads_page}" "error"
        return 0
    fi

    # 3) Версия и URL только с зеркала
    new_version="$(echo "$file_name" | grep -oE 'git[0-9]+' | tr -d '\r' || true)"
    if [ -z "$new_version" ]; then
        log_message "Не удалось распознать номер билда из имени: $file_name" "error"
        return 0
    fi

    url_primary="https://www.sourcemm.net/mmsdrop/2.0/${file_name}"
    url_primary="$(printf '%s' "$url_primary" | tr -d '\r' | xargs)"
    file_name="$(printf '%s' "$file_name" | xargs)"

    current_version="$(get_current_version "Metamod")"
    
    # Проверяем: если папка удалена вручную, но версия записана - переустанавливаем
    if [ "$metamod_installed" = false ]; then
        if [ -n "$current_version" ]; then
            log_message "Metamod удалён вручную (версия: $current_version, но папка отсутствует). Переустанавливаю..." "warning"
        else
            log_message "Устанавливаю Metamod версии $new_version..." "running"
        fi
        # Принудительная установка - НЕ проверяем версию
    else
        # Папка существует - проверяем версию
        if ! check_version "Metamod" "$current_version" "$new_version"; then
            return 0
        fi
    fi

    log_message "Новая версия для Metamod: ${new_version} (файл: ${file_name})" "running"
    log_message "url_primary=[$url_primary]" "running"

    # 4) Скачиваем и распаковываем через твой helper (ВАЖНО: порядок аргументов)
    mkdir -p "$TEMP_DIR"
    rm -f "$tmp_tar"
    rm -rf "$TEMP_DIR/metamod"

    if handle_download_and_extract "$url_primary" "$tmp_tar" "$TEMP_DIR/metamod" "tar.gz"; then
        # 5) Копируем addons/ (иногда архив кладёт в корень, иногда — в подпапку)
        local addons_src
        addons_src="$(find "$TEMP_DIR/metamod" -maxdepth 2 -type d -path '*/addons' | head -n1)"
        if [ -z "$addons_src" ]; then
            log_message "Не нашли папку addons/ после распаковки" "error"
            return 1
        fi
        cp -rf "$addons_src/." "$OUTPUT_DIR/"
        update_version_file "Metamod" "$new_version"
        log_message "Metamod обновлён до $new_version" "success"
    else
        log_message "Не удалось скачать/распаковать Metamod" "error"
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


# ===========================
# Управление gameinfo.gi
# ===========================

add_gameinfo_entry() {
    local addon_dir="$1"      # Например: "swiftlys2", "modsharp"
    local addon_name="$2"     # Например: "Swiftly", "ModSharp"
    
    local GAMEINFO_FILE="/home/container/game/csgo/gameinfo.gi"
    local GAMEINFO_BACKUP="${GAMEINFO_FILE}.backup"
    local GAMEINFO_ENTRY="			Game	csgo/addons/$addon_dir"
    
    if [ ! -f "$GAMEINFO_FILE" ]; then
        log_message "Файл gameinfo.gi не найден: $GAMEINFO_FILE" "error"
        return 1
    fi
    
    # Создаём резервную копию перед изменением (если её ещё нет)
    if [ ! -f "$GAMEINFO_BACKUP" ]; then
        cp "$GAMEINFO_FILE" "$GAMEINFO_BACKUP"
        log_message "Создана резервная копия gameinfo.gi" "debug"
    fi
    
    # Проверяем, есть ли уже запись
    if grep -q "Game[[:blank:]]*csgo\/addons\/$addon_dir" "$GAMEINFO_FILE"; then
        log_message "Запись $addon_name уже присутствует в gameinfo.gi" "debug"
        return 0
    fi
    
    # Добавляем запись после Game_LowViolence
    log_message "Добавляем $addon_name в gameinfo.gi..." "running"
    
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
    
    if [ $? -eq 0 ]; then
        mv "${GAMEINFO_FILE}.tmp" "$GAMEINFO_FILE"
        log_message "$addon_name добавлен в gameinfo.gi" "success"
        return 0
    else
        log_message "Ошибка при обновлении gameinfo.gi для $addon_name" "error"
        rm -f "${GAMEINFO_FILE}.tmp"
        return 1
    fi
}

remove_gameinfo_entry() {
    local addon_dir="$1"      # Например: "swiftlys2", "modsharp"
    local addon_name="$2"     # Например: "Swiftly", "ModSharp"
    
    local GAMEINFO_FILE="/home/container/game/csgo/gameinfo.gi"
    local GAMEINFO_BACKUP="${GAMEINFO_FILE}.backup"
    
    if [ ! -f "$GAMEINFO_FILE" ]; then
        return 0
    fi
    
    # Создаём резервную копию перед изменением (если её ещё нет)
    if [ ! -f "$GAMEINFO_BACKUP" ]; then
        cp "$GAMEINFO_FILE" "$GAMEINFO_BACKUP"
        log_message "Создана резервная копия gameinfo.gi" "debug"
    fi
    
    # Проверяем, есть ли запись
    if ! grep -q "csgo\/addons\/$addon_dir" "$GAMEINFO_FILE"; then
        return 0
    fi
    
    log_message "Удаляем $addon_name из gameinfo.gi..." "running"
    
    # Удаляем строку с записью
    sed -i "/csgo\/addons\/$addon_dir/d" "$GAMEINFO_FILE"
    
    log_message "$addon_name удалён из gameinfo.gi" "success"
    return 0
}

verify_gameinfo_order() {
    # Проверяет и АВТОМАТИЧЕСКИ ИСПРАВЛЯЕТ порядок записей в gameinfo.gi
    # MetaMod должен быть первым, потом остальные
    
    local GAMEINFO_FILE="/home/container/game/csgo/gameinfo.gi"
    local GAMEINFO_BACKUP="${GAMEINFO_FILE}.backup"
    
    if [ ! -f "$GAMEINFO_FILE" ]; then
        return 0
    fi
    
    # Получаем порядок записей
    local entries
    entries="$(grep -oP 'Game[[:blank:]]+csgo/addons/\K[^[:space:]]+' "$GAMEINFO_FILE" || true)"
    
    if [ -z "$entries" ]; then
        return 0
    fi
    
    log_message "Записи в gameinfo.gi:" "debug"
    echo "$entries" | while read -r entry; do
        log_message "  - $entry" "debug"
    done
    
    # Проверяем что MetaMod первый (если он есть)
    local first_entry
    first_entry="$(echo "$entries" | head -n1)"
    
    if echo "$entries" | grep -q "metamod"; then
        if [ "$first_entry" != "metamod" ]; then
            log_message "ВНИМАНИЕ: MetaMod не первый в gameinfo.gi. Автоматически исправляю порядок..." "warning"
            
            # Создаём резервную копию перед изменением
            if [ ! -f "$GAMEINFO_BACKUP" ]; then
                cp "$GAMEINFO_FILE" "$GAMEINFO_BACKUP"
            fi
            
            # Простой способ: удаляем строку с metamod и добавляем её первой
            local temp_file="${GAMEINFO_FILE}.reorder"
            
            # Удаляем запись metamod
            sed '/Game[[:blank:]]*csgo\/addons\/metamod/d' "$GAMEINFO_FILE" > "$temp_file"
            
            # Добавляем metamod первым (сразу после Game_LowViolence)
            awk '
                BEGIN { added=0; }
                /Game_LowViolence/ {
                    print $0
                    if (!added) {
                        print "\t\t\tGame\tcsgo/addons/metamod"
                        added=1
                    }
                    next
                }
                { print $0 }
            ' "$temp_file" > "${GAMEINFO_FILE}"
            
            rm -f "$temp_file"
            
            log_message "Порядок в gameinfo.gi исправлен: MetaMod теперь первый" "success"
        else
            log_message "Порядок в gameinfo.gi правильный: MetaMod первый" "debug"
        fi
    fi
    
    return 0
}
