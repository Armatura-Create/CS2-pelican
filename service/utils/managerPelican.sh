#!/bin/bash
set -Eeuo pipefail
trap 'handle_error "$LINENO" "$BASH_COMMAND"' ERR

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/logging.sh"

# ВАЖНО: теперь используем PELICAN_IMAGE без дефолта "dev" или "latest"
# Чтобы не возникало ситуаций, что stop ищет одни, а start ищет другие.

pelican_base_url() {
    echo "${PELICAN_URL%/}"
}

get_servers_by_image_app() {
    local image_filter="${1:-}"
    if [ -z "$image_filter" ]; then
        log_message "get_servers_by_image_app: не указан image_filter" "error"
        return 1
    fi

    if [ -z "${PELICAN_URL:-}" ] || [ -z "${PELICAN_APP_TOKEN:-}" ]; then
        log_message "Отсутствуют PELICAN_URL / PELICAN_APP_TOKEN" "error"
        return 1
    fi

    if [ -z "${PELICAN_NODE_ID:-}" ]; then
        log_message "Не задан PELICAN_NODE_ID" "error"
        return 1
    fi

    local base_url api_url response body http_code
    base_url="$(pelican_base_url)"
    api_url="${base_url}/api/application/servers?per_page=100"

    response="$(curl -s -w "\n%{http_code}" \
        -H "Authorization: Bearer $PELICAN_APP_TOKEN" \
        -H "Accept: application/json" \
        "$api_url")"

    body="$(echo "$response" | head -n -1)"
    http_code="$(echo "$response" | tail -n1)"

    if [[ "$http_code" -lt 200 || "$http_code" -gt 299 ]]; then
        log_message "Не удалось получить список серверов (application API), HTTP $http_code" "error"
        log_message "URL: $api_url" "warning"
        if [ -n "$body" ]; then
            log_message "Ответ: $body" "warning"
        fi
        if [ "$http_code" = "404" ]; then
            log_message "404 — проверьте PELICAN_URL в .env (без лишнего пути, без / в конце) и ./test-pelican.sh" "warning"
        fi
        return 1
    fi

    local server_ids
    server_ids="$(echo "$body" | jq -r \
        --arg IMG "$image_filter" \
        --argjson NODE "$PELICAN_NODE_ID" '
        .data[]
        | select(
            .attributes.container.image == $IMG
            and .attributes.node == $NODE
        )
        | .attributes.identifier
    ')"

    if [ -z "$server_ids" ]; then
        echo ""
        return 0
    fi

    echo "$server_ids"
}

is_server_running_client() {
    local identifier="$1"
    if [ -z "$identifier" ]; then
        log_message "is_server_running_client: не указан identifier" "error"
        return 1
    fi

    if [ -z "${PELICAN_URL:-}" ] || [ -z "${PELICAN_API_TOKEN:-}" ]; then
        log_message "Отсутствуют PELICAN_URL / PELICAN_API_TOKEN" "error"
        return 1
    fi

    local response body http_code base_url
    base_url="$(pelican_base_url)"
    response="$(curl -s -w "\n%{http_code}" \
      -H "Authorization: Bearer $PELICAN_API_TOKEN" \
      -H "Accept: application/json" \
      "${base_url}/api/client/servers/${identifier}/resources")"

    body="$(echo "$response" | head -n -1)"
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
    fi
    return 1
}

get_running_servers_by_image() {
    local image_filter="$1"
    if [ -z "$image_filter" ]; then
        log_message "get_running_servers_by_image: не указан image_filter" "error"
        return 1
    fi

    local all_servers
    all_servers="$(get_servers_by_image_app "$image_filter")" || {
        log_message "Pelican API недоступен — продолжаем без управления серверами." "warning"
        echo ""
        return 0
    }
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

send_command() {
    local server_identifier="$1"
    local command="$2"

    if [ -z "$server_identifier" ] || [ -z "$command" ]; then
        log_message "send_command: не указаны server_identifier или command" "error"
        return 1
    fi

    if [ -z "${PELICAN_URL:-}" ] || [ -z "${PELICAN_API_TOKEN:-}" ]; then
        log_message "Отсутствуют PELICAN_URL / PELICAN_API_TOKEN" "error"
        return 1
    fi

    # Доп. проверка: сервер запущен?
    if ! is_server_running_client "$server_identifier"; then
        log_message "Сервер $server_identifier не в статусе running. Пропускаем команду [$command]." "debug"
        return 0
    fi

    local response body http_code base_url
    base_url="$(pelican_base_url)"
    response="$(curl -s -w "\n%{http_code}" -X POST \
      -H "Authorization: Bearer $PELICAN_API_TOKEN" \
      -H "Content-Type: application/json" \
      --data "{\"command\":\"$command\"}" \
      "${base_url}/api/client/servers/$server_identifier/command")"

    body="$(echo "$response" | head -n -1)"
    http_code="$(echo "$response" | tail -n1)"

    if [[ "$http_code" -lt 200 || "$http_code" -gt 299 ]]; then
        log_message "Ошибка отправки команды [$command] на сервер $server_identifier, HTTP $http_code" "error"
        log_message "Ответ: $body" "debug"
        return 0
    fi

    log_message "Отправлена команда [$command] на сервер $server_identifier" "debug"
}

power_action() {
    local server_identifier="$1"
    local action="$2"
    local valid_signals=("start" "stop" "restart" "kill")

    if [[ ! " ${valid_signals[*]} " =~ " ${action} " ]]; then
        log_message "Недопустимый сигнал power_action: $action" "error"
        return 1
    fi

    if [ -z "${PELICAN_URL:-}" ] || [ -z "${PELICAN_API_TOKEN:-}" ]; then
        log_message "Отсутствуют PELICAN_URL / PELICAN_API_TOKEN" "error"
        return 1
    fi

    local response body http_code base_url
    base_url="$(pelican_base_url)"
    response="$(curl -s -w "\n%{http_code}" \
      "${base_url}/api/client/servers/$server_identifier/power" \
      -H "Accept: application/json" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer $PELICAN_API_TOKEN" \
      -X POST \
      -d "{\"signal\": \"$action\"}")"

    body="$(echo "$response" | head -n -1)"
    http_code="$(echo "$response" | tail -n1)"

    if [[ "$http_code" -lt 200 || "$http_code" -gt 299 ]]; then
        log_message "Сбой power_action '$action' на сервере $server_identifier (HTTP $http_code)" "error"
        log_message "Ответ: $body" "debug"
        return 0
    fi

    log_message "Выполнен power_action [$action] на сервере $server_identifier" "debug"
}
