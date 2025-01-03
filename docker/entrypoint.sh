#!/bin/bash

# Подключаем необходимые модули
source /scripts/cleanup.sh    # Содержит логику очистки старых файлов
source /scripts/update.sh     # Содержит логику обновлений (Metamod, CSS и т.д.)
source /scripts/filter.sh     # Содержит логику фильтрации вывода (консоли)

# -------------------------------------------------------------------
# Расширенная обработка ошибок: при любой ошибке вызываем handle_error
# (определён в logging.sh), передаем номер строки и команду
# -------------------------------------------------------------------
trap 'handle_error ${LINENO} "$BASH_COMMAND"' ERR

# ============================
# 1) Базовая инициализация
# ============================
# 1.1 Создаём символьные ссылки, удаляем устаревшие
create_symlinks
remove_stale_symlinks

# 1.2 Копируем bin/ и cfg/, если нужно
copy_bin
copy_cfg

# 1.3 Переходим в рабочую директорию контейнера
cd "/home/container"
sleep 1

# 1.4 Узнаём внутренний Docker IP (для дополнительной логики)
INTERNAL_IP=$(ip route get 1 | awk '{print $NF;exit}')

# 1.5 Удаляем старые логи, если включено логирование в файл
clean_old_logs

# ============================
# 2) Инициализация серверных настроек
# ============================
# 2.1 Создаём/обновляем server.cfg, если нужно
initialize_server_cfg
# 2.2 Настраиваем Metamod (добавляем нужные строки в gameinfo.gi)
configure_metamod

# ============================
# 3) Очистка и обновление (если задано)
# ============================
# 3.1 Запускаем процедуру cleanup_and_update (включает update_addon, update_metamod и т.д.)
cleanup_and_update

# ============================
# 4) Настройка фильтра (mute_messages.cfg и т.д.)
# ============================
setup_message_filter

# Устанавливаем рабочую директорию окружения
export PWD=/home/container

# ============================
# 5) Формируем и логируем команду запуска сервера
# ============================
# Поддержка переменных {{VAR}} => ${VAR}
MODIFIED_STARTUP=$(eval echo $(echo ${STARTUP} | sed -e 's/{{/${/g' -e 's/}}/}/g'))
# При необходимости используем 'unbuffer' (из expect) для плавного вывода
MODIFIED_STARTUP="unbuffer -p ${MODIFIED_STARTUP}"

# Маскируем +sv_setsteamaccount <token> в логах
LOGGED_STARTUP=$(echo "${MODIFIED_STARTUP#unbuffer -p }" | \
    sed -E 's/(\+sv_setsteamaccount\s+[A-Z0-9]{32})/+sv_setsteamaccount ************************/g')

# Пишем в лог, что именно запускаем
log_message "Запуск сервера командой: ${LOGGED_STARTUP}" "running"

# ============================
# 6) Запуск сервера и обработка вывода
# ============================
#  - Читаем строку за строкой из стандартного вывода/ошибок (2>&1)
#  - Удаляем пробелы в конце строки
#  - Игнорируем строки про 'Segmentation fault' от "${GAMEEXE}"
#  - Передаём строку в handle_server_output (реализация в filter.sh)
$MODIFIED_STARTUP 2>&1 | while IFS= read -r line; do
    line="${line%[[:space:]]}"
    [[ "$line" =~ Segmentation\ fault.*"${GAMEEXE}" ]] && continue
    handle_server_output "$line"
done

# Убиваем все фоновые процессы, запущенные от текущего PID
pkill -P $$ 2>/dev/null || true

# Итоговое сообщение в лог
log_message "Сервер успешно остановлен." "success"
