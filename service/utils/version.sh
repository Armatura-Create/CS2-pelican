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
        # Только цифры: steam.inf от Valve приходит с CRLF, и «1.41.8.1\r»
        # превращался в «14181\r». Возврат каретки в URL curl отвергает
        # (код 3, «Malformed input»), и проверка версии падала всегда.
        echo "${patch_version//[^0-9]/}"
    else
        echo ""
    fi
}

# Steam API объявляет новую версию раньше, чем её сборка появляется в SteamCMD.
# 25.09.2026: API требовал 1.41.8.4, SteamCMD отвечал «already up to date» —
# updater оповестил игроков, погасил серверы, ничего не скачал, поднял их и
# через 5 минут начал всё заново. Поэтому до отсчёта сверяем buildid: тот, что
# SteamCMD поставит сейчас, и установленный.
# 0 — сборки совпадают, то есть качать нечего; 1 — есть что качать или не знаем.
steamcmd_build_is_current() {
    local base="${BASE_DIR:-/home/cs2_base}/server" appid="${SRCDS_APPID:-730}" branch="public"
    [[ " ${EXTRA_FLAGS:-} " =~ \ -beta\ ([^ ]+) ]] && branch="${BASH_REMATCH[1]}"

    local local_build remote_build
    local_build="$(grep -m1 '"buildid"' "$base/steamapps/appmanifest_$appid.acf" 2>/dev/null | tr -cd '0-9' || true)"
    [ -n "$local_build" ] || return 1

    # Анонимный вход: сведения о приложении публичные, а пароль в аргументах
    # был бы виден всем в ps.
    remote_build="$(timeout 120 "$base/steamcmd/steamcmd.sh" +login anonymous \
            +app_info_update 1 +app_info_print "$appid" +quit 2>/dev/null \
        | sed -n '/"branches"/,$p' | sed -n "/\"$branch\"/,/}/p" \
        | grep -m1 '"buildid"' | tr -cd '0-9' || true)"
    [ -n "$remote_build" ] || return 1

    STEAMCMD_BUILD="$local_build"
    [ "$remote_build" = "$local_build" ]
}

# Сколько ждать, пока SteamCMD увидит объявленную версию, прежде чем обновляться
# по одним данным Steam API. Страховка: если сведения SteamCMD залипнут, игра не
# должна перестать обновляться совсем.
STEAMCMD_LAG_MAX=3600
STEAMCMD_LAG_VERSION=""
STEAMCMD_LAG_SINCE=0

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

    local raw curl_rc=0
    raw="$(curl -sS --connect-timeout 10 --max-time 30 -w $'\n%{http_code}' "$api_url" 2>/dev/null)" || curl_rc=$?
    [ "$curl_rc" -eq 0 ] || raw=$'\n000'

    local response http_status
    response="$(printf '%s' "$raw" | head -n -1)"
    http_status="$(printf '%s' "$raw" | tail -n1)"

    if [ "$http_status" != "200" ]; then
        # Код curl обязателен: «HTTP 000» одинаково выглядит и для упавшей сети
        # (6 — DNS, 7 — соединение, 28 — таймаут), и для кривого URL (3).
        # Без него неделю искали сеть, а ломался запрос.
        log_message "Steam API не ответил (HTTP $http_status, код curl $curl_rc). Повторим на следующей итерации." "warning"
        return 1
    fi

    if ! echo "$response" | jq -e . >/dev/null 2>&1; then
        log_message "Некорректный JSON от Steam API: $response" "error"
        return 1
    fi

    local up_to_date
    # БЕЗ `// empty`: оператор // в jq подставляет альтернативу не только для
    # null, но и для false. А false здесь — это и есть «вышло обновление»,
    # поэтому сигнал молча терялся: up_to_date всегда оказывался пустым,
    # сравнение с "false" не срабатывало, и апдейтер никогда не видел обновлений.
    up_to_date="$(echo "$response" | jq -r '.response.up_to_date')"

    case "$up_to_date" in
        false)
            local required_version message
            required_version="$(echo "$response" | jq -r '.response.required_version // "?"')"
            message="$(echo "$response" | jq -r '.response.message // ""')"

            if steamcmd_build_is_current; then
                local now
                now="$(date +%s)"
                if [ "$STEAMCMD_LAG_VERSION" != "$required_version" ]; then
                    STEAMCMD_LAG_VERSION="$required_version"
                    STEAMCMD_LAG_SINCE="$now"
                fi
                if [ $((now - STEAMCMD_LAG_SINCE)) -lt "$STEAMCMD_LAG_MAX" ]; then
                    log_message "Steam объявил версию $required_version, но SteamCMD её ещё не видит (сборка $STEAMCMD_BUILD уже стоит). Серверы не трогаем, проверим позже." "warning"
                    return 1
                fi
                log_message "SteamCMD не видит версию $required_version больше часа — обновляем по данным Steam API." "warning"
            fi

            log_message "Доступна новая версия CS2: $required_version (текущая $current_version)" "running"
            [ -n "$message" ] && log_message "Сообщение Steam: $message" "debug"
            return 0
            ;;
        true)
            log_message "Сервер уже на актуальной версии: $current_version" "debug"
            return 1
            ;;
        *)
            # ни true, ни false — ответ не тот, что мы умеем читать.
            # Молча считать «обновления нет» нельзя: так баг и жил незамеченным.
            log_message "Steam API не вернул up_to_date, ответ: $response" "warning"
            return 1
            ;;
    esac
}

# Команда плагина NotifyMessages зависит от фреймворка на серверах:
# sw_restart_notify (Swiftly), css_restart_notify (CounterStrikeSharp),
# mm_restart_notify (MetaMod) или своя. Задаётся RESTART_NOTIFY_CMD в .env.
DEFAULT_RESTART_NOTIFY_CMD="sw_restart_notify"

# Оповещение о рестарте через плагин NotifyMessages.
#
# Плагин НЕ ведёт отсчёт сам: команда <RESTART_NOTIFY_CMD> <секунды> рендерит одно
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

    local cmd="${RESTART_NOTIFY_CMD:-$DEFAULT_RESTART_NOTIFY_CMD}"
    log_message "Оповещаем игроков командой $cmd, отсчёт $countdown сек." "running"

    local s now target
    for (( s = countdown; s >= 1; s-- )); do
        # Всем серверам одновременно. По очереди каждая «секунда» стоила по
        # запросу на сервер (~0,8 с): на двух серверах 300 с отсчёта шли
        # 8 минут, на пяти — 20. Пропускать секунды нельзя (см. выше), так что
        # укладываться в секунду можно только параллелью.
        # skip_state_check: список running получен выше, а опрос статуса на
        # каждую секунду удвоил бы число запросов к панели.
        # Ждём только свои запросы: голый `wait` ждал бы ВСЕ фоновые процессы
        # оболочки, и любой другой фоновый процесс в start.sh вешал бы отсчёт.
        local -a pids=()
        while IFS= read -r srv_id; do
            [ -n "$srv_id" ] || continue
            send_command "$srv_id" "$cmd $s" skip_state_check &
            pids+=("$!")
        done <<< "$servers"
        [ "${#pids[@]}" -eq 0 ] || wait "${pids[@]}" || true

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

# Ждёт, пока запущенные после обновления серверы дойдут до running.
# «Панель приняла start» ничего не доказывает: после обновления CS2 до
# 1.41.8.2 оба сервера падали через 6 секунд после старта (аддон не находил
# сигнатуры), а updater писал «Запускаем сервер» — и молчал.
# 0 — все поднялись, 1 — кто-то нет (подробности в логе).
verify_servers_started() {
    local servers_list="$1" timeout="${2:-180}"
    [ -n "$servers_list" ] || return 0

    local deadline pending="$servers_list" still id
    deadline=$(( $(date +%s) + timeout ))
    log_message "Проверяем, что серверы поднялись (до $timeout сек.)..." "running"

    while [ -n "$pending" ] && [ "$(date +%s)" -lt "$deadline" ]; do
        sleep 10
        still=""
        while IFS= read -r id; do
            [ -n "$id" ] || continue
            if [ "$(server_state "$id")" = "running" ]; then
                log_message "Сервер $id работает." "success"
            else
                still+="$id"$'\n'
            fi
        done <<< "$pending"
        pending="$still"
    done

    if [ -z "$pending" ]; then
        log_message "Все серверы после обновления запущены." "success"
        return 0
    fi

    local st
    while IFS= read -r id; do
        [ -n "$id" ] || continue
        st="$(server_state "$id")"
        if [ "$st" = "unknown" ]; then
            log_message "Сервер $id: не удалось узнать состояние — панель не ответила. Проверьте его вручную." "error"
        else
            log_message "Сервер $id НЕ поднялся после обновления CS2 (состояние: $st)." "error"
            log_message "Частая причина — аддон несовместим с новой версией игры. Смотрите консоль сервера в панели." "error"
        fi
    done <<< "$pending"
    return 1
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
