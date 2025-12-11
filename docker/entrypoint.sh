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
    
    # Сортируем и выводим все переменные окружения
    while IFS='=' read -r name value; do
        # Маскируем чувствительные данные
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
    log_message "" "debug"
fi

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
# Инициализация gameinfo.gi
# ============================
# КРИТИЧЕСКИ ВАЖНО: gameinfo.gi НЕ должен быть символьной ссылкой!
# Мы его модифицируем (добавляем MetaMod, Swiftly и т.д.)
# и изменения должны сохраняться локально в контейнере
GAMEINFO_CONTAINER="/home/container/game/csgo/gameinfo.gi"
GAMEINFO_MNT="/mnt/game/csgo/gameinfo.gi"

if [ -L "$GAMEINFO_CONTAINER" ]; then
    # Если это символьная ссылка - удаляем её и копируем файл
    log_message "gameinfo.gi является символьной ссылкой, преобразуем в обычный файл..." "warning"
    rm -f "$GAMEINFO_CONTAINER"
    if [ -f "$GAMEINFO_MNT" ]; then
        cp "$GAMEINFO_MNT" "$GAMEINFO_CONTAINER"
        log_message "gameinfo.gi скопирован из /mnt" "success"
    fi
fi

if [ ! -f "$GAMEINFO_CONTAINER" ]; then
    # Если файла нет - копируем из /mnt (если есть там)
    if [ -f "$GAMEINFO_MNT" ]; then
        log_message "Копируем gameinfo.gi из /mnt..." "running"
        cp "$GAMEINFO_MNT" "$GAMEINFO_CONTAINER"
        log_message "gameinfo.gi скопирован" "success"
    else
        log_message "КРИТИЧЕСКАЯ ОШИБКА: gameinfo.gi не найден ни в контейнере, ни в /mnt!" "error"
        log_message "Сервер может не запуститься. Убедитесь что SteamCMD установил игру корректно." "error"
    fi
fi

# Удаляем записи для отключенных И неустановленных аддонов из gameinfo.gi
# Если аддон установлен (папка существует), оставляем запись даже если автообновление выключено
if [ "${METAMOD_AUTOUPDATE:-0}" != "1" ] && [ ! -d "$OUTPUT_DIR/metamod" ]; then
    remove_gameinfo_entry "metamod" "MetaMod"
fi

if [ "${SWIFTLY_AUTOUPDATE:-0}" != "1" ] && [ ! -d "$OUTPUT_DIR/swiftlys2" ]; then
    remove_gameinfo_entry "swiftlys2" "Swiftly"
fi

# Проверяем порядок записей в gameinfo.gi
verify_gameinfo_order

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
