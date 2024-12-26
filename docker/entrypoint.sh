#!/bin/bash

source /scripts/cleanup.sh
source /scripts/update.sh
source /scripts/filter.sh

# Enhanced error handling
trap 'handle_error ${LINENO} "$BASH_COMMAND"' ERR

# Путь к базовым файлам и файлам в контейнере
BASE_FILES="/mnt"
CONTAINER_FILES="/home/container"

# Функция для копирования папки bin
copy_bin() {
    log_message "Копирование папки bin из $BASE_FILES/bin в $CONTAINER_FILES/bin с заменой..." "running"
    # Убедиться, что папка назначения существует
    mkdir -p "$CONTAINER_FILES/game/bin"
    # Копировать содержимое с заменой
    rsync -a --delete "$BASE_FILES/game/bin/" "$CONTAINER_FILES/game/bin/"
    log_message "Копирование папки bin завершено." "success"
}

# Функция для создания символических ссылок
create_symlinks() {
    log_message "Создание символических ссылок из $BASE_FILES в $CONTAINER_FILES..." "running"
    find "$BASE_FILES" -type f | while read -r file; do
        # Пропустить папку bin, так как она копируется отдельно
        if [[ $file == "$BASE_FILES/game/bin/"* ]]; then
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

# Выполнить функции
create_symlinks
remove_stale_symlinks
copy_bin

cd $CONTAINER_FILES
sleep 1

# Get internal Docker IP
INTERNAL_IP=$(ip route get 1 | awk '{print $NF;exit}')

# Initial setup and sync
clean_old_logs
initialize_server_cfg
configure_metamod

# Run cleanup and setup message filter
cleanup_and_update
setup_message_filter

export PWD=/home/container

# Prepare startup command
MODIFIED_STARTUP=$(eval echo $(echo ${STARTUP} | sed -e 's/{{/${/g' -e 's/}}/}/g'))
MODIFIED_STARTUP="unbuffer -p ${MODIFIED_STARTUP}"

# Log censored startup command
LOGGED_STARTUP=$(echo "${MODIFIED_STARTUP#unbuffer -p }" | \
    sed -E 's/(\+sv_setsteamaccount\s+[A-Z0-9]{32})/+sv_setsteamaccount ************************/g')
log_message "Starting server with command: ${LOGGED_STARTUP}" "running"

# Run the server with output handling
$MODIFIED_STARTUP 2>&1 | while IFS= read -r line; do
    line="${line%[[:space:]]}"
    [[ "$line" =~ Segmentation\ fault.*"${GAMEEXE}" ]] && continue
    handle_server_output "$line"
done

# Kill all background processes
pkill -P $$ 2>/dev/null || true

log_message "Server has stopped successfully." "success"