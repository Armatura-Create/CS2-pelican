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
        patch_version=$(grep "PatchVersion=" "$steam_inf" | cut -d'=' -f2 || true)
        [ -n "$patch_version" ] && echo "${patch_version//./}" || echo ""
    else
        echo ""
    fi
}

check_server_version() {
    # Если уже идёт обновление, выходим
    if [ "$UPDATE_IN_PROGRESS" -eq 1 ]; then
        return 0
    fi

    local current_version
    current_version="$(get_game_version)"
    if [ -z "$current_version" ]; then
        log_message "Не удалось определить локальную версию в steam.inf" "error"
        return 404
    fi

    local api_url=$(echo "https://api.steampowered.com/ISteamApps/UpToDateCheck/v0001/?appid=730&version=$current_version&nocache=$(date +%s)" | tr -d '[:space:]')
    local response
    response="$(curl -s "$api_url" || true)"

    # Проверка на пустой ответ
    if [ -z "$response" ]; then
        log_message "API Steam не вернул ответ" "error"
        return 500
    fi

    # Проверка корректности JSON
    if ! echo "$response" | jq . > /dev/null 2>&1; then
        log_message "Некорректный JSON в ответе API Steam: $response" "error"
        return 500
    fi

    local up_to_date
    up_to_date="$(echo "$response" | jq -r '.response.up_to_date')"
    if [ "$up_to_date" = "false" ]; then
        local required_version
        required_version="$(echo "$response" | jq -r '.response.required_version')"
        local message
        message="$(echo "$response" | jq -r '.response.message')"

        log_message "Обнаружена новая версия: $required_version текущая: [$current_version]" "running"
        log_message "Steam-сообщение: $message" "debug"
        return 200
    else
        log_message "Сервер актуален: $current_version" "debug"
        return 0
    fi
}

#############################################
# Оповестить игроков на всех running-серверах
# (функция ниже: inform_players_and_wait)
#############################################
inform_players_and_wait() {
    local countdown_time="${1:-300}"
    local msg_file="configs/message.json"
    [ -f "$msg_file" ] || return 0

    local lines
    lines="$(jq -r '.restart_countdown | to_entries | .[] | "\(.key) \(.value)"' "$msg_file" 2>/dev/null || true)"
    [ -n "$lines" ] || return 0

    local start_time
    start_time=$(date +%s)

    # 1) Берём список серверов, которые running + image
    local servers
    servers="$(get_running_servers_by_image "${PELICAN_IMAGE:-docker.io/scrender/base-files-cs2:latest}")"

    while IFS=' ' read -r seconds message || [ -n "$seconds" ]; do
        [[ "$seconds" =~ ^[0-9]+$ ]] || continue
        local s_val=$((seconds))
        if [ "$s_val" -gt "$countdown_time" ]; then
            continue
        fi

        local target_time=$((start_time + (countdown_time - s_val)))
        local now
        now=$(date +%s)
        local wait_time=$((target_time - now))
        if [ "$wait_time" -gt 0 ]; then
            sleep "$wait_time"
        fi

        # Рассылаем команду на все сервера, которые всё ещё running
        if [ -n "$servers" ]; then
            while IFS= read -r srv_id; do
                send_command "$srv_id" "say $message"
            done <<< "$servers"
        fi
    done <<< "$lines"

    # Проверим, сколько осталось
    local final_now
    final_now=$(date +%s)
    local used=$((final_now - start_time))
    local leftover=$((countdown_time - used))
    if [ "$leftover" -gt 0 ]; then
        sleep "$leftover"
    fi
}

#############################################
# Останавливаем только те, что были running
# Возвращаем список идентификаторов
#############################################
stop_running_servers_for_update() {
    local servers
    servers="$(get_running_servers_by_image "${PELICAN_IMAGE:-docker.io/scrender/base-files-cs2:dev}")"
    if [ -z "$servers" ]; then
        echo ""
        return 0
    fi

    while IFS= read -r srv_id; do
        log_message "Останавливаем сервер $srv_id" "running"
        power_action "$srv_id" "stop"
    done <<< "$servers"

    # Возвращаем список, чтобы потом запускать именно их
    echo "$servers"
}

#############################################
# Запускаем с интервалом 10 сек. только те,
# что были running до остановки
#############################################
start_servers_with_delay() {
    local servers_list="$1"
    if [ -z "$servers_list" ]; then
        return 0
    fi

    while IFS= read -r srv_id; do
        log_message "Запускаем сервер $srv_id" "running"
        power_action "$srv_id" "start"
        sleep 10
    done <<< "$servers_list"
}
