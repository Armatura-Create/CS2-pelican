#!/bin/bash
source /utils/logging.sh

# ===========================
# Базовые пути
# ===========================
# Путь к базовым файлам (монтируется в Docker)
BASE_FILES="/mnt"

# Путь к файлам внутри контейнера
CONTAINER_FILES="/home/container"

# ===========================
# Основные директории
# ===========================
GAME_DIRECTORY="./game/csgo"
OUTPUT_DIR="./game/csgo/addons"
TEMP_DIR="./temps"
ACCELERATOR_DUMPS_DIR="$OUTPUT_DIR/AcceleratorCS2/dumps"
VERSION_FILE="./game/versions.txt"

# ===========================
# Функция: копирование папки bin
# ===========================
copy_bin() {
    log_message "Копирование папки game/bin из $BASE_FILES/game/bin в $CONTAINER_FILES/game/bin с удалением лишнего (rsync --delete)..." "running"

    # Создаём папку назначения, если её нет
    mkdir -p "$CONTAINER_FILES/game/bin"

    # Копируем содержимое с полным удалением того, чего нет в source
    rsync -a --delete "$BASE_FILES/game/bin/" "$CONTAINER_FILES/game/bin/"
    log_message "Копирование папки bin завершено." "success"
}

# ===========================
# Функция: копирование только недостающих cfg
# ===========================
copy_cfg() {
    log_message "Копирование файлов game/csgo/cfg из $BASE_FILES/game/csgo/cfg в $CONTAINER_FILES/game/csgo/cfg..." "running"
    
    # Создаём папку назначения, если её нет
    mkdir -p "$CONTAINER_FILES/game/csgo/cfg"

    # Копируем только те файлы/папки, которых нет в целевой директории (rsync --ignore-existing)
    rsync -av --ignore-existing "$BASE_FILES/game/csgo/cfg/" "$CONTAINER_FILES/game/csgo/cfg/"

    # Проверяем код выхода rsync
    if [[ $? -eq 0 ]]; then
        log_message "Копирование файлов из game/csgo/cfg завершено." "success"
    else
        log_message "Ошибка при копировании файлов из game/csgo/cfg." "error"
    fi
}

# ===========================
# Функция: создание символических ссылок
# ===========================
create_symlinks() {
    log_message "Создание символических ссылок из $BASE_FILES в $CONTAINER_FILES..." "running"

    # Перебираем все файлы внутри $BASE_FILES
    find "$BASE_FILES" -type f | while read -r file; do

        # Пропускаем папку bin, т.к. она копируется отдельно (copy_bin)
        if [[ $file == "$BASE_FILES/game/bin/"* ]]; then
            continue
        fi

        # Пропускаем всё, что лежит в game/csgo/cfg, т.к. копируем cfg отдельно
        if [[ $file == "$BASE_FILES/game/csgo/cfg/"* ]]; then
            continue
        fi

        # Вычисляем относительный путь к файлу от BASE_FILES
        relative_path="${file#$BASE_FILES/}"

        # Определяем, куда будем делать ссылку в контейнере
        symlink_path="$CONTAINER_FILES/$relative_path"

        # Создаём недостающие поддиректории
        mkdir -p "$(dirname "$symlink_path")"

        # Если ссылка ещё не существует, пытаемся создать
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
                    # Если файла там нет, возможно недостаточно прав или иная ошибка
                    log_message "Файл/ссылка отсутствуют, но создать ссылку всё равно не удалось: $symlink_path -> $file" "error"
                fi
            fi
        fi
    done
}

