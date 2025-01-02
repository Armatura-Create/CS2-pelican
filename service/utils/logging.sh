#!/bin/bash

# Colors and constants
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
WHITE='\033[0;37m'
NC='\033[0m'

PREFIX="${YELLOW}[CS2]${WHITE} > "

declare -A log_levels=(
    ["debug"]=0
    ["info"]=1
    ["running"]=2
    ["error"]=3
)

# Выводим лог
log_message() {
    local message="$1"
    local type="${2:-info}"

    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    message="${message%[[:space:]]}"

    case "$type" in
        running)  printf "%b%s%b\n" "${PREFIX}${YELLOW}" "$message" "${NC}" ;;
        error)    printf "%b%s%b\n" "${PREFIX}${RED}" "$message" "${NC}" ;;
        success)  printf "%b%s%b\n" "${PREFIX}${GREEN}" "$message" "${NC}" ;;
        debug)    printf "%b[DEBUG] %s%b\n" "${PREFIX}${WHITE}" "$message" "${NC}" ;;
        *)        printf "%b%s%b\n" "${PREFIX}${WHITE}" "$message" "${NC}" ;;
    esac
}

# Универсальная ловушка ошибок
handle_error() {
    local exit_code=$?
    local line_number="${1:-}"
    local last_command="${2:-$BASH_COMMAND}"

    if [ $exit_code -ne 0 ]; then
        log_message "Error on line $line_number: $last_command (exit code $exit_code)" "error"
    fi
    exit $exit_code
}