#!/bin/bash
#
# Защита игровых портов CS2 от UDP-флуда — nftables на хосте.
#
#   sudo ./guard.sh on                включить: правила + сверка портов раз в минуту
#   sudo ./guard.sh off               выключить и снять правила
#   sudo ./guard.sh status            порты, блокировки, счётчики
#   sudo ./guard.sh unblock <ip>|all  снять блокировку
#   sudo ./guard.sh block <ip> [мин]  заблокировать вручную (15 мин)
#   sudo ./guard.sh why <ip>          всё об адресе: баны, белый список, журналы
#   sudo ./guard.sh rates [сек]       пакетов/с с каждого адреса (5 с)
#   sudo ./guard.sh apply             один проход; его раз в минуту запускает таймер
#
# Действует только на UDP-порты CS2-серверов этой ноды (allocations из панели):
#   • больше GUARD_PPS_LIMIT пакетов в секунду с одного адреса — адрес
#     блокируется на GUARD_BAN_MINUTES минут. Так сервер и кладут: он работает,
#     но лагает, разбирая чужие пакеты;
#   • UDP короче 9 байт данных отбрасывается: игра таких не шлёт, это пробы;
#   • A2S-запросы (начинаются с FF FF FF FF) сверх 20 в секунду с адреса
#     отбрасываются без бана: обратный адрес у них легко подделать.
# Частные сети (в том числе мост Docker) и GUARD_WHITELIST не ограничиваются.
#
# Таймер раз в минуту сверяет порты с панелью: новый сервер защищён через
# минуту после создания. Цепочка — prerouting с приоритетом -300, раньше NAT
# Docker и conntrack: флуд отбрасывается, не доходя до контейнера.
#
# От флуда, который забивает сам канал до сервера, правила на хосте не спасут:
# это решает только фильтрация у хостера.
#
# Правила и пороги — по мотивам модуля guard из K4ryuu/CS2-Egg-Go (GPLv3).
#
set -Eeuo pipefail
cd "$(dirname "$(readlink -f "$0")")"

source "./utils/logging.sh"
source "./utils/managerPelican.sh"
trap 'handle_error "$LINENO" "$BASH_COMMAND"' ERR

# shellcheck disable=SC1091
[ -f .env ] && source ./.env

DIR="$(pwd)"
NAME="cs2-guard"
TABLE="inet cs2guard"
# Загруженный набор правил. /run очищается при перезагрузке вместе с таблицей
# в ядре, поэтому «файл есть, таблицы нет» не случается.
STATE="/run/cs2-guard.ruleset"