# ===========================
# Функция: удаление устаревших символьных ссылок
# ===========================
remove_stale_symlinks() {
    log_message "Проверка и удаление устаревших символических ссылок в $CONTAINER_FILES..." "running"

    # Находим все ссылки в $CONTAINER_FILES
    find "$CONTAINER_FILES" -type l | while read -r symlink; do
        # Если целевой файл не существует (битая ссылка) — удаляем её
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

# ===========================
# Функции для работы с версиями
# ===========================
# Получаем текущую версию указанного дополнения (Metamod, CSS и т.д.)
get_current_version() {
    local addon="$1"
    if [ -f "$VERSION_FILE" ]; then
        grep "^$addon=" "$VERSION_FILE" | cut -d'=' -f2
    else
        echo ""
    fi
}

# Обновляем/добавляем новую версию в файл versions.txt
update_version_file() {
    local addon="$1"
    local new_version="$2"

    if grep -q "^$addon=" "$VERSION_FILE" 2>/dev/null; then
        sed -i "s/^$addon=.*/$addon=$new_version/" "$VERSION_FILE"
    else
        echo "$addon=$new_version" >> "$VERSION_FILE"
    fi
}

# ===========================
# Единая функция загрузки и распаковки (zip / tar.gz)
# ===========================
handle_download_and_extract() {
    local url="$1"
    local output_file="$2"
    local extract_dir="$3"
    local file_type="$4"  # "zip" или "tar.gz"

    log_message "Загрузка файла с адреса: $url" "debug"

    local max_retries=3
    local retry=0

    # Несколько попыток скачать файл
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

    # Проверяем, что файл не пустой
    if [ ! -s "$output_file" ]; then
        log_message "Скачанный файл пуст" "error"
        return 1
    fi

    log_message "Распаковываем в $extract_dir" "debug"
    mkdir -p "$extract_dir"

    case $file_type in
        "zip")
            unzip -qq -o "$output_file" -d "$extract_dir" || {
                log_message "Ошибка при распаковке zip-файла" "error"
                return 1
            }
            ;;
        "tar.gz")
            tar -xzf "$output_file" -C "$extract_dir" || {
                log_message "Ошибка при распаковке tar.gz" "error"
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
    local current="${2:-none}"
    local new="$3"

    if [ "$current" != "$new" ]; then
        log_message "Найдена новая версия для $addon: $new (текущая: $current)" "running"
        return 0
    fi

    log_message "У $addon нет новой версии. Текущая версия: $current" "success"
    return 1
}

# ===========================
# Очистка и обновление (Metamod/CSS)
# ===========================
cleanup_and_update() {
    # Если в переменных окружения включена очистка (CLEANUP_ENABLED), запускаем cleanup
    if [ "${CLEANUP_ENABLED:-0}" = "1" ]; then
        cleanup  # Функция cleanup где-то должна быть объявлена
    fi

    mkdir -p "$TEMP_DIR"

    # Логика автообновления metamod
    if [ "${METAMOD_AUTOUPDATE:-0}" = "1" ] || ([ ! -d "$OUTPUT_DIR/metamod" ] && [ "${CSS_AUTOUPDATE:-0}" = "1" ]); then
        update_metamod
    fi

    # Логика автообновления CounterStrikeSharp (CSS)
    if [ "${CSS_AUTOUPDATE:-0}" = "1" ]; then
        update_addon "roflmuffin/CounterStrikeSharp" "$OUTPUT_DIR" "css" "CSS"
    fi

    # Если нужно обновить server.cfg
    if [ "${UPDATE_CFG_FILE:-0}" = "1" ]; then
        update_server_cfg
    fi

    rm -rf "$TEMP_DIR"
}

