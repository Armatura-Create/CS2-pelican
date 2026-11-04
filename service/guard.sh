#!/bin/bash
#
# Защита игровых портов CS2 от UDP-флуда — nftables на хосте.
#
#   sudo ./guard.sh on                включить: правила + сверка портов раз в минуту
#   sudo ./guard.sh off               выключить и снять правила
#   sudo ./guard.sh status            порты, блокировки, счётчики
#   sudo ./guard.sh unblock <ip>|all  снять блокировку
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

    # `udp dport @ports jump game` — единственный вход в правила. Иначе лимит
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

    chain prerouting {
        type filter hook prerouting priority -300; policy accept;
        udp dport @ports jump game
    }

    chain game {
        ip saddr @allow4 accept
        ip6 saddr @allow6 accept
        ip saddr @block4 counter drop
        ip6 saddr @block6 counter drop
        udp length < 17 counter drop
        @th,64,32 0xffffffff update @a2s4 { ip saddr limit rate over 20/second burst 40 packets } counter drop
        @th,64,32 0xffffffff update @a2s6 { ip6 saddr limit rate over 20/second burst 40 packets } counter drop
        update @flood4 { ip saddr limit rate over $PPS/second burst $PPS packets } add @block4 { ip saddr timeout ${BAN}m } log prefix "cs2guard flood " counter drop
        update @flood6 { ip6 saddr limit rate over $PPS/second burst $PPS packets } add @block6 { ip6 saddr timeout ${BAN}m } log prefix "cs2guard flood " counter drop
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

unblock() {
    local what="${1:-}"
    table_exists || die "Защита не включена."
    case "$what" in
        all)
            nft flush set $TABLE block4
            nft flush set $TABLE block6
            log_message "Все блокировки сняты." "success"
            ;;
        *.*.*.*)
            [[ "$what" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || die "Не IPv4-адрес: $what"
            nft delete element $TABLE block4 "{ $what }" || die "$what не заблокирован."
            log_message "Блокировка снята: $what" "success"
            ;;
        *:*)
            [[ "$what" =~ ^[0-9A-Fa-f:]+$ ]] || die "Не IPv6-адрес: $what"
            nft delete element $TABLE block6 "{ $what }" || die "$what не заблокирован."
            log_message "Блокировка снята: $what" "success"
            ;;
        *) die "Использование: sudo $0 unblock <ip>|all" ;;
    esac
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
    { nft list set $TABLE block4; nft list set $TABLE block6; } | sed -n '/elements/,/}/p' | grep . || echo "  никого"
    echo
    echo "Отброшено пакетов (по правилам):"
    nft list chain $TABLE game | grep -E 'counter packets [1-9]' || echo "  пока ничего"
    echo
    echo "Последние блокировки:"
    journalctl -k --no-pager -o short --grep 'cs2guard flood' -n 10 2>/dev/null || echo "  нет записей"
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
    on)      on ;;
    off)     off ;;
    apply)   apply ;;
    status)  status ;;
    unblock) unblock "${2:-}" ;;
    *)
        echo "Использование: sudo $0 on|off|status|apply|unblock <ip>|all" >&2
        exit 1
        ;;
esac
