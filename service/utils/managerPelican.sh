#!/bin/bash
set -Eeuo pipefail
trap 'handle_error "$LINENO" "$BASH_COMMAND"' ERR

source "$(dirname "$0")/logging.sh"

#####################################################
# 1) Получаем список серверов по нужному image (application API)
#####################################################
get_servers_by_image_app() {
    local image_filter="${1:-}"
    if [ -z "$image_filter" ]; then
        log_message "get_servers_by_image_app: не указан image_filter" "error"
        return 1
    fi

    if [ -z "${PELICAN_URL:-}" ] || [ -z "${PELICAN_APP_TOKEN:-}" ]; then
        log_message "Не заданы PELICAN_URL или PELICAN_APP_TOKEN" "error"
        return 1
    fi

    # Получаем (per_page=100 — adjust при необходимости)
    local response
    response="$(curl -s -w "\n%{http_code}" \
      -H "Authorization: Bearer $PELICAN_APP_TOKEN" \
      -H "Accept: application/json" \
      "${PELICAN_URL}/api/application/servers?per_page=100")"

    local body
    body="$(echo "$response" | head -n -1)"
    local http_code
    http_code="$(echo "$response" | tail -n1)"

    if [[ "$http_code" -lt 200 || "$http_code" -gt 299 ]]; then
        log_message "Не удалось получить список серверов (application API), HTTP $http_code" "error"
        log_message "Ответ: $body" "debug"
        return 1
    fi

    # Фильтруем по image
    local server_ids
    server_ids="$(echo "$body" | jq -r --arg IMG "$image_filter" '
        .data[]
        | select(.attributes.container.image == $IMG)
        | .attributes.identifier
    ')"

    if [ -z "$server_ids" ]; then
        echo ""
        return 0
    fi

    echo "$server_ids"
}

#####################################################
# 2) Проверить, что сервер сейчас "running" (client API)
#####################################################
is_server_running_client() {
    local identifier="$1"
    if [ -z "$identifier" ]; then
        log_message "is_server_running_client: не указан identifier" "error"
        return 1
    fi

    if [ -z "${PELICAN_URL:-}" ] || [ -z "${PELICAN_API_TOKEN:-}" ]; then
        log_message "Не заданы PELICAN_URL или PELICAN_API_TOKEN" "error"
        return 1
    fi

    local response
    response="$(curl -s -w "\n%{http_code}" \
      -H "Authorization: Bearer $PELICAN_API_TOKEN" \
      -H "Accept: application/json" \
      "${PELICAN_URL}/api/client/servers/${identifier}/resources")"

    local body
    body="$(echo "$response" | head -n -1)"
    local http_code
    http_code="$(echo "$response" | tail -n1)"

    if [[ "$http_code" -lt 200 || "$http_code" -gt 299 ]]; then
        log_message "Не удалось получить статус сервера (client API) $identifier, HTTP $http_code" "error"
        log_message "Ответ: $body" "debug"
        return 1
    fi

    local current_state
    current_state="$(echo "$body" | jq -r '.attributes.current_state')"
    if [ "$current_state" = "running" ]; then
        return 0
    else
        return 1
    fi
}

#####################################################
# 3) Собрать только те, что running + нужный image
#####################################################
get_running_servers_by_image() {
    local image_filter="$1"
    local all_servers
    all_servers="$(get_servers_by_image_app "$image_filter")" || return 1
    if [ -z "$all_servers" ]; then
        echo ""
        return 0
    fi

    local running_list=""
    while IFS= read -r identifier; do
        if is_server_running_client "$identifier"; then
            running_list+="$identifier"$'\n'
        fi
    done <<< "$all_servers"

    echo "$running_list"
}

#####################################################
# 4) Отправка команды (client API)
#####################################################
send_command() {
    local server_identifier="$1"
    local command="$2"
    if [ -z "$server_identifier" ] || [ -z "$command" ]; then
        log_message "send_command: не заданы server_identifier или command" "error"
        return 1
    fi

    if [ -z "${PELICAN_URL:-}" ] || [ -z "${PELICAN_API_TOKEN:-}" ]; then
        log_message "Отсутствуют переменные PELICAN_URL или PELICAN_API_TOKEN" "error"
        return 1
    fi

    # Проверим, что сервер действительно running (чтобы не слать команду впустую)
    if ! is_server_running_client "$server_identifier"; then
        log_message "Сервер $server_identifier не в статусе running. Пропускаем команду [$command]." "debug"
        return 0
    fi

    local response
    response="$(curl -s -w "\n%{http_code}" -X POST \
      -H "Authorization: Bearer $PELICAN_API_TOKEN" \
      -H "Content-Type: application/json" \
      --data "{\"command\": \"$command\"}" \
      "${PELICAN_URL}/api/client/servers/$server_identifier/command")"

    local body
    body="$(echo "$response" | head -n -1)"
    local http_code
    http_code="$(echo "$response" | tail -n1)"

    if [[ "$http_code" -lt 200 || "$http_code" -gt 299 ]]; then
        log_message "Не удалось отправить команду ($command) на сервер $server_identifier, HTTP $http_code" "error"
        log_message "Ответ: $body" "debug"
        return 1
    fi

    log_message "Отправлена команда [$command] на сервер $server_identifier" "debug"
}

#####################################################
# 5) Power-экшен (start, stop, restart, kill)
#####################################################
power_action() {
    local server_identifier="$1"
    local action="$2"
    if [ -z "$server_identifier" ] || [ -z "$action" ]; then
        log_message "power_action: не заданы server_identifier или action" "error"
        return 1
    fi

    local valid_signals=("start" "stop" "restart" "kill")
    if [[ ! " ${valid_signals[*]} " =~ " ${action} " ]]; then
        log_message "Недопустимый сигнал power_action: $action" "error"
        return 1
    fi

    if [ -z "${PELICAN_URL:-}" ] || [ -z "${PELICAN_API_TOKEN:-}" ]; then
        log_message "Отсутствуют переменные PELICAN_URL или PELICAN_API_TOKEN" "error"
        return 1
    fi

    local response
    response="$(curl -s -w "\n%{http_code}" \
      "${PELICAN_URL}/api/client/servers/$server_identifier/power" \
      -H 'Accept: application/json' \
      -H 'Content-Type: application/json' \
      -H "Authorization: Bearer $PELICAN_API_TOKEN" \
      -X POST \
      -d "{\"signal\": \"$action\"}")"

    local body
    body="$(echo "$response" | head -n -1)"
    local http_code
    http_code="$(echo "$response" | tail -n1)"

    if [[ "$http_code" -lt 200 || "$http_code" -gt 299 ]]; then
        log_message "Сбой power_action '$action' на сервере $server_identifier, HTTP $http_code" "error"
        log_message "Ответ: $body" "debug"
        return 1
    fi

    log_message "Выполнен power_action [$action] на сервер $server_identifier" "debug"
}
