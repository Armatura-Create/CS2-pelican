#!/bin/bash
set -Eeuo pipefail

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
WHITE='\033[0;37m'
NC='\033[0m'

PREFIX="${YELLOW}[CS2]${WHITE} > "

# Уровни логов
declare -A log_levels=(
    ["debug"]=0
    ["info"]=1
    ["running"]=2
    ["error"]=3
    ["warning"]=2
    ["success"]=1
)

# Настройки логирования (читаем из .env)
LOG_LEVEL="${LOG_LEVEL:-INFO}"
LOG_FILE_ENABLED="${LOG_FILE_ENABLED:-1}"  # По умолч. включаем
# Пример: Base_file_log.txt-2025-05-14
# Чтобы держать файлы до 7 дней
LOG_FILE_BASENAME="Base_file_log.txt"
LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-7}"

get_level_priority() {
    case "${LOG_LEVEL^^}" in
        "DEBUG")   echo 0 ;;
        "INFO")    echo 1 ;;
        "WARNING") echo 2 ;;
        "ERROR")   echo 3 ;;
        *)         echo 1 ;;
    esac
}
LOG_LEVEL_PRIORITY="$(get_level_priority)"

# Получаем имя лога вида Base_file_log.txt-YYYY-MM-DD
get_log_filename_for_today() {
    local date_part
    date_part="$(date '+%Y-%m-%d')"
    echo "${LOG_FILE_BASENAME}-${date_part}"
}

# Очистка логов старше N дней
clean_old_logs() {
    [[ "$LOG_FILE_ENABLED" == "1" ]] || return 0

    local log_dir="./logs"  # например, храним логи в ./logs
    mkdir -p "$log_dir" 2>/dev/null || return 0

    # Удаляем файлы Base_file_log.txt-YYYY-MM-DD старше LOG_RETENTION_DAYS
    find "$log_dir" -name "${LOG_FILE_BASENAME}-*" -type f -mtime "+$LOG_RETENTION_DAYS" -exec rm -f {} \; 2>/dev/null || true
}

# При первом источнике скрипта чистим старые логи
clean_old_logs

log_message() {
    local message="$1"
    local type="${2:-info}"
    local msg_priority="${log_levels[$type]:-1}"

    [[ "$msg_priority" -ge "$LOG_LEVEL_PRIORITY" ]] || return 0

    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    message="${message%[[:space:]]}"

    case "$type" in
        running)
            >&2 printf "%b%s%b\n" "${PREFIX}${YELLOW}" "$message" "${NC}" ;;
        error)
            >&2 printf "%b%s%b\n" "${PREFIX}${RED}"   "$message" "${NC}" ;;
        success)
            >&2 printf "%b%s%b\n" "${PREFIX}${GREEN}" "$message" "${NC}" ;;
        warning)
            >&2 printf "%b[WARNING] %s%b\n" "${PREFIX}${YELLOW}" "$message" "${NC}" ;;
        debug)
            >&2 printf "%b[DEBUG] %s%b\n" "${PREFIX}${WHITE}" "$message" "${NC}" ;;
        info|*)
            >&2 printf "%b%s%b\n" "${PREFIX}${WHITE}" "$message" "${NC}" ;;
    esac

    # Пишем в файл, если включено.
    #
    # Запись — строго best-effort: файловый лог НЕ имеет права ронять апдейтер.
    # Кончилось место на разделе (CS2 — это ~40 ГБ, случается регулярно) —
    # `echo >>` возвращает 1, ERR-трап под `set -Eeuo pipefail` убивает start.sh,
    # systemd перезапускает его, за 5 падений подряд упирается в StartLimitBurst
    # и гасит юнит насовсем. То есть из-за неудачной строчки лога переставал
    # работать весь апдейтер — ровно тогда, когда он нужнее всего.
    if [[ "$LOG_FILE_ENABLED" == "1" ]]; then
        local log_dir="./logs" logfile
        if mkdir -p "$log_dir" 2>/dev/null; then
            logfile="$log_dir/$(get_log_filename_for_today)"
            echo "[$timestamp] [$type] $message" >> "$logfile" 2>/dev/null || true
        fi
    fi
}

# ВАЖНО: только логируем и возвращаем код.
# ERR-трап срабатывает даже при `set +e` (и наследуется в функции из-за `set -E`),
# поэтому `exit` здесь убивал весь updater на любой сетевой осечке curl.
handle_error() {
    local exit_code=$?
    local line_number="${1:-}"
    local last_command="${2:-$BASH_COMMAND}"

    case $exit_code in
        0) return 0 ;;
        127) log_message "Команда не найдена: $last_command" "error" ;;
        *)   log_message "Ошибка в строке $line_number: $last_command (код $exit_code)" "error" ;;
    esac
    return "$exit_code"
}