die() { log_message "$1" "error"; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Нужен root: sudo $0 ${1:-status}"

# Число из .env или значение по умолчанию: оно попадает в текст правил nft
positive_int() {
    local name="$1" value="$2" def="$3"
    if [ -z "$value" ]; then
        printf '%s' "$def"
    elif [[ "$value" =~ ^[1-9][0-9]{0,6}$ ]]; then
        printf '%s' "$value"
    else
        log_message "$name='$value' — не число, использую $def." "warning"
        printf '%s' "$def"
    fi
}

PPS="$(positive_int GUARD_PPS_LIMIT "${GUARD_PPS_LIMIT:-}" 1500)"
BAN="$(positive_int GUARD_BAN_MINUTES "${GUARD_BAN_MINUTES:-}" 60)"

# Полный текст таблицы. Без портов: их список меняется, а правила — нет.
ruleset() {
    local v4="10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 127.0.0.0/8, 100.64.0.0/10, 169.254.0.0/16"
    local v6="::1/128, fc00::/7, fe80::/10"
    # :- обязателен: в .env от прошлых версий ключа нет, а set -u уронил бы скрипт
    local w list="${GUARD_WHITELIST:-}"
    for w in ${list//,/ }; do
        if [[ "$w" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?$ ]]; then
            v4+=", $w"
        elif [[ "$w" =~ ^[0-9A-Fa-f:]*:[0-9A-Fa-f:]*(/[0-9]{1,3})?$ ]]; then
            v6+=", $w"
        else
            log_message "GUARD_WHITELIST: '$w' — не адрес и не подсеть, пропускаю." "warning"
        fi
    done

    # `udp/tcp dport @ports jump …` — единственный вход в правила. Иначе лимит
    # и блокировки легли бы на весь трафик хоста, включая SSH.
    cat <<EOF
table $TABLE {
    set ports  { type inet_service; }
    set allow4 { type ipv4_addr; flags interval; elements = { $v4 } }
    set allow6 { type ipv6_addr; flags interval; elements = { $v6 } }
    set block4 { type ipv4_addr; flags dynamic, timeout; size 65536; }
    set block6 { type ipv6_addr; flags dynamic, timeout; size 65536; }
    set flood4 { type ipv4_addr; flags dynamic, timeout; timeout 10s; size 65536; }
    set flood6 { type ipv6_addr; flags dynamic, timeout; timeout 10s; size 65536; }
    set a2s4   { type ipv4_addr; flags dynamic, timeout; timeout 10s; size 65536; }
    set a2s6   { type ipv6_addr; flags dynamic, timeout; timeout 10s; size 65536; }
    # Баны по правилам консоли — только на портах того сервера, чья консоль это
    # показала: консоль пишет владелец сервера, и бан на всю ноду дал бы ему
    # банить игроков чужих серверов (watch.sh)
    set blockport4 { type ipv4_addr . inet_service; flags timeout; size 65536; }
    set blockport6 { type ipv6_addr . inet_service; flags timeout; size 65536; }
    # Счётчики пакетов по адресам — для команды guard.sh rates
    set seen4  { type ipv4_addr; flags dynamic, timeout; timeout 30s; size 65536; }
    set seen6  { type ipv6_addr; flags dynamic, timeout; timeout 30s; size 65536; }
    set rcon4  { type ipv4_addr; flags dynamic, timeout; timeout 60s; size 65536; }
    set rcon6  { type ipv6_addr; flags dynamic, timeout; timeout 60s; size 65536; }
    set tcp4   { type ipv4_addr; flags dynamic, timeout; timeout 10s; size 65536; }
    set tcp6   { type ipv6_addr; flags dynamic, timeout; timeout 10s; size 65536; }

    chain prerouting {
        type filter hook prerouting priority -300; policy accept;
        udp dport @ports jump game
        tcp dport @ports jump game_tcp
    }

    chain game {
        ip saddr @allow4 accept
        ip6 saddr @allow6 accept
        ip saddr @block4 counter drop
        ip6 saddr @block6 counter drop
        ip saddr . udp dport @blockport4 counter drop
        ip6 saddr . udp dport @blockport6 counter drop
        update @seen4 { ip saddr counter }
        update @seen6 { ip6 saddr counter }
        udp length < 17 counter drop
        @th,64,32 0xffffffff update @a2s4 { ip saddr limit rate over 20/second burst 40 packets } counter drop
        @th,64,32 0xffffffff update @a2s6 { ip6 saddr limit rate over 20/second burst 40 packets } counter drop
        update @flood4 { ip saddr limit rate over $PPS/second burst $PPS packets } add @block4 { ip saddr timeout ${BAN}m } log prefix "cs2guard flood " counter drop
        update @flood6 { ip6 saddr limit rate over $PPS/second burst $PPS packets } add @block6 { ip6 saddr timeout ${BAN}m } log prefix "cs2guard flood " counter drop
    }

    # TCP на игровом порту — это RCON (игроки ходят по UDP). Перебор пароля
    # начинается с потока SYN: больше 20 в минуту — бан на сутки. Остальной
    # TCP сверх 200 пакетов/с отбрасываем без бана: источник легко подделать.
    chain game_tcp {
        ip saddr @allow4 accept
        ip6 saddr @allow6 accept
        ip saddr @block4 counter drop
        ip6 saddr @block6 counter drop
        ip saddr . tcp dport @blockport4 counter drop
        ip6 saddr . tcp dport @blockport6 counter drop
        tcp flags & (syn | ack) == syn update @rcon4 { ip saddr limit rate over 20/minute burst 20 packets } add @block4 { ip saddr timeout 1440m } log prefix "cs2guard rcon " counter drop
        tcp flags & (syn | ack) == syn update @rcon6 { ip6 saddr limit rate over 20/minute burst 20 packets } add @block6 { ip6 saddr timeout 1440m } log prefix "cs2guard rcon " counter drop
        update @tcp4 { ip saddr limit rate over 200/second burst 200 packets } counter drop
        update @tcp6 { ip6 saddr limit rate over 200/second burst 200 packets } counter drop
    }
}
EOF
}

table_exists() { nft list table $TABLE >/dev/null 2>&1; }

current_ports() {
    table_exists || return 0
    nft -j list set $TABLE ports 2>/dev/null | jq -r '.nftables[]?.set.elem[]?' 2>/dev/null | sort -n || true
}

apply() {
    command -v nft >/dev/null 2>&1 || die "Не найден nft. Включите защиту заново: sudo $DIR/guard.sh on"

    # Ручной apply не должен столкнуться с проходом по таймеру
    exec 9>/run/cs2-guard.lock
    flock 9

    local have want
    have="$(current_ports)"
    # Панель недоступна — оставляем порты, что уже стоят: не снимать же защиту
    if ! want="$(pelican_node_ports)"; then
        log_message "Список портов из панели не получен — оставляю прежний." "warning"
        want="$have"
    fi
    want="$(printf '%s\n' "$want" | grep -E '^[0-9]{1,5}$' | sort -nu || true)"

    local rules rebuild=0
    rules="$(ruleset)"
    if ! table_exists || [ "$(cat "$STATE" 2>/dev/null || true)" != "$rules" ]; then
        rebuild=1
    elif [ "$have" = "$want" ]; then
        log_message "Защита: без изменений, порты: ${want//$'\n'/ }" "debug"
        return 0
    fi

    # Одной транзакцией: пересборка таблицы и порты встают вместе
    {
        if [ "$rebuild" -eq 1 ]; then
            table_exists && echo "delete table $TABLE"
            printf '%s\n' "$rules"
        fi
        echo "flush set $TABLE ports"
        [ -z "$want" ] || echo "add element $TABLE ports { $(printf '%s' "$want" | paste -sd, -) }"
    } | nft -f -

    if [ "$rebuild" -eq 1 ]; then
        printf '%s' "$rules" > "$STATE"
        log_message "Правила защиты загружены: больше $PPS пакетов/с с адреса — блок на $BAN мин." "success"
    fi
    if [ -n "$want" ]; then
        log_message "Защищённые порты: ${want//$'\n'/ }" "info"
    else
        log_message "Защищённых портов нет: CS2-серверов на ноде не нашёл." "warning"
    fi
}

# ip → «4» / «6» / пусто (не адрес). Значение уходит в команду nft.
ip_family() {
    if [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then printf 4
    elif [[ "$1" =~ ^[0-9A-Fa-f:]+$ ]] && [[ "$1" == *:* ]]; then printf 6
    fi
}

# Частные адреса и мост Docker не блокируем никаким путём: за мостом стоят все
# клиенты, проходящие через docker-proxy, и бан моста — бан всех.
is_private() {
    [[ "$1" =~ ^(10\.|127\.|0\.|192\.168\.|169\.254\.|172\.(1[6-9]|2[0-9]|3[01])\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.) ]] \
        || [[ "${1,,}" =~ ^(::1$|fc|fd|fe80:) ]]
}

# Баны адреса по портам: «ip . порт» из blockport4/6, по одному на строку
port_bans() {
    local fam="$1" ip="$2"
    nft -j list set $TABLE "blockport$fam" 2>/dev/null | jq -r --arg ip "$ip" \
        '.nftables[]?.set.elem[]? | (.elem.val // .) | .concat? // empty | select(.[0] == $ip) | "\(.[0]) . \(.[1])"' 2>/dev/null || true
}

unblock() {
    local what="${1:-}" fam e n=0
    table_exists || die "Защита не включена."
    if [ "$what" = all ]; then
        for e in block4 block6 blockport4 blockport6; do nft flush set $TABLE "$e"; done
        log_message "Все блокировки сняты." "success"
        return 0
    fi
    fam="$(ip_family "$what")"
    [ -n "$fam" ] || die "Использование: sudo $0 unblock <ip>|all"
    nft delete element $TABLE "block$fam" "{ $what }" 2>/dev/null && n=$((n + 1))
    while IFS= read -r e; do
        [ -n "$e" ] || continue
        nft delete element $TABLE "blockport$fam" "{ $e }" 2>/dev/null && n=$((n + 1))
    done < <(port_bans "$fam" "$what")
    [ "$n" -gt 0 ] || die "$what не заблокирован."
    log_message "Блокировка снята: $what" "success"
}

# block <ip> [минут] — ручной бан на всех игровых портах ноды (по умолчанию 15 мин)
block() {
    local ip="${1:-}" min="${2:-15}" fam
    table_exists || die "Защита не включена."
    fam="$(ip_family "$ip")"
    [ -n "$fam" ] || die "Использование: sudo $0 block <ip> [минут]"
    [[ "$min" =~ ^[1-9][0-9]{0,5}$ ]] || die "Минуты — целое число, получено: $min"
    is_private "$ip" && die "$ip — частный адрес или мост Docker: за ним могут стоять все игроки, не блокирую."
    nft add element $TABLE "block$fam" "{ $ip timeout ${min}m }"
    log_message "Заблокирован вручную: $ip на $min мин" "success"
}

# ban-port <ip> <минут> <порт…> — бан только на портах одного сервера; для watch.sh
ban_port() {
    local ip="${1:-}" min="${2:-}" fam port
    shift 2 || true
    table_exists || die "Защита не включена."
    fam="$(ip_family "$ip")"
    [ -n "$fam" ] && [[ "$min" =~ ^[1-9][0-9]{0,5}$ ]] || die "Использование: $0 ban-port <ip> <минут> <порт…>"
    is_private "$ip" && die "$ip — частный адрес, не блокирую."
    for port in "$@"; do
        [[ "$port" =~ ^[0-9]{1,5}$ ]] || continue
        # add не продлевает уже стоящий бан, поэтому сначала delete
        nft delete element $TABLE "blockport$fam" "{ $ip . $port }" 2>/dev/null || true
        nft add element $TABLE "blockport$fam" "{ $ip . $port timeout ${min}m }"
    done
}

# why <ip> — всё, что известно об адресе
why() {
    local ip="${1:-}" fam
    fam="$(ip_family "$ip")"
    [ -n "$fam" ] || die "Использование: sudo $0 why <ip>"
    table_exists || die "Защита не включена."
    echo "Адрес $ip"
    if nft get element $TABLE "allow$fam" "{ $ip }" >/dev/null 2>&1; then
        echo "  в белом списке (частная сеть или GUARD_WHITELIST): не ограничивается"
    fi
    if nft get element $TABLE "block$fam" "{ $ip }" >/dev/null 2>&1; then
        echo "  заблокирован на всех игровых портах: $(nft get element $TABLE "block$fam" "{ $ip }" 2>/dev/null | grep -o 'expires [0-9hms]*' | head -n1)"
    fi
    local pb
    pb="$(port_bans "$fam" "$ip")"
    [ -z "$pb" ] || echo "  заблокирован на портах: $(printf '%s\n' "$pb" | awk '{print $3}' | paste -sd' ' -)"
    echo
    echo "Защита по трафику (ядро):"
    journalctl -k -q --no-pager -o short --grep "cs2guard .*SRC=$ip " -n 10 2>/dev/null || true
    echo
    echo "Защита по консоли (cs2-watch):"
    journalctl -u cs2-watch -q --no-pager -o cat --grep "$ip" -n 10 2>/dev/null || true
}

# rates [секунд] — пакеты в секунду с каждого адреса на игровые порты
rates() {
    local secs="${1:-5}" a b
    [[ "$secs" =~ ^[1-9][0-9]?$ ]] || die "Использование: sudo $0 rates [секунд, 1-99]"
    table_exists || die "Защита не включена."
    # Текстовый вывод, а не -j: nft 0.9.3 (Ubuntu 20.04) в JSON счётчики
    # элементов набора не печатает. «адрес … counter packets N bytes M»
    snapshot() {
        { nft list set $TABLE seen4; nft list set $TABLE seen6; } 2>/dev/null | tr '\n\t' '  ' \
            | grep -o 'elements = {[^}]*}' | sed 's/^elements = {//; s/}$//' | tr ',' '\n' \
            | awk '{ p = 0; b = 0; for (i = 1; i < NF; i++) { if ($i == "packets") p = $(i + 1); if ($i == "bytes") b = $(i + 1) }
                     if ($1 != "") print $1, p, b }' || true
    }
    a="$(snapshot)"; sleep "$secs"; b="$(snapshot)"
    printf '%-40s %10s %10s\n' "АДРЕС" "ПАКЕТ/С" "БАЙТ/ПАК"
    awk -v s="$secs" 'NR == FNR { p[$1] = $2; o[$1] = $3; next }
        { dp = $2 - p[$1]; db = $3 - o[$1]; if (dp > 0) printf "%-40s %10.1f %10d\n", $1, dp / s, db / dp }' \
        <(printf '%s\n' "$a") <(printf '%s\n' "$b") | sort -k2 -nr | head -n 20
}

status() {
    if systemctl is-enabled --quiet "$NAME.timer" 2>/dev/null; then
        echo "Защита от флуда: ВКЛЮЧЕНА (лимит $PPS пакетов/с с адреса, блок на $BAN мин)"
    else
        echo "Защита от флуда: выключена (включить: sudo $0 on)"
    fi
    table_exists || return 0
    echo
    echo "Порты: $(current_ports | paste -sd' ' -)"
    echo
    echo "Заблокированы сейчас:"
    { nft list set $TABLE block4; nft list set $TABLE block6; } | sed -n '/elements/,/}/p' | grep . || echo "  на всех портах — никого"
    { nft list set $TABLE blockport4; nft list set $TABLE blockport6; } | sed -n '/elements/,/}/p' | grep . \
        && echo "  (выше — баны на портах одного сервера: по консоли, cs2-watch)" || echo "  на портах отдельных серверов — никого"
    echo
    echo "Отброшено пакетов (по правилам):"
    nft list chain $TABLE game | grep -E 'counter packets [1-9]' || echo "  пока ничего"
    echo
    echo "Последние блокировки:"
    # -q: без «-- No entries --» от самого journalctl; пусто — пишем своё
    local recent
    recent="$(journalctl -k -q --no-pager -o short --grep 'cs2guard flood' -n 10 2>/dev/null || true)"
    printf '%s\n' "${recent:-  нет записей}"
}

on() {
    if ! command -v nft >/dev/null 2>&1; then
        log_message "Ставлю nftables..." "running"
        # Устаревшие списки пакетов дают 404 — тогда обновляем их и пробуем ещё раз
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nftables >/dev/null 2>&1 \
            || { apt-get update -qq >/dev/null 2>&1 \
                 && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nftables >/dev/null 2>&1; } \
            || die "apt не смог поставить nftables."
    fi
    apply

    cat > "/etc/systemd/system/$NAME.service" <<UNIT
[Unit]
Description=CS2 guard: правила защиты и порты серверов
Wants=network-online.target
After=network-online.target docker.service

[Service]
Type=oneshot
ExecStart=$DIR/guard.sh apply
UNIT

    cat > "/etc/systemd/system/$NAME.timer" <<UNIT
[Unit]
Description=CS2 guard: сверка портов серверов раз в минуту

[Timer]
OnBootSec=30s
OnUnitActiveSec=1min
AccuracySec=10s

[Install]
WantedBy=timers.target
UNIT

    systemctl daemon-reload
    systemctl enable --now "$NAME.timer" >/dev/null 2>&1
    log_message "Защита от флуда включена. Состояние: sudo $DIR/guard.sh status" "success"
}

off() {
    systemctl disable --now "$NAME.timer" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/$NAME.service" "/etc/systemd/system/$NAME.timer"
    systemctl daemon-reload 2>/dev/null || true
    if table_exists; then nft delete table $TABLE; fi
    rm -f "$STATE"
    log_message "Защита от флуда выключена, правила сняты." "success"
}

case "${1:-status}" in
    on)       on ;;
    off)      off ;;
    apply)    apply ;;
    status)   status ;;
    unblock)  unblock "${2:-}" ;;
    block)    block "${2:-}" "${3:-15}" ;;
    why)      why "${2:-}" ;;
    rates)    rates "${2:-5}" ;;
    ban-port) shift; ban_port "$@" ;;
    *)
        echo "Использование: sudo $0 on|off|status|apply|unblock <ip>|all|block <ip> [мин]|why <ip>|rates [сек]" >&2
        exit 1
        ;;
esac
