#!/bin/bash
#
# Автообновление самого CS2 Updater (не игры — игру обновляет start.sh).
#
#   sudo ./autoupdate.sh on       включить: раз в сутки ночью ставит новый релиз
#   sudo ./autoupdate.sh off      выключить
#   sudo ./autoupdate.sh status   включено ли, когда следующая проверка, итог последней
#
# Работает через systemd-таймер, а не из-под cs2.service: update.sh
# останавливает сервис, а systemd при остановке убивает всю его cgroup —
# вместе с тем, кто обновляет. У таймера своя cgroup, и если новая версия
# сломает start.sh, таймер всё равно отработает и сможет поставить исправление.
#
# Запускается update.sh из этого каталога, то есть только код из
# опубликованного релиза с проверенной контрольной суммой, а не с master.
#
set -Eeuo pipefail
cd "$(dirname "$(readlink -f "$0")")"

DIR="$(pwd)"
NAME="cs2-updater-autoupdate"

[ "$(id -u)" -eq 0 ] || { echo "Нужен root: sudo $0 ${1:-status}" >&2; exit 1; }

case "${1:-status}" in
    on)
        [ -x ./update.sh ] || { echo "В $DIR нет update.sh — сначала обновитесь вручную до v1.2.6+." >&2; exit 1; }

        cat > "/etc/systemd/system/$NAME.service" <<UNIT
[Unit]
Description=CS2 Updater: установка нового релиза
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
Environment=INSTALL_DIR=$DIR
ExecStart=$DIR/update.sh
# Зависшая закачка не должна блокировать следующие ночи
TimeoutStartSec=30min
UNIT

        cat > "/etc/systemd/system/$NAME.timer" <<UNIT
[Unit]
Description=CS2 Updater: ночная проверка новых релизов

[Timer]
OnCalendar=*-*-* 04:00:00
RandomizedDelaySec=1h
# Сервер был выключен ночью — проверим после включения
Persistent=true

[Install]
WantedBy=timers.target
UNIT

        systemctl daemon-reload
        systemctl enable --now "$NAME.timer" >/dev/null 2>&1
        echo "Автообновление включено. Проверка каждую ночь между 04:00 и 05:00."
        echo "Логи: journalctl -u $NAME.service"
        ;;
    off)
        systemctl disable --now "$NAME.timer" >/dev/null 2>&1 || true
        echo "Автообновление выключено. Обновлять вручную:"
        echo "  curl -fsSL https://raw.githubusercontent.com/Armatura-Create/CS2-pelican/master/update.sh | sudo bash"
        ;;
    status)
        if systemctl is-enabled --quiet "$NAME.timer" 2>/dev/null; then
            echo "Автообновление: ВКЛЮЧЕНО"
            systemctl list-timers "$NAME.timer" --no-pager | head -n 2
        else
            echo "Автообновление: выключено (включить: sudo $0 on)"
        fi
        echo "Версия: $(cat VERSION 2>/dev/null || echo неизвестна)"
        echo
        echo "Последний запуск:"
        journalctl -u "$NAME.service" -n 15 --no-pager -o cat 2>/dev/null || true
        ;;
    *)
        echo "Использование: sudo $0 on|off|status" >&2
        exit 1
        ;;
esac
