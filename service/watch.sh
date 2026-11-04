#!/bin/bash
#
# Наблюдение за консолью CS2-серверов ноды — демон на хосте.
#
#   sudo ./watch.sh on       включить (юнит cs2-watch.service)
#   sudo ./watch.sh off      выключить
#   sudo ./watch.sh status   что читается, журналы, отчёты о падениях, срабатывания
#   ./watch.sh run           сам демон — его запускает systemd
#
# Для каждого запущенного CS2-сервера читает `docker logs -f` — ровно то, что
# видно в консоли панели, — и через utils/console.awk:
#   • пишет журнал консоли /var/lib/cs2-updater/logs/<сервер>/ГГГГ-ММ-ДД.log
#     (даты UTC, секреты замаскированы); старые сжимаются, хранится
#     CONSOLE_LOG_DAYS дней (не больше 365);
#   • на падение (маркер entrypoint, или OOM) сохраняет отчёт с последними
#     500 строками в /var/lib/cs2-updater/crashes/<сервер>/ и шлёт в Discord;
#   • ловит ботов по консоли (GUARD_CONSOLE: log — только пишет, что сделал бы;
#     enforce — бан адреса на портах ЭТОГО сервера и kickid; off).
# Ещё следит за журналом ядра: блокировки guard.sh по трафику → в Discord.
#
# В тома серверов не заходит: только поток консоли из Docker. Всё, что в нём,
# — недоверенные данные (ник игрока, вывод плагина владельца сервера).
#
set -Eeuo pipefail
cd "$(dirname "$(readlink -f "$0")")"

source "./utils/logging.sh"
source "./utils/managerPelican.sh"
source "./utils/notify.sh"
trap 'handle_error "$LINENO" "$BASH_COMMAND"' ERR

# shellcheck disable=SC1091
[ -f .env ] && source ./.env

DIR="$(pwd)"
NAME="cs2-watch"
STATE_DIR="${WATCH_STATE_DIR:-/var/lib/cs2-updater}"
LOG_DIR="$STATE_DIR/logs"
CRASH_DIR="$STATE_DIR/crashes"
RUN_DIR="${WATCH_RUN_DIR:-/run/cs2-watch}"

die() { log_message "$1" "error"; exit 1; }
[ "$(id -u)" -eq 0 ] || die "Нужен root: sudo $0 ${1:-status}"

LOG_DAYS="${CONSOLE_LOG_DAYS:-14}"
[[ "$LOG_DAYS" =~ ^[1-9][0-9]{0,2}$ ]] && [ "$LOG_DAYS" -le 365 ] || LOG_DAYS=14
MODE="${GUARD_CONSOLE:-log}"
case "$MODE" in log|enforce|off) ;; *) MODE=log ;; esac

declare -A SRV_ID=() SRV_NAME=() SRV_PORTS=() SRV_ACC=()

# Серверы ноды из панели. uuid — имя контейнера у Wings, identifier — имя
# каталога журнала: оба проверяются, прежде чем стать аргументом или путём.
refresh_servers() {
    pelican_node_servers || return 1
    SRV_ID=(); SRV_NAME=(); SRV_PORTS=(); SRV_ACC=()
    local uuid id name ports acc
    while IFS=$'\t' read -r uuid id name ports acc; do
        [[ "$uuid" =~ ^[0-9a-f-]{36}$ ]] && [[ "$id" =~ ^[0-9a-f]{8}$ ]] || continue
        SRV_ID[$uuid]="$id"; SRV_NAME[$uuid]="${name:-$id}"; SRV_PORTS[$uuid]="$ports"; SRV_ACC[$uuid]="$acc"
    done < <(printf '%s' "$NODE_SERVERS" | jq -r '.[] | [.uuid, .identifier, .name,
        ([.relationships.allocations.data[]?.attributes.port | tostring] | join(" ")),
        (.container.environment.STEAM_ACC // "")] | @tsv' 2>/dev/null)
    # порт → сервер: для оповещений о блокировках по трафику
    {
        for uuid in "${!SRV_ID[@]}"; do
            for p in ${SRV_PORTS[$uuid]}; do printf '%s\t%s\n' "$p" "${SRV_NAME[$uuid]}"; done
        done
    } > "$RUN_DIR/ports.map.tmp" && mv "$RUN_DIR/ports.map.tmp" "$RUN_DIR/ports.map"
}

# --- события одного сервера (вызываются из конвейера читателя) ---------------

declare -A FIRST=() REPEAT=()
LAST_NOTE=0 SUPPRESSED=0 LAST_CRASH=0

on_hit() {
    local rule="$1" ip="$2" min="$3" uid="$4" now
    [[ "$rule" =~ ^[a-z_]+$ ]] && [[ "$min" =~ ^[0-9]+$ ]] && [[ "$uid" =~ ^[0-9]+$ ]] || return 0
    now="$(date +%s)"
    # Повторы за сутки: второй бан вчетверо длиннее, третий — неделя.
    # Адрес, трижды за день попавший под правило, — не игрок с плохим вечером.
    if [ "$ip" != "-" ]; then
        if (( now - ${FIRST[$ip]:-0} > 86400 )); then FIRST[$ip]="$now"; REPEAT[$ip]=0; fi
        REPEAT[$ip]=$(( ${REPEAT[$ip]:-0} + 1 ))
        case "${REPEAT[$ip]}" in
            1) ;;
            2) min=$(( min * 4 )) ;;
            *) min=10080 ;;
        esac
        (( min <= 10080 )) || min=10080
    fi
    local who="$ip"; [ "$uid" -eq 0 ] || who="$ip (uid $uid)"

    if [ "$MODE" != enforce ]; then
        log_message "[guard log] $SRV_N: «$rule» от $who — в режиме enforce был бы бан на $min мин" "info"
        return 0
    fi
    if [ "$ip" != "-" ]; then
        # shellcheck disable=SC2086
        "$DIR/guard.sh" ban-port "$ip" "$min" $SRV_P >/dev/null 2>&1 \
            || log_message "[guard] $SRV_N: бан $ip не поставлен — защита от флуда выключена? (sudo $DIR/guard.sh on)" "warning"
    fi
    [ "$uid" -eq 0 ] || send_command "$SRV_I" "kickid $uid" skip_state_check || true
    log_message "[guard] $SRV_N: «$rule» от $who — бан на $min мин на портах $SRV_P" "warning"

    # Discord — не чаще раза в минуту на сервер, остальное считаем
    if (( now - LAST_NOTE >= 60 )); then
        notify warn "Защита: бот на $SRV_N" \
            "Адрес $who, правило «$rule», бан на $min мин на портах $SRV_P.$( (( SUPPRESSED == 0 )) || echo " За минуту до этого — ещё $SUPPRESSED.")"
        LAST_NOTE="$now"; SUPPRESSED=0
    else
        SUPPRESSED=$(( SUPPRESSED + 1 ))
    fi
}

on_crash() {
    local code="$1" now f tailtext
    now="$(date +%s)"
    (( now - LAST_CRASH >= 60 )) || return 0   # петля падений не забьёт диск
    LAST_CRASH="$now"
    mkdir -p "$CRASH_DIR/$SRV_I"
    f="$CRASH_DIR/$SRV_I/$(date -u +%Y%m%d-%H%M%S).log"
    {
        echo "Сервер: $SRV_N ($SRV_I)"
        echo "Время (UTC): $(date -u '+%F %T')"
        echo "Код выхода: $code"
        echo
        echo "Последние строки консоли:"
        tail -n 500 "$LOG_DIR/$SRV_I/$(date -u +%F).log" 2>/dev/null || true
    } > "$f"
    # отчётов на сервер — не больше 20
    find "$CRASH_DIR/$SRV_I" -name '*.log' -type f -printf '%T@ %p\n' 2>/dev/null \
        | sort -nr | tail -n +21 | cut -d' ' -f2- | xargs -r rm -f
    log_message "Сервер $SRV_N упал (код $code). Отчёт: $f" "error"
    tailtext="$(tail -n 15 "$LOG_DIR/$SRV_I/$(date -u +%F).log" 2>/dev/null | cut -c1-160 | tr -d '`' || true)"
    notify error "Сервер $SRV_N упал (код $code)" \
        "Последние строки консоли:"$'\n```\n'"$tailtext"$'\n```\n'"Полный отчёт на ноде: $f"
}

# Читатель консоли одного сервера: живёт, пока жив контейнер
read_console() {
    local uuid="$1" since started
    SRV_I="${SRV_ID[$uuid]}"; SRV_N="${SRV_NAME[$uuid]}"; SRV_P="${SRV_PORTS[$uuid]}"
    mkdir -p "$LOG_DIR/$SRV_I"
    # Контейнер стартовал после запуска watch — читаем с его старта (вся загрузка);
    # иначе — с запуска watch: после перезапуска демона строки не дублируются.
    started="$(docker inspect -f '{{.State.StartedAt}}' "$uuid" 2>/dev/null || true)"
    since="$WATCH_STARTED"
    [[ "${started:0:19}" > "${WATCH_STARTED:0:19}" ]] && since="${started:0:19}Z"

    docker logs -f --timestamps --since "$since" "$uuid" 2>&1 \
        | awk -v dir="$LOG_DIR/$SRV_I" -v secret="${SRV_ACC[$uuid]}" -v wl="${GUARD_WHITELIST:-}" \
              -f "$DIR/utils/console.awk" \
        | while read -r kind a b c d; do
              case "$kind" in
                  CRASH) on_crash "$a" ;;
                  HIT)   [ "$MODE" = off ] || on_hit "$a" "$b" "$c" "$d" ;;
              esac
          done || true

    # Убит по памяти — тоже падение, но маркера от entrypoint тогда не будет
    if [ "$(docker inspect -f '{{.State.OOMKilled}}' "$uuid" 2>/dev/null || true)" = true ]; then
        on_crash "OOM: не хватило памяти, контейнер убит"
    fi
}

# Блокировки guard.sh по трафику — из журнала ядра в Discord
follow_kernel() {
    local line src dpt kind srv now last=0 sup=0
    journalctl -k -f -n 0 -o cat 2>/dev/null | grep --line-buffered -E 'cs2guard (flood|rcon) ' \
        | while IFS= read -r line; do
              src="$(grep -o 'SRC=[0-9a-fA-F.:]*' <<<"$line" | head -n1 || true)"; src="${src#SRC=}"
              dpt="$(grep -o 'DPT=[0-9]*' <<<"$line" | head -n1 || true)"; dpt="${dpt#DPT=}"
              kind="флуд"; [[ "$line" == *"cs2guard rcon"* ]] && kind="перебор RCON"
              srv="$(awk -F'\t' -v p="$dpt" '$1 == p { print $2; exit }' "$RUN_DIR/ports.map" 2>/dev/null || true)"
              log_message "[guard] $kind с $src на порт $dpt${srv:+ ($srv)} — адрес заблокирован" "warning"
              now="$(date +%s)"
              if (( now - last >= 60 )); then
                  notify warn "Защита: $kind${srv:+ на $srv}" \
                      "Адрес $src заблокирован на всех игровых портах ноды (порт атаки $dpt).$( (( sup == 0 )) || echo " За минуту до этого — ещё $sup.")"
                  last="$now"; sup=0
              else
                  sup=$(( sup + 1 ))
              fi
          done || true
}

# Сжатие и срок хранения: журналы старше суток — gzip, старше CONSOLE_LOG_DAYS — прочь
housekeeping() {
    local today; today="$(date -u +%F).log"
    find "$LOG_DIR" -type f -name '*.log' ! -name "$today" -mmin +10 -exec gzip -f {} + 2>/dev/null || true
    find "$LOG_DIR" -type f -name '*.log.gz' -mtime +"$LOG_DAYS" -delete 2>/dev/null || true
    find "$CRASH_DIR" -type f -name '*.log' -mtime +30 -delete 2>/dev/null || true
    find "$LOG_DIR" "$CRASH_DIR" -mindepth 1 -type d -empty -delete 2>/dev/null || true
}

