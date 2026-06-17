#!/bin/bash
set -Eeuo pipefail

source "./utils/logging.sh"

PASS=0
FAIL=0

check_ok() {
    log_message "$1" "success"
    ((PASS++)) || true
}

check_fail() {
    log_message "$1" "error"
    ((FAIL++)) || true
}

check_warn() {
    log_message "$1" "warning"
}

api_request() {
    local method="$1"
    local url="$2"
    local token="$3"
    local data="${4:-}"

    local curl_args=(
        -s -w "\n%{http_code}"
        -X "$method"
        -H "Authorization: Bearer $token"
        -H "Accept: application/json"
    )

    if [ -n "$data" ]; then
        curl_args+=(-H "Content-Type: application/json" --data "$data")
    fi

    curl "${curl_args[@]}" "$url"
}

parse_response() {
    local response="$1"
    RESPONSE_BODY="$(echo "$response" | head -n -1)"
    RESPONSE_CODE="$(echo "$response" | tail -n1)"
}

load_env() {
    if [ -f ".env" ]; then
        # shellcheck disable=SC1091
        source ".env"
        log_message "Загружен .env" "info"
    else
        log_message ".env не найден. Запустите ./install.sh или создайте .env вручную." "error"
        exit 1
    fi

    : "${PELICAN_URL:?PELICAN_URL не задан}"
    : "${PELICAN_APP_TOKEN:?PELICAN_APP_TOKEN не задан}"
    : "${PELICAN_API_TOKEN:?PELICAN_API_TOKEN не задан}"
    : "${PELICAN_IMAGE:?PELICAN_IMAGE не задан}"
    : "${PELICAN_NODE_ID:?PELICAN_NODE_ID не задан}"

    PELICAN_URL="${PELICAN_URL%/}"

    if [ "$PELICAN_APP_TOKEN" = "$PELICAN_API_TOKEN" ]; then
        check_warn "PELICAN_APP_TOKEN и PELICAN_API_TOKEN совпадают — для Client API нужен отдельный ключ"
    fi
}

explain_client_api_error() {
    local http_code="$1"
    local body="$2"

    if [ "$http_code" = "403" ] && echo "$body" | grep -qi "application API key"; then
        log_message "В PELICAN_API_TOKEN указан Application API ключ. Нужен Client API ключ." "error"
        log_message "Создайте его: панель → Account → API Credentials → Client API → Create." "warning"
        return 0
    fi

    if [ "$http_code" = "401" ]; then
        log_message "Токен недействителен или отозван. Создайте новый Client API ключ." "warning"
        return 0
    fi

    if [ "$http_code" = "403" ]; then
        log_message "Доступ запрещён. Проверьте тип ключа, IP whitelist и права на сервер." "warning"
    fi
}

test_panel_reachable() {
    log_message "Проверка доступности панели: $PELICAN_URL" "running"

    local http_code
    http_code="$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 10 --max-time 20 "$PELICAN_URL" || true)"

    if [[ "$http_code" =~ ^[23] ]]; then
        check_ok "Панель отвечает (HTTP $http_code)"
    else
        check_fail "Панель недоступна или вернула HTTP $http_code"
    fi
}

test_application_api() {
    log_message "Проверка Application API (PELICAN_APP_TOKEN)..." "running"

    local response
    response="$(api_request GET "${PELICAN_URL}/api/application/servers?per_page=100" "$PELICAN_APP_TOKEN")"
    parse_response "$response"

    if [[ "$RESPONSE_CODE" -lt 200 || "$RESPONSE_CODE" -gt 299 ]]; then
        check_fail "Application API: HTTP $RESPONSE_CODE"
        log_message "Ответ: $RESPONSE_BODY" "info"
        return 0
    fi

    if ! echo "$RESPONSE_BODY" | jq . >/dev/null 2>&1; then
        check_fail "Application API: ответ не является валидным JSON"
        return 0
    fi

    local total
    total="$(echo "$RESPONSE_BODY" | jq -r '.data | length')"
    check_ok "Application API: получен список серверов ($total шт.)"

    local matched
    matched="$(echo "$RESPONSE_BODY" | jq -r \
        --arg IMG "$PELICAN_IMAGE" \
        --argjson NODE "$PELICAN_NODE_ID" '
        [.data[]
            | select(
                .attributes.container.image == $IMG
                and .attributes.node == $NODE
            )
            | "\(.attributes.identifier) | \(.attributes.name) | node=\(.attributes.node) | image=\(.attributes.container.image)"
        ] | .[]' 2>/dev/null || true)"

    if [ -z "$matched" ]; then
        check_warn "Серверы с PELICAN_IMAGE=$PELICAN_IMAGE и PELICAN_NODE_ID=$PELICAN_NODE_ID не найдены"
        log_message "Проверьте, что образ в egg совпадает с PELICAN_IMAGE и NODE ID указан верно." "warning"
        TEST_SERVER_ID=""
        return 0
    fi

    check_ok "Найдены серверы с нужным образом и нодой:"
    while IFS= read -r line; do
        log_message "  - $line" "info"
    done <<< "$matched"

    TEST_SERVER_ID="$(echo "$RESPONSE_BODY" | jq -r \
        --arg IMG "$PELICAN_IMAGE" \
        --argjson NODE "$PELICAN_NODE_ID" '
        [.data[]
            | select(
                .attributes.container.image == $IMG
                and .attributes.node == $NODE
            )
            | .attributes.identifier
        ][0]')"
}

