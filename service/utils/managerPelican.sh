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

    # Токен — через stdin (`-H @-`), не аргументом: аргументы любого процесса
    # видны всем пользователям хоста в `ps` и /proc/<pid>/cmdline.
    local -a args=(
        -sS --connect-timeout 10 --max-time 30
        -w $'\n%{http_code}'
        -X "$method"
        -H @-
        -H "Accept: application/json"
    )
    [ -n "$data" ] && args+=(-H "Content-Type: application/json" --data "$data")

    local raw
    raw="$(printf 'Authorization: Bearer %s\n' "$token" | curl "${args[@]}" "$url" 2>/dev/null)" || raw=$'\n000'

    PELICAN_BODY="$(printf '%s' "$raw" | head -n -1)"
    PELICAN_CODE="$(printf '%s' "$raw" | tail -n1)"
    [ -n "$PELICAN_CODE" ] || PELICAN_CODE="000"
}

pelican_ok() {
    [[ "$PELICAN_CODE" =~ ^2[0-9][0-9]$ ]]
}

# CS2-серверы ноды: JSON-массив атрибутов из application API (с allocations и
# переменными окружения) — по ВСЕМ страницам. Общий источник для updater'а и guard.
# Образ сравниваем без тега: egg предлагает :latest и :dev, и серверы на :dev
# раньше не гасились перед обновлением, а SteamCMD переписывал /mnt прямо под ними.
# Без листания страниц (per_page=100) терялись серверы на большой панели.
# pelican_node_servers [образ] — по умолчанию PELICAN_IMAGE. Результат — в
# NODE_SERVERS, а не в stdout: вызов внутри $( ) потерял бы PELICAN_CODE для лога.
# 1 — панель не ответила или ответ не разобран (код — в PELICAN_CODE).
NODE_SERVERS="[]"
pelican_node_servers() {
    local image="${1:-${PELICAN_IMAGE:-}}"
    if [ -z "${PELICAN_URL:-}" ] || [ -z "${PELICAN_APP_TOKEN:-}" ] \
        || [[ ! "${PELICAN_NODE_ID:-}" =~ ^[0-9]+$ ]] || [ -z "$image" ]; then
        log_message "Нужны PELICAN_URL, PELICAN_APP_TOKEN, PELICAN_NODE_ID и PELICAN_IMAGE в .env" "error"
        PELICAN_CODE="000"
        return 1
    fi

    local page=1 pages=1 found=""
    while [ "$page" -le "$pages" ]; do
        pelican_request GET \
            "$(pelican_base_url)/api/application/servers?include=allocations&per_page=100&page=$page" \
            "$PELICAN_APP_TOKEN"
        pelican_ok || return 1
        found+="$(printf '%s' "$PELICAN_BODY" | jq -c --arg img "$image" --argjson node "$PELICAN_NODE_ID" '
            def repo: sub(":[^:/]*$"; "");
            [.data[].attributes
             | select(.node == $node and ((.container.image // "") | repo) == ($img | repo))]')" || return 1
        found+=$'\n'
        pages="$(printf '%s' "$PELICAN_BODY" | jq -r '.meta.pagination.total_pages // 1' 2>/dev/null || echo 1)"
        [[ "$pages" =~ ^[0-9]+$ ]] || pages=1
        page=$((page + 1))
    done
    NODE_SERVERS="$(printf '%s' "$found" | jq -cs 'add // []')" || return 1
}

# Идентификаторы CS2-серверов ноды, по одному на строку.
get_servers_by_image_app() {
    if ! pelican_node_servers "${1:-}"; then
        log_message "Не удалось получить список серверов (application API), HTTP $PELICAN_CODE" "error"
        case "$PELICAN_CODE" in
            000) log_message "Панель недоступна с этого хоста (сеть, DNS или таймаут)." "warning" ;;
            404) log_message "404 — проверьте PELICAN_URL в .env (без лишнего пути и / в конце) и ./test-pelican.sh" "warning" ;;
        esac
        return 1
    fi
    printf '%s' "$NODE_SERVERS" | jq -r '.[].identifier'
}

# Порты (allocations) CS2-серверов ноды, по одному на строку, — для guard.sh.
pelican_node_ports() {
    pelican_node_servers || return 1
    printf '%s' "$NODE_SERVERS" | jq -r '.[].relationships.allocations.data[]?.attributes.port'
}

# Печатает состояние сервера: running | starting | stopping | offline,
# или unknown, если панель не ответила. Лог — в stderr, в stdout только состояние.
server_state() {
    local identifier="$1"
    if [ -z "$identifier" ]; then
        log_message "server_state: не указан identifier" "error"
        printf 'unknown'
        return 0
    fi

    if [ -z "${PELICAN_URL:-}" ] || [ -z "${PELICAN_API_TOKEN:-}" ]; then
        log_message "Отсутствуют PELICAN_URL / PELICAN_API_TOKEN" "error"
        printf 'unknown'
        return 0
    fi

    pelican_request GET \
        "$(pelican_base_url)/api/client/servers/${identifier}/resources" \
        "$PELICAN_API_TOKEN"

    if ! pelican_ok; then
        log_message "Не удалось получить статус сервера (client API) $identifier, HTTP $PELICAN_CODE" "error"
        log_message "Ответ: $PELICAN_BODY" "debug"
        printf 'unknown'
        return 0
    fi

    local current_state
    current_state="$(echo "$PELICAN_BODY" | jq -r '.attributes.current_state // empty' 2>/dev/null || true)"
    printf '%s' "${current_state:-unknown}"
}

is_server_running_client() {
    [ "$(server_state "$1")" = "running" ]
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