run() {
    command -v docker >/dev/null 2>&1 || die "Нет docker — это нода Wings?"
    umask 077
    mkdir -p "$LOG_DIR" "$CRASH_DIR" "$RUN_DIR"
    cp VERSION "$RUN_DIR/version" 2>/dev/null || true
    WATCH_STARTED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    log_message "Наблюдение за консолью запущено (защита по консоли: $MODE, журналы — $LOG_DAYS дн.)" "info"

    declare -A READER=()
    local last_refresh=0 last_house=0 kpid="" now uuid pid running
    while true; do
        now="$(date +%s)"
        if (( now - last_refresh >= 60 )); then
            refresh_servers && last_refresh="$now" \
                || log_message "Список серверов из панели не получен (HTTP $PELICAN_CODE) — повторю через минуту." "warning"
        fi
        if [ "${WATCH_ONCE:-0}" != 1 ] && { [ -z "$kpid" ] || ! kill -0 "$kpid" 2>/dev/null; }; then
            follow_kernel & kpid=$!
        fi
        running="$(docker ps --format '{{.Names}}' 2>/dev/null || true)"
        for uuid in "${!SRV_ID[@]}"; do
            grep -qxF "$uuid" <<<"$running" || continue
            pid="${READER[$uuid]:-}"
            if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
                read_console "$uuid" &
                READER[$uuid]=$!
            fi
        done
        if (( now - last_house >= 3600 )); then housekeeping; last_house="$now"; fi
        [ "${WATCH_ONCE:-0}" != 1 ] || break
        sleep 10
    done
    # WATCH_ONCE=1 (тесты): дождаться своих читателей — именно их, не все задачи
    [ "${#READER[@]}" -eq 0 ] || wait "${READER[@]}" || true
}

status() {
    if systemctl is-active --quiet "$NAME" 2>/dev/null; then
        echo "Наблюдение за консолью: РАБОТАЕТ (защита по консоли: $MODE, журналы — $LOG_DAYS дн.)"
    else
        echo "Наблюдение за консолью: выключено (включить: sudo $0 on)"
    fi
    echo
    echo "Журналы консоли ($LOG_DIR):"
    local d n=0
    for d in "$LOG_DIR"/*/; do
        [ -d "$d" ] || continue
        n=$((n + 1))
        printf '  %s  %s, последняя строка: %s\n' "$(basename "$d")" "$(du -sh "$d" 2>/dev/null | cut -f1)" \
            "$(tail -n 1 "$d$(date -u +%F).log" 2>/dev/null | cut -c1-80 || echo 'сегодня ничего')"
    done
    [ "$n" -gt 0 ] || echo "  пока нет"
    echo
    echo "Последние отчёты о падениях:"
    find "$CRASH_DIR" -name '*.log' -type f -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n 5 | cut -d' ' -f2- \
        | sed 's/^/  /' | grep . || echo "  нет"
    echo
    echo "Защита по консоли — последние срабатывания:"
    local recent
    recent="$(journalctl -u "$NAME" -q --no-pager -o cat -n 400 2>/dev/null | grep -F '[guard' | tail -n 10 || true)"
    printf '%s\n' "${recent:-  нет}"
}

on() {
    command -v docker >/dev/null 2>&1 || die "Нет docker — это нода Wings?"
    cat > "/etc/systemd/system/$NAME.service" <<UNIT
[Unit]
Description=CS2 watch: консоль серверов, падения, защита по консоли
Wants=network-online.target
After=network-online.target docker.service

[Service]
Type=simple
ExecStart=$DIR/watch.sh run
WorkingDirectory=$DIR
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    systemctl enable --now "$NAME.service" >/dev/null 2>&1
    log_message "Наблюдение за консолью включено. Состояние: sudo $DIR/watch.sh status" "success"
}

off() {
    systemctl disable --now "$NAME.service" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/$NAME.service"
    systemctl daemon-reload 2>/dev/null || true
    log_message "Наблюдение за консолью выключено. Журналы и отчёты остались в $STATE_DIR." "success"
}

case "${1:-status}" in
    on)     on ;;
    off)    off ;;
    run)    run ;;
    status) status ;;
    *)
        echo "Использование: sudo $0 on|off|status" >&2
        exit 1
        ;;
esac
