#!/bin/bash
set -Eeuo pipefail
trap 'handle_error "$LINENO" "$BASH_COMMAND"' ERR

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/logging.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/managerPelican.sh"

UPDATE_IN_PROGRESS=0

get_game_version() {
    local steam_inf="${BASE_DIR:-/home/cs2_base}/server/game/csgo/steam.inf"
    if [ -f "$steam_inf" ]; then
        local patch_version
        # grep "PatchVersion=" | cut -f2
        patch_version="$(grep "PatchVersion=" "$steam_inf" | cut -d'=' -f2 || true)"
        echo "${patch_version//./}"
    else
        echo ""
    fi
}

check_server_version() {
    # 1) Если обновление уже идёт
    if [ "$UPDATE_IN_PROGRESS" -eq 1 ]; then
        return 0
    fi

    local current_version
    current_version="$(get_game_version)"
    if [ -z "$current_version" ]; then
        log_message "Не удалось определить локальную версию (steam.inf не найден)" "error"
        return 404
    fi

    local api_url="https://api.steampowered.com/ISteamApps/UpToDateCheck/v0001/?appid=730&version=$current_version&nocache=$(date +%s)"
    api_url="$(echo "$api_url" | tr -d '[:space:]')"

    local response
    response="$(curl -s -w "%{http_code}" "$api_url")"

    local http_status="${response: -3}"
    response="${response::-3}"

    if [ "$http_status" -ne 200 ]; then
        log_message "Ошибка Steam API. HTTP-статус: $http_status" "error"
        return 0
    fi

    if [ -z "$response" ]; then
        log_message "Пустой ответ от Steam API." "error"
        return 500
    fi

    if ! echo "$response" | jq . >/dev/null 2>&1; then
        log_message "Некорректный JSON от Steam API: $response" "error"
        return 500
    fi

    local up_to_date
    up_to_date="$(echo "$response" | jq -r '.response.up_to_date')"
    if [ "$up_to_date" = "false" ]; then
        local required_version
        required_version="$(echo "$response" | jq -r '.response.required_version')"
        local message
        message="$(echo "$response" | jq -r '.response.message')"

        log_message "Доступна новая версия CS2: $required_version (текущая $current_version)" "running"
        log_message "Сообщение Steam: $message" "debug"
        return 200
    fi

    log_message "Сервер уже на актуальной версии: $current_version" "debug"
    return 0
}

inform_players_and_wait() {
    local countdown_time="${1:-300}"
    local msg_file="configs/message.json"
    [ -f "$msg_file" ] || return 0

    local lines
    lines="$(jq -r '.restart_countdown | to_entries | .[] | "\(.key) \(.value)"' "$msg_file" 2>/dev/null || true)"
    [ -n "$lines" ] || return 0

    local start_time
    start_time="$(date +%s)"

    # Берём список серверов, которые running
    local servers
    servers="$(get_running_servers_by_image "${PELICAN_IMAGE:-}")" || servers=""

    while IFS=' ' read -r seconds message || [ -n "$seconds" ]; do
        [[ "$seconds" =~ ^[0-9]+$ ]] || continue
        local s_val="$seconds"
        if [ "$s_val" -gt "$countdown_time" ]; then
            continue
        fi

        local target_time=$((start_time + (countdown_time - s_val)))
        local now
        now="$(date +%s)"
        local wait_time=$((target_time - now))
        if [ "$wait_time" -gt 0 ]; then
            sleep "$wait_time"
        fi

        if [ -n "$servers" ]; then
            while IFS= read -r srv_id; do
                send_command "$srv_id" "say $message"
            done <<< "$servers"
        fi
    done <<< "$lines"

    local final_now
    final_now="$(date +%s)"
    local used=$((final_now - start_time))
    local leftover=$((countdown_time - used))
    if [ "$leftover" -gt 0 ]; then
        sleep "$leftover"
    fi
}

stop_running_servers_for_update() {
    # Останавливаем сервера, которые сейчас running
    local servers
    servers="$(get_running_servers_by_image "${PELICAN_IMAGE:-}")" || servers=""
    if [ -z "$servers" ]; then
        echo ""
        return 0
    fi

    while IFS= read -r srv_id; do
        [ -n "$srv_id" ] || continue
        log_message "Останавливаем сервер $srv_id" "running"
        power_action "$srv_id" "stop" || true
    done <<< "$servers"

    echo "$servers"
}

start_servers_with_delay() {
    local servers_list="$1"
    if [ -z "$servers_list" ]; then
        return 0
    fi

    while IFS= read -r srv_id; do
        [ -n "$srv_id" ] || continue
        log_message "Запускаем сервер $srv_id" "running"
        power_action "$srv_id" "start" || true
        sleep 10
    done <<< "$servers_list"
}
