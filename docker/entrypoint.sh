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
# Своя копия в контейнере (он дописывает туда аддоны, а /mnt только на чтение).
# Если Valve обновила файл вместе с CS2 — берём новую версию, см. refresh_gameinfo.
refresh_gameinfo

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

# 'unbuffer' — для корректного вывода; run-server.sh печатает код выхода
# сервера служебной строкой: сам unbuffer его не передаёт
SERVER_WRAPPER="unbuffer -p /scripts/run-server.sh"
MODIFIED_STARTUP="$SERVER_WRAPPER ${MODIFIED_STARTUP}"

# Маскируем +sv_setsteamaccount <token> в логе
LOGGED_STARTUP="$(echo "${MODIFIED_STARTUP#"$SERVER_WRAPPER" }" | \
    sed -E 's/(\+sv_setsteamaccount\s+[A-Z0-9]{32})/+sv_setsteamaccount ************************/g')"

log_message "Запускаем сервер командой: ${LOGGED_STARTUP}" "running"

# ============================
# 7) Запуск сервера + фильтрация вывода
# ============================
# Ввод консоли пропускаем через себя. Wings пишет туда команды из панели и
# `quit` при остановке — так видно, что остановку попросили. CS2 падает с
# segfault/abort на КАЖДОМ штатном выходе, поэтому раньше эти строки прятались
# всегда, вместе с настоящими падениями.
STOP_FLAG="/tmp/.cs2-stop-requested"
CONSOLE_FIFO="/tmp/.cs2-console"
CRASH_FLAG="/tmp/.cs2-crash-line"
EXIT_FILE="/tmp/.cs2-exit-code"
rm -f "$STOP_FLAG" "$CONSOLE_FIFO" "$CRASH_FLAG" "$EXIT_FILE"
mkfifo "$CONSOLE_FIFO"
# FIFO открыт и на запись, пока жив entrypoint: даже если Wings закроет stdin,
# сервер не получит EOF — CS2 без открытого stdin сразу завершается.
exec 7<>"$CONSOLE_FIFO"
# stdin — явно через fd 6: фоновой задаче без перенаправления bash отдал бы /dev/null
exec 6<&0
while IFS= read -r cmd; do
    case "${cmd//[[:space:]]/}" in
        quit|exit) : > "$STOP_FLAG" ;;
    esac
    printf '%s\n' "$cmd" >&7
done <&6 &

GSLT_HINTED=0
server_rc=0
# `|| server_rc=$?`: код выхода сервера нужен, а ERR-трап на штатной остановке —
# нет (с pipefail упавший CS2 делал весь конвейер «ошибкой в строке …»)
$MODIFIED_STARTUP <&7 2>&1 | while IFS= read -r line; do
    line="${line%[[:space:]]}"

    # Код выхода от run-server.sh — служебная строка, в консоль не идёт
    if [[ "$line" =~ ^\[cs2-exit\]\ ([0-9]+)$ ]]; then
        printf '%s' "${BASH_REMATCH[1]}" > "$EXIT_FILE"
        continue
    fi

    if [[ "$line" =~ Segmentation\ fault|Aborted.*core\ dumped ]]; then
        if [ -e "$STOP_FLAG" ]; then
            log_message "Шумный выход CS2 при остановке — так CS2 завершается всегда, это не падение: $line" "debug"
            continue
        fi
        : > "$CRASH_FLAG"
    fi

    # GSLT недействителен или просрочен: без подсказки это лишь строка в потоке
    if [ "$GSLT_HINTED" = 0 ] && [ -n "${STEAM_ACC:-}" ] \
        && [[ "$line" == *"Cert request for invalid failed"* || "$line" == *"We're not logged into Steam"* ]]; then
        GSLT_HINTED=1
        handle_server_output "$line"
        log_message "GSLT (Game Server Login Token) недействителен или просрочен — сервер не попадёт в список серверов." "warning"
        log_message "Создайте новый на https://steamcommunity.com/dev/managegameservers (App ID 730) и замените STEAM_ACC в переменных сервера." "warning"
        continue
    fi

    handle_server_output "$line"
done || server_rc=$?

# Фоновые процессы (пересылка консоли) — до выхода
pkill -P $$ 2>/dev/null || true

# Настоящий код сервера — от run-server.sh; код конвейера — это код unbuffer
if [ -s "$EXIT_FILE" ]; then
    server_rc="$(cat "$EXIT_FILE")"
fi

if [ -e "$STOP_FLAG" ]; then
    log_message "Сервер остановлен." "success"
elif [ "$server_rc" -ne 0 ] || [ -e "$CRASH_FLAG" ]; then
    log_message "Сервер упал (код выхода $server_rc). Что было перед падением — в строках выше." "error"
    log_message "Частые причины: аддон несовместим с текущей CS2 (устаревшие gamedata/сигнатуры), плагин, нехватка памяти." "error"
    # Маркер для watch.sh на хосте: по нему сохраняется отчёт о падении
    printf '[cs2-crash] code=%s\n' "$server_rc"
    exit "$(( server_rc == 0 ? 1 : server_rc ))"
else
    log_message "Сервер завершил работу." "success"
fi
