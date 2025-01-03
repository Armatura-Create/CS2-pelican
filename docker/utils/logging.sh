#!/bin/bash

# ================================
# Цвета и базовые константы
# ================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
WHITE='\033[0;37m'
NC='\033[0m'  # Сброс цвета

# ================================
# Параметры по умолчанию (используем bash-подстановку)
# ================================
LOG_FILE_ENABLED="${LOG_FILE_ENABLED:=0}"          # Включать ли лог в файл
LOG_FILE="${LOG_FILE:=./egg.log}"                  # Файл для логов
LOG_RETENTION_HOURS="${LOG_RETENTION_HOURS:=48}"   # Сколько часов хранить логи
PREFIX="${PREFIX:=${YELLOW}[ServUp]${WHITE} > }"   # Префикс для вывода в консоль

# ================================
# Приоритеты уровней логирования
# ================================
declare -A log_levels=(
    ["debug"]=0
    ["info"]=1
    ["running"]=2
    ["error"]=3
)

# Функция для получения приоритета в зависимости от LOG_LEVEL
get_level_priority() {
    local log_level="${LOG_LEVEL:-INFO}"
    case "${log_level^^}" in
        "DEBUG") echo 0 ;;
        "INFO") echo 1 ;;
        "WARNING") echo 2 ;;
        "ERROR") echo 3 ;;
        *)       echo 1 ;;  # По умолчанию INFO
    esac
}

# Сохраняем вычисленный приоритет в переменную
LOG_LEVEL_PRIORITY=$(get_level_priority)

# ================================
# Удаление старых логов (старше заданных часов)
# ================================
clean_old_logs() {
    # Если лог в файл не включён, выходим
    [[ "${LOG_FILE_ENABLED}" == "1" ]] || return 0

    local log_dir
    local log_name

    log_dir="$(dirname "${LOG_FILE}")"
    log_name="$(basename "${LOG_FILE}")"

    # Если каталог для логов существует
    if [[ -d "${log_dir}" ]]; then
        # Удаляем все файлы, чьё имя начинается с лог-файла и чей возраст
        # превышает LOG_RETENTION_HOURS (в минутах)
        find "${log_dir}" -name "${log_name}*" -type f -mmin "+$((LOG_RETENTION_HOURS * 60))" -delete 2>/dev/null
    fi
}

# ================================
# Основная функция логирования
# ================================
log_message() {
    local message="$1"
    local type="${2:-info}"
    local msg_priority="${log_levels[$type]:-1}"

    # Если приоритет сообщения ниже порога LOG_LEVEL_PRIORITY, пропускаем вывод
    [[ ${msg_priority} -ge ${LOG_LEVEL_PRIORITY} ]] || return 0

    # Готовим метку времени
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    # Убираем лишние пробелы в конце
    message="${message%[[:space:]]}"

    # Выводим в консоль с цветами
    case "$type" in
        running)
            printf "%b%s%b\n" "${PREFIX}${YELLOW}" "$message" "${NC}"
            ;;
        error)
            printf "%b%s%b\n" "${PREFIX}${RED}" "$message" "${NC}"
            ;;
        success)
            printf "%b%s%b\n" "${PREFIX}${GREEN}" "$message" "${NC}"
            ;;
        debug)
            printf "%b[DEBUG] %s%b\n" "${PREFIX}${WHITE}" "$message" "${NC}"
            ;;
        *)
            printf "%b%s%b\n" "${PREFIX}${WHITE}" "$message" "${NC}"
            ;;
    esac

    # Если включено LOG_FILE_ENABLED, пишем в файл
    if [[ "${LOG_FILE_ENABLED}" == "1" ]]; then
        echo "[$timestamp] [$type] $message" >> "${LOG_FILE}"
    fi
}

# ================================
# Обработка ошибок (trap ERR)
# ================================
handle_error() {
    local exit_code=$?
    local line_number="${1:-}"
    local last_command="${2:-$BASH_COMMAND}"

    # Смотрим код выхода
    case $exit_code in
        127)
            log_message "Команда не найдена: $last_command" "error"
            log_message "Код выхода: 127" "error"
            ;;
        0)
            # Код выхода 0 — без ошибок
            return 0
            ;;
        *)
            # Если это не ситуация с 'eval ${STEAMCMD}', логируем ошибку
            if [[ $last_command != *"eval ${STEAMCMD}"* ]]; then
                log_message "Ошибка в строке $line_number: $last_command" "error"
                log_message "Код выхода: $exit_code" "error"
            fi
            ;;
    esac

    # Возвращаем тот же код выхода
    return $exit_code
}
