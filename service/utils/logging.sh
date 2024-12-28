#!/bin/bash

# Colors and constants
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
WHITE='\033[0;37m'
NC='\033[0m'

# Default values using proper bash parameter expansion
LOG_FILE_ENABLED="${LOG_FILE_ENABLED:=0}"
LOG_FILE="${LOG_FILE:=./egg.log}"
LOG_RETENTION_HOURS="${LOG_RETENTION_HOURS:=48}"
PREFIX="${PREFIX:=${YELLOW}[ServUp]${WHITE} > }"

# Pre-calculate log level priority
declare -A log_levels=(
    ["debug"]=0
    ["info"]=1
    ["running"]=2
    ["error"]=3
)

log_message() {
    local message="$1"
    local type="${2:-info}"
    local msg_priority="${log_levels[$type]:-1}"

    # Format message
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    message="${message%[[:space:]]}"

    # Console output with color
    case "$type" in
        running) printf "%b%s%b\n" "${PREFIX}${YELLOW}" "$message" "${NC}" ;;
        error)   printf "%b%s%b\n" "${PREFIX}${RED}" "$message" "${NC}" ;;
        success) printf "%b%s%b\n" "${PREFIX}${GREEN}" "$message" "${NC}" ;;
        debug)   printf "%b[DEBUG] %s%b\n" "${PREFIX}${WHITE}" "$message" "${NC}" ;;
        *)       printf "%b%s%b\n" "${PREFIX}${WHITE}" "$message" "${NC}" ;;
    esac
}

handle_error() {
    local exit_code=$?
    local line_number="${1:-}"
    local last_command="${2:-$BASH_COMMAND}"

    # Handle specific error cases
    case $exit_code in
        127)
            log_message "Command not found: $last_command" "error"
            log_message "Exit code: 127" "error"
            ;;
        0)
            return 0
            ;;
        *)
            if [[ $last_command != *"eval ${STEAMCMD}"* ]]; then
                log_message "Error on line $line_number: $last_command" "error"
                log_message "Exit code: $exit_code" "error"
            fi
            ;;
    esac

    return $exit_code
}