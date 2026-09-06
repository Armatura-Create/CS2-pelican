#!/bin/bash
set -Eeuo pipefail

# Подключаем необходимые скрипты
source /scripts/cleanup.sh    # Логика очистки
source /scripts/update.sh     # Логика обновлений
source /scripts/filter.sh     # Логика фильтрации вывода (консоли)

# Ловим любые ошибки через handle_error() из logging.sh
trap 'handle_error "$LINENO" "$BASH_COMMAND"' ERR

# ============================
# DEBUG: Вывод переменных окружения
# ============================
if [ "${LOG_LEVEL:-INFO}" = "DEBUG" ]; then
    log_message "=== DEBUG MODE: Вывод всех переменных окружения ===" "debug"
    log_message "────────────────────────────────────────────────────" "debug"

    while IFS='=' read -r name value; do
        case "$name" in
            *PASSWORD*|*TOKEN*|*SECRET*|*KEY*|STEAM_ACC|RCON_PASSWORD)
                log_message "  $name=********" "debug"
                ;;
            *)
                log_message "  $name=$value" "debug"
                ;;
        esac
    done < <(env | sort)

    log_message "────────────────────────────────────────────────────" "debug"
    log_message "=== Конец вывода переменных окружения ===" "debug"
fi

# ============================
# 1) Базовая инициализация
# ============================
create_symlinks
remove_stale_symlinks
copy_bin
copy_cfg

cd "/home/container"

# Чистим старые логи, если логирование в файл включено
clean_old_logs

# ============================
# 2) Инициализация серверных настроек
# ============================
initialize_server_cfg

# ============================
# 3) gameinfo.gi
# ============================
# КРИТИЧЕСКИ ВАЖНО: gameinfo.gi НЕ должен быть символьной ссылкой — мы его
# модифицируем, а /mnt смонтирован только на чтение.
if [ -L "$GAMEINFO_FILE" ]; then
    log_message "gameinfo.gi является символьной ссылкой, преобразуем в обычный файл..." "warning"
    rm -f "$GAMEINFO_FILE"
fi

if [ ! -f "$GAMEINFO_FILE" ]; then
    if [ -f "$GAMEINFO_MNT" ]; then
        log_message "Копируем gameinfo.gi из /mnt..." "running"
        mkdir -p "$(dirname "$GAMEINFO_FILE")"
        cp "$GAMEINFO_MNT" "$GAMEINFO_FILE"
        log_message "gameinfo.gi скопирован" "success"
    else
        log_message "КРИТИЧЕСКАЯ ОШИБКА: gameinfo.gi не найден ни в контейнере, ни в /mnt!" "error"
        log_message "Сервер может не запуститься. Убедитесь что SteamCMD установил игру корректно." "error"
    fi
fi

gameinfo_drift_check

# ============================
# 4) Очистка + установка/обновление аддонов
# ============================
# Аддоны опциональны: их недоступность не должна мешать серверу стартовать.
if ! cleanup_and_update; then
    log_message "Этап обновления завершился с ошибкой — продолжаем запуск сервера." "warning"
fi

# ============================
# 5) Настройка фильтра (при необходимости)
# ============================
setup_message_filter

# ============================
# 6) Формируем и логируем команду запуска
# ============================
# RCON без пароля включать нельзя — иначе сервер слушает управляющий порт впустую
# либо (при заданном где-то пароле) отдаёт управление наружу.
if [ "${RCON_ENABLED:-0}" = "1" ] && [ -z "${RCON_PASSWORD:-}" ]; then
    log_message "RCON включён, но RCON_PASSWORD пуст — RCON НЕ будет включён." "error"
    log_message "Задайте Rcon Password в переменных сервера или выключите Using Rcon." "error"
    RCON_ENABLED=0
fi

# ВНИМАНИЕ (принятый риск, как в штатных яйцах Pelican):
# ниже переменные окружения проходят через eval. Значение вида $(команда)
# в CUSTOM_PARAMS и других переменных БУДЕТ выполнено внутри контейнера.
# Редактировать переменные может только владелец сервера, у которого и так есть консоль.
MODIFIED_STARTUP="$(eval echo "$(echo "${STARTUP}" | sed -e 's/{{/${/g' -e 's/}}/}/g')")"

# Используем 'unbuffer' для корректного вывода
MODIFIED_STARTUP="unbuffer -p ${MODIFIED_STARTUP}"

# Маскируем +sv_setsteamaccount <token> в логе
LOGGED_STARTUP="$(echo "${MODIFIED_STARTUP#unbuffer -p }" | \
    sed -E 's/(\+sv_setsteamaccount\s+[A-Z0-9]{32})/+sv_setsteamaccount ************************/g')"

log_message "Запускаем сервер командой: ${LOGGED_STARTUP}" "running"

# ============================
# 7) Запуск сервера + фильтрация вывода
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
