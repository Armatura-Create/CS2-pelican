#!/bin/bash
set -Eeuo pipefail
trap 'handle_error "$LINENO" "$BASH_COMMAND"' ERR

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/logging.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/managerPelican.sh"

get_game_version() {
    local steam_inf="${BASE_DIR:-/home/cs2_base}/server/game/csgo/steam.inf"
    if [ -f "$steam_inf" ]; then
        local patch_version
        patch_version="$(grep "PatchVersion=" "$steam_inf" | cut -d'=' -f2 || true)"
        echo "${patch_version//./}"
    else
        echo ""
    fi
}

# 0 — вышло обновление CS2, 1 — обновление не требуется либо проверить не удалось.
# Вызывать только как условие (`if update_available; then`): тогда bash глушит
# ERR-трап на неудачных командах внутри.
update_available() {
    local current_version
    current_version="$(get_game_version)"
    if [ -z "$current_version" ]; then
        log_message "Не удалось определить локальную версию (steam.inf не найден)" "error"
        return 1
    fi

    local api_url="https://api.steampowered.com/ISteamApps/UpToDateCheck/v0001/?appid=${SRCDS_APPID:-730}&version=$current_version&nocache=$(date +%s)"

    local raw
    raw="$(curl -sS --connect-timeout 10 --max-time 30 -w $'\n%{http_code}' "$api_url" 2>/dev/null)" || raw=$'\n000'

    local response http_status
    response="$(printf '%s' "$raw" | head -n -1)"
    http_status="$(printf '%s' "$raw" | tail -n1)"

    if [ "$http_status" != "200" ]; then
        log_message "Steam API недоступен (HTTP $http_status). Повторим на следующей итерации." "warning"
        return 1
    fi

    if ! echo "$response" | jq -e . >/dev/null 2>&1; then
        log_message "Некорректный JSON от Steam API: $response" "error"
        return 1
    fi

    local up_to_date
    up_to_date="$(echo "$response" | jq -r '.response.up_to_date // empty')"

    if [ "$up_to_date" = "false" ]; then
        local required_version message
        required_version="$(echo "$response" | jq -r '.response.required_version // "?"')"
        message="$(echo "$response" | jq -r '.response.message // ""')"

        log_message "Доступна новая версия CS2: $required_version (текущая $current_version)" "running"
        [ -n "$message" ] && log_message "Сообщение Steam: $message" "debug"
        return 0
    fi

    log_message "Сервер уже на актуальной версии: $current_version" "debug"
    return 1
}

# Оповещение о рестарте через плагин NotifyMessages.
#
# Плагин НЕ ведёт отсчёт сам: команда css_restart_notify <секунды> рендерит одно
# сообщение для переданного числа. Что показать на конкретной секунде, решает
# RestartNotify.Thresholds / DefaultMessage в Settings.json плагина — при пустом
# DefaultMessage лишние секунды не печатаются вовсе.
# Поэтому шлём команду на каждую секунду от countdown до 1: пропуск секунды
# означал бы потерю точной отсечки (совпадение в Thresholds строгое).
#
# Длительность отсчёта задаёт UPDATE_COUNTDOWN_TIME в .env.
inform_players_and_wait() {
    local countdown="${1:-300}"
    [ "$countdown" -gt 0 ] 2>/dev/null || return 0

    local servers
    servers="$(get_running_servers_by_image "${PELICAN_IMAGE:-}")" || servers=""
    if [ -z "$servers" ]; then
        log_message "Нет запущенных серверов — оповещать некого, просто ждём $countdown сек." "debug"
        sleep "$countdown"
        return 0
    fi

    local start_time end_time
    start_time="$(date +%s)"
    end_time=$((start_time + countdown))

    log_message "Оповещаем игроков командой css_restart_notify, отсчёт $countdown сек." "running"

    local s now target
    for (( s = countdown; s >= 1; s-- )); do
        while IFS= read -r srv_id; do
            [ -n "$srv_id" ] || continue
            # skip_state_check: список running получен выше, а опрос статуса на
            # каждую секунду удвоил бы число запросов к панели
            send_command "$srv_id" "css_restart_notify $s" skip_state_check || true
        done <<< "$servers"

        # Абсолютное расписание: тик для «осталось s» приходится на end_time-s,
        # поэтому задержки API не накапливаются в дрейф.
        target=$((end_time - s + 1))
        now="$(date +%s)"
        if [ "$target" -gt "$now" ]; then
            sleep $((target - now))
        fi
    done

    now="$(date +%s)"
    if [ "$end_time" -gt "$now" ]; then
        sleep $((end_time - now))
    fi
}

# Печатает в stdout список остановленных серверов (по одному id на строку).
# Лог идёт в stderr (см. logging.sh), поэтому вывод чистый.
stop_running_servers_for_update() {
    local servers
    servers="$(get_running_servers_by_image "${PELICAN_IMAGE:-}")" || servers=""
    if [ -z "$servers" ]; then
        return 0
    fi

    while IFS= read -r srv_id; do
        [ -n "$srv_id" ] || continue
        log_message "Останавливаем сервер $srv_id" "running"
        power_action "$srv_id" "stop" || true
    done <<< "$servers"

    printf '%s\n' "$servers"
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