test_client_account() {
    log_message "Проверка Client API — аккаунт (PELICAN_API_TOKEN)..." "running"

    local response
    response="$(api_request GET "${PELICAN_URL}/api/client/account" "$PELICAN_API_TOKEN")"
    parse_response "$response"

    if [[ "$RESPONSE_CODE" -lt 200 || "$RESPONSE_CODE" -gt 299 ]]; then
        check_fail "Client API /account: HTTP $RESPONSE_CODE"
        log_message "Ответ: $RESPONSE_BODY" "info"
        explain_client_api_error "$RESPONSE_CODE" "$RESPONSE_BODY"
        return 0
    fi

    local email
    email="$(echo "$RESPONSE_BODY" | jq -r '.attributes.email // .attributes.username // "unknown"')"
    check_ok "Client API: токен валиден (аккаунт: $email)"
}

test_client_server_resources() {
    if [ -z "${TEST_SERVER_ID:-}" ]; then
        check_warn "Пропускаем проверку /resources — нет сервера для теста"
        return 0
    fi

    log_message "Проверка Client API — статус сервера $TEST_SERVER_ID..." "running"

    local response
    response="$(api_request GET "${PELICAN_URL}/api/client/servers/${TEST_SERVER_ID}/resources" "$PELICAN_API_TOKEN")"
    parse_response "$response"

    if [[ "$RESPONSE_CODE" -lt 200 || "$RESPONSE_CODE" -gt 299 ]]; then
        check_fail "Client API /resources: HTTP $RESPONSE_CODE (сервер $TEST_SERVER_ID)"
        log_message "Ответ: $RESPONSE_BODY" "info"
        explain_client_api_error "$RESPONSE_CODE" "$RESPONSE_BODY"
        return 0
    fi

    local state
    state="$(echo "$RESPONSE_BODY" | jq -r '.attributes.current_state // "unknown"')"
    check_ok "Client API: статус сервера $TEST_SERVER_ID = $state"
}

test_client_permissions() {
    if [ -z "${TEST_SERVER_ID:-}" ]; then
        check_warn "Пропускаем проверку прав — нет сервера для теста"
        return 0
    fi

    log_message "Проверка Client API — права на сервер $TEST_SERVER_ID..." "running"

    local response
    response="$(api_request GET "${PELICAN_URL}/api/client/servers/${TEST_SERVER_ID}" "$PELICAN_API_TOKEN")"
    parse_response "$response"

    if [[ "$RESPONSE_CODE" -lt 200 || "$RESPONSE_CODE" -gt 299 ]]; then
        check_fail "Client API /servers/{id}: HTTP $RESPONSE_CODE"
        log_message "Ответ: $RESPONSE_BODY" "info"
        explain_client_api_error "$RESPONSE_CODE" "$RESPONSE_BODY"
        return 0
    fi

    local can_control can_command
    can_control="$(echo "$RESPONSE_BODY" | jq -r '.attributes.relationships.permissions.attributes.control // "unknown"')"
    can_command="$(echo "$RESPONSE_BODY" | jq -r '.attributes.relationships.permissions.attributes.command // "unknown"')"

    if [ "$can_control" = "true" ] || [ "$can_control" = "1" ]; then
        check_ok "Есть право control (start/stop/restart)"
    else
        check_fail "Нет права control — updater не сможет останавливать/запускать серверы"
    fi

    if [ "$can_command" = "true" ] || [ "$can_command" = "1" ]; then
        check_ok "Есть право command (say и др.)"
    else
        check_fail "Нет права command — updater не сможет оповещать игроков"
    fi
}

main() {
    log_message "Тест подключения к Pelican Panel" "info"
    log_message "────────────────────────────────────" "info"

    load_env
    test_panel_reachable
    test_application_api
    test_client_account
    test_client_server_resources
    test_client_permissions

    log_message "────────────────────────────────────" "info"
    log_message "Итого: успешно $PASS, ошибок $FAIL" "$([ "$FAIL" -eq 0 ] && echo success || echo error)"

    if [ "$FAIL" -gt 0 ]; then
        exit 1
    fi
}

main
