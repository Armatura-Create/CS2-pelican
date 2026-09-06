#!/bin/bash
set -Eeuo pipefail
trap 'handle_error "$LINENO" "$BASH_COMMAND"' ERR

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/logging.sh"

# ВАЖНО: используем PELICAN_IMAGE без дефолта "dev"/"latest",
# чтобы stop и start не искали разные образы.

pelican_base_url() {
    echo "${PELICAN_URL%/}"
}

# Один запрос к API. Результат кладём в PELICAN_BODY / PELICAN_CODE.
# Транспортная ошибка curl (DNS, обрыв, таймаут) даёт код 000: без `|| raw=...`
# неудачное присваивание под `set -e` роняло весь updater.
PELICAN_BODY=""
PELICAN_CODE="000"
pelican_request() {
    local method="$1" url="$2" token="$3" data="${4:-}"

    local -a args=(
        -sS --connect-timeout 10 --max-time 30
        -w $'\n%{http_code}'
        -X "$method"
        -H "Authorization: Bearer $token"
        -H "Accept: application/json"
    )
    [ -n "$data" ] && args+=(-H "Content-Type: application/json" --data "$data")

    local raw
    raw="$(curl "${args[@]}" "$url" 2>/dev/null)" || raw=$'\n000'

    PELICAN_BODY="$(printf '%s' "$raw" | head -n -1)"
    PELICAN_CODE="$(printf '%s' "$raw" | tail -n1)"
    [ -n "$PELICAN_CODE" ] || PELICAN_CODE="000"
}

pelican_ok() {
    [[ "$PELICAN_CODE" =~ ^2[0-9][0-9]$ ]]
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

    local api_url
    api_url="$(pelican_base_url)/api/application/servers?per_page=100"
    pelican_request GET "$api_url" "$PELICAN_APP_TOKEN"

    if ! pelican_ok; then
        log_message "Не удалось получить список серверов (application API), HTTP $PELICAN_CODE" "error"
        log_message "URL: $api_url" "warning"
        [ -n "$PELICAN_BODY" ] && log_message "Ответ: $PELICAN_BODY" "warning"
        case "$PELICAN_CODE" in
            000) log_message "Панель недоступна с этого хоста (сеть, DNS или таймаут)." "warning" ;;
            404) log_message "404 — проверьте PELICAN_URL в .env (без лишнего пути и / в конце) и ./test-pelican.sh" "warning" ;;
        esac
        return 1
    fi

    local server_ids
    server_ids="$(echo "$PELICAN_BODY" | jq -r \
        --arg IMG "$image_filter" \
        --argjson NODE "$PELICAN_NODE_ID" '
        .data[]
        | select(
            .attributes.container.image == $IMG
            and .attributes.node == $NODE
        )
        | .attributes.identifier
    ' 2>/dev/null || true)"

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

    pelican_request GET \
        "$(pelican_base_url)/api/client/servers/${identifier}/resources" \
        "$PELICAN_API_TOKEN"

    if ! pelican_ok; then
        log_message "Не удалось получить статус сервера (client API) $identifier, HTTP $PELICAN_CODE" "error"
        log_message "Ответ: $PELICAN_BODY" "debug"
        return 1
    fi

    local current_state
    current_state="$(echo "$PELICAN_BODY" | jq -r '.attributes.current_state // empty' 2>/dev/null || true)"
    [ "$current_state" = "running" ]
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
        [ -n "$identifier" ] || continue
        if is_server_running_client "$identifier"; then
            running_list+="$identifier"$'\n'
        fi
    done <<< "$all_servers"

    printf '%s' "$running_list"
}

# send_command <id> <команда> [skip_state_check]
# Третий аргумент пропускает опрос статуса сервера — для циклов, где список
# running получен заранее и лишний запрос на каждую итерацию не нужен.
send_command() {
    local server_identifier="$1"
    local command="$2"
    local skip_state_check="${3:-}"

    if [ -z "$server_identifier" ] || [ -z "$command" ]; then
        log_message "send_command: не указаны server_identifier или command" "error"
        return 1
    fi

    if [ -z "${PELICAN_URL:-}" ] || [ -z "${PELICAN_API_TOKEN:-}" ]; then
        log_message "Отсутствуют PELICAN_URL / PELICAN_API_TOKEN" "error"
        return 1
    fi

    if [ "$skip_state_check" != "skip_state_check" ]; then
        if ! is_server_running_client "$server_identifier"; then
            log_message "Сервер $server_identifier не в статусе running. Пропускаем команду [$command]." "debug"
            return 0
        fi
    fi

    # jq вместо ручной склейки: кавычка в тексте сообщения ломала JSON
    local payload
    payload="$(jq -nc --arg cmd "$command" '{command: $cmd}')"

    pelican_request POST \
        "$(pelican_base_url)/api/client/servers/$server_identifier/command" \
        "$PELICAN_API_TOKEN" "$payload"

    if ! pelican_ok; then
        log_message "Ошибка отправки команды [$command] на сервер $server_identifier, HTTP $PELICAN_CODE" "error"
        log_message "Ответ: $PELICAN_BODY" "debug"
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

    local payload
    payload="$(jq -nc --arg sig "$action" '{signal: $sig}')"

    pelican_request POST \
        "$(pelican_base_url)/api/client/servers/$server_identifier/power" \
        "$PELICAN_API_TOKEN" "$payload"

    if ! pelican_ok; then
        log_message "Сбой power_action '$action' на сервере $server_identifier (HTTP $PELICAN_CODE)" "error"
        log_message "Ответ: $PELICAN_BODY" "debug"
        return 0
    fi

    log_message "Выполнен power_action [$action] на сервере $server_identifier" "debug"
}
