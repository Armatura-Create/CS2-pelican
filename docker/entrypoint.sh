#!/bin/bash
set -Eeuo pipefail

# Подключаем необходимые скрипты
source /scripts/cleanup.sh    # Логика очистки
source /scripts/update.sh     # Логика обновлений
source /scripts/filter.sh     # Логика фильтрации вывода (консоли)

# Ловим любые ошибки через handle_error() из logging.sh
trap 'handle_error "$LINENO" "$BASH_COMMAND"' ERR

# ============================
# 1) Базовая инициализация
# ============================
create_symlinks
remove_stale_symlinks
copy_bin
copy_cfg

# Переходим в рабочую директорию
cd "/home/container"
sleep 1

# Узнаём внутренний Docker IP (для каких-то нужд)
INTERNAL_IP="$(ip route get 1 | awk '{print $NF;exit}')"

# Чистим старые логи, если логирование в файл включено
clean_old_logs

# ============================
# 2) Инициализация серверных настроек
# ============================
initialize_server_cfg
configure_metamod

# ============================
# 3) Очистка + обновление (если включено)
# ============================
cleanup_and_update

# ============================
# 4) Настройка фильтра (при необходимости)
# ============================
setup_message_filter

# ============================
# 5) Формируем и логируем команду запуска
# ============================
# Поддержка шаблона {{VAR}} => ${VAR}
MODIFIED_STARTUP="$(eval echo "$(echo "${STARTUP}" | sed -e 's/{{/${/g' -e 's/}}/}/g')")"

# Используем 'unbuffer' для корректного вывода
MODIFIED_STARTUP="unbuffer -p ${MODIFIED_STARTUP}"

# Маскируем +sv_setsteamaccount <token> в логе
LOGGED_STARTUP="$(echo "${MODIFIED_STARTUP#unbuffer -p }" | \
    sed -E 's/(\+sv_setsteamaccount\s+[A-Z0-9]{32})/+sv_setsteamaccount ************************/g')"

log_message "Запускаем сервер командой: ${LOGGED_STARTUP}" "running"

# ============================
# 6) Запуск сервера + фильтрация вывода
# ============================
$MODIFIED_STARTUP 2>&1 | while IFS= read -r line; do
    line="${line%[[:space:]]}"

    # Пропускаем Segfault по GAMEEXE
    [[ "$line" =~ Segmentation\ fault.* ]] && continue

    handle_server_output "$line"
done

# Убиваем все фоновые процессы, если остались
pkill -P $$ 2>/dev/null || true

log_message "Сервер завершил работу." "success"