# ===========================
# Обновление конкретного дополнения (например, CSS)
# ===========================
update_addon() {
    local repo="$1"
    local output_path="$2"
    local temp_subdir="$3"
    local addon_name="$4"

    local temp_dir="$TEMP_DIR/$temp_subdir"
    mkdir -p "$output_path" "$temp_dir"
    rm -rf "$temp_dir"/*

    # Запрашиваем GitHub Releases
    local api_response
    api_response=$(curl -s "https://api.github.com/repos/$repo/releases/latest")

    if [ -z "$api_response" ]; then
        log_message "Не удалось получить информацию о релизе для репо $repo" "error"
        return 1
    fi

    # Ищем ссылку на zip-файл
    local asset_url
    asset_url=$(echo "$api_response" | grep -oP '"browser_download_url": "\K[^"]+' | grep 'counterstrikesharp-with-runtime-build-.*-linux-.*\.zip')

    # Ищем tag_name, чтобы понять версию
    local new_version
    new_version=$(echo "$api_response" | grep -oP '"tag_name": "\K[^"]+')
    # Текущая версия, если была
    local current_version
    current_version=$(get_current_version "$addon_name")

    # Проверяем, есть ли новая версия
    if ! check_version "$addon_name" "$current_version" "$new_version"; then
        # Если нет новой, выходим
        return 0
    fi

    if [ -z "$asset_url" ]; then
        log_message "Не найдена подходящая ссылка на сборку Linux для $repo" "error"
        return 1
    fi

    # Скачиваем и распаковываем
    if handle_download_and_extract "$asset_url" "$temp_dir/download.zip" "$temp_dir" "zip"; then
        # Копируем распакованное в addons
        cp -r "$temp_dir/addons/." "$output_path" && \
        # Обновляем info о версии
        update_version_file "$addon_name" "$new_version" && \
        log_message "Успешно обновлён $repo до версии $new_version" "success"
        return 0
    fi

    return 1
}

# ===========================
# Установка/обновление Metamod
# ===========================
update_metamod() {
    # Если метамод не установлен
    if [ ! -d "$OUTPUT_DIR/metamod" ]; then
        log_message "Metamod не установлен. Выполняем установку..." "running"
    fi

    # Получаем ссылку на последний tar.gz
    local metamod_version
    metamod_version=$(curl -sL https://mms.alliedmods.net/mmsdrop/2.0/ | grep -oP 'href="\K(mmsource-[^"]*-linux\.tar\.gz)' | tail -1)
    if [ -z "$metamod_version" ]; then
        log_message "Не удалось получить версию Metamod" "error"
        return 1
    fi

    local full_url="https://mms.alliedmods.net/mmsdrop/2.0/$metamod_version"

    # Из имени файла достаём gitXXXX
    local new_version
    new_version=$(echo "$metamod_version" | grep -oP 'git\d+')
    local current_version
    current_version=$(get_current_version "Metamod")

    if ! check_version "Metamod" "$current_version" "$new_version"; then
        return 0
    fi

    # Скачиваем и распаковываем
    if handle_download_and_extract "$full_url" "$TEMP_DIR/metamod.tar.gz" "$TEMP_DIR/metamod" "tar.gz"; then
        # Копируем addons/metamod в $OUTPUT_DIR
        cp -rf "$TEMP_DIR/metamod/addons/." "$OUTPUT_DIR/" && \
        update_version_file "Metamod" "$new_version" && \
        log_message "Metamod успешно обновлён до $new_version" "success"
        return 0
    fi

    return 1
}

# ===========================
# Обновление server.cfg (при необходимости)
# ===========================
update_server_cfg() {
    log_message "Обновление конфигурационного файла сервера..." "running"

    ROOT_CFG="/servUpConfig.cfg"
    SERVER_CFG="${GAME_DIRECTORY}/cfg/${CFG_FILE}"

    # Проверяем наличие файла-образца
    if [ ! -f "$ROOT_CFG" ]; then
        log_message "Файл servUpConfig.cfg не найден. Пропускаем обновление конфигурации." "error"
    else
        # Если server.cfg уже есть, добавим в него новые строки
        if [ -f "$SERVER_CFG" ]; then
            while IFS= read -r line || [[ -n "$line" ]]; do
                # Убираем пробелы в начале/конце
                trimmed_line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                # Пропускаем пустые и закомментированные строки
                if [[ -n "$trimmed_line" && ! "$trimmed_line" =~ ^// ]]; then
                    # Берём первое слово (команда)
                    first_word=$(echo "$trimmed_line" | awk '{print $1}')
                    # Если такой команды нет в server.cfg, добавляем
                    if ! grep -q "^$first_word\b" "$SERVER_CFG"; then
                        echo "$trimmed_line" >> "$SERVER_CFG"
                        log_message "Добавлена строка в server.cfg: $trimmed_line" "success"
                    fi
                fi
            done < "$ROOT_CFG"
        else
            # Если server.cfg нет вовсе, копируем целиком
            cp "$ROOT_CFG" "$SERVER_CFG"
            log_message "Создан $SERVER_CFG на основе servUpConfig.cfg." "success"
        fi
    fi
}

# ===========================
# Инициализация server.cfg (если не существует)
# ===========================
initialize_server_cfg() {
    ROOT_CFG="/servUpConfig.cfg"
    SERVER_CFG="${GAME_DIRECTORY}/cfg/${CFG_FILE}"

    # Если server.cfg отсутствует или пуст, создаём
    if [ ! -f "$SERVER_CFG" ] || [ ! -s "$SERVER_CFG" ]; then
        log_message "Инициализация server.cfg..." "running"
        cp "$ROOT_CFG" "$SERVER_CFG"
        log_message "Создан $SERVER_CFG на основе servUpConfig.cfg." "success"

        # Дополнительно заменяем некоторые строки (hostname, sv_tags)
        if [ -f "$SERVER_CFG" ]; then
            sed -i "s/^hostname .*/hostname \"${HOST_NAME}\"/" "$SERVER_CFG"
            sed -i "s/^sv_tags .*/sv_tags \"${SERVER_TAGS}\"/" "$SERVER_CFG"
        fi
    fi
}

# ===========================
# Настройка Metamod в gameinfo.gi
# ===========================
configure_metamod() {
    local GAMEINFO_FILE="/home/container/game/csgo/gameinfo.gi"
    local GAMEINFO_ENTRY="			Game	csgo/addons/metamod"

    if [ -f "${GAMEINFO_FILE}" ]; then
        # Проверяем, есть ли строка "Game   csgo/addons/metamod"
        if ! grep -q "Game[[:blank:]]*csgo\/addons\/metamod" "$GAMEINFO_FILE"; then
            # Используем awk, чтобы вставить новую строку после "Game_LowViolence"
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
