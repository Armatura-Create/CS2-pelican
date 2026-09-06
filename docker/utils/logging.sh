#!/bin/bash
set -Eeuo pipefail

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
WHITE='\033[0;37m'
NC='\033[0m'

# Лог в файл включён?
LOG_FILE_ENABLED="${LOG_FILE_ENABLED:-0}"
# Имя файла лога
LOG_FILE="${LOG_FILE:-./egg.log}"
# Храним логи 48 часов
LOG_RETENTION_HOURS="${LOG_RETENTION_HOURS:-48}"

# Префикс по умолчанию
PREFIX="${PREFIX:=${YELLOW}[ServUp]${WHITE} > }"

# Уровни логов
declare -A log_levels=(
    ["debug"]=0
    ["info"]=1
    ["running"]=2
    ["error"]=3
    ["warning"]=2
    ["success"]=1
)

# Получаем приоритет
get_level_priority() {
    local log_level="${LOG_LEVEL:-INFO}"
    case "${log_level^^}" in
        "DEBUG")   echo 0 ;;
        "INFO")    echo 1 ;;
        "WARNING") echo 2 ;;
        "ERROR")   echo 3 ;;
        *)         echo 1 ;;
    esac
}
LOG_LEVEL_PRIORITY="$(get_level_priority)"

clean_old_logs() {
    [[ "$LOG_FILE_ENABLED" == "1" ]] || return 0

    local log_dir
    log_dir="$(dirname "$LOG_FILE")"
    local log_name
    log_name="$(basename "$LOG_FILE")"

    if [[ -d "$log_dir" ]]; then
        find "$log_dir" -name "${log_name}*" -type f -mmin "+$((LOG_RETENTION_HOURS * 60))" -delete 2>/dev/null || true
    fi
}

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
            printf "%b[RUNNING] %s%b\n" "${PREFIX}${YELLOW}" "$message" "${NC}" ;;
        error)
            printf "%b[ERROR] %s%b\n" "${PREFIX}${RED}" "$message" "${NC}" ;;
        success)
            printf "%b[SUCCESS] %s%b\n" "${PREFIX}${GREEN}" "$message" "${NC}" ;;
        warning)
            printf "%b[WARNING] %s%b\n" "${PREFIX}${YELLOW}" "$message" "${NC}" ;;
        debug)
            printf "%b[DEBUG] %s%b\n" "${PREFIX}${WHITE}" "$message" "${NC}" ;;
        info|*)
            printf "%b[INFO] %s%b\n" "${PREFIX}${WHITE}" "$message" "${NC}" ;;
    esac >&2

    if [[ "$LOG_FILE_ENABLED" == "1" ]]; then
        echo "[$timestamp] [$type] $message" >> "$LOG_FILE"
    fi
}

handle_error() {
    local exit_code=$?
    local line_number="${1:-}"
    local last_command="${2:-$BASH_COMMAND}"

    case $exit_code in
        0) return 0 ;;
        127)
            log_message "Команда не найдена: $last_command" "error"
            ;;
        *)
            log_message "Ошибка в строке $line_number: $last_command" "error"
            log_message "Код выхода: $exit_code" "error"
            ;;
    esac
    return $exit_code
}
