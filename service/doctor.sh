#!/bin/bash
#
# Проверка ноды одной командой: sudo ./doctor.sh
#
# Сервис, права файлов, панель и ключи, файлы игры, место на диске, Wings,
# защита от флуда, Discord. Каждая проверка — одна строка: ✓ в порядке,
# ! стоит посмотреть, ✗ сломано. Код выхода 1 только при ✗, поэтому
# doctor годится и для мониторинга.
#
set -uo pipefail
cd "$(dirname "$(readlink -f "$0")")"

export LOG_FILE_ENABLED=0
source "./utils/logging.sh"
source "./utils/managerPelican.sh"
source "./utils/managerSteamCMD.sh"
source "./utils/notify.sh"
trap - ERR
set +e

G=$'\033[0;32m'; Y=$'\033[0;33m'; R=$'\033[0;31m'; B=$'\033[1m'; N=$'\033[0m'
FAILS=0 WARNS=0
ok()   { printf '  %s✓%s %s\n' "$G" "$N" "$*"; }
warn() { printf '  %s!%s %s\n' "$Y" "$N" "$*"; WARNS=$((WARNS + 1)); }
bad()  { printf '  %s✗%s %s\n' "$R" "$N" "$*"; FAILS=$((FAILS + 1)); }
section() { printf '\n%s%s%s\n' "$B" "$1" "$N"; }

[ "$(id -u)" -eq 0 ] || { echo "Нужен root: sudo $0" >&2; exit 1; }

DIR="$(pwd)"
section "Установка ($DIR)"
ok "Версия $(cat VERSION 2>/dev/null || echo 'неизвестна')"
if [ -f .env ]; then
    # shellcheck disable=SC1091
    source ./.env
    mode="$(stat -c %a .env)"
    [ "$mode" = 600 ] && ok ".env с правами 600" || bad ".env с правами $mode — в нём ключи панели: chmod 600 $DIR/.env"
else
    bad "Нет .env — запустите sudo $DIR/configure.sh"
fi
foreign="$(find "$DIR" ! -user root 2>/dev/null | head -n 3)"
if [ -z "$foreign" ]; then
    ok "Все файлы принадлежат root"
else
    bad "Файлы не root (их выполняет root — это путь к повышению прав): $(printf '%s' "$foreign" | paste -sd' ' -). Исправить: chown -R root:root $DIR"
fi

section "Сервисы"
unit="$(grep -ls "^WorkingDirectory=$DIR\$" /etc/systemd/system/*.service 2>/dev/null | head -n1)"
svc="$(basename "${unit:-cs2-updater.service}")"
if systemctl is-active --quiet "$svc"; then
    restarts="$(systemctl show -p NRestarts --value "$svc" 2>/dev/null || echo 0)"
    [ "${restarts:-0}" -eq 0 ] && ok "$svc работает" || warn "$svc работает, но перезапускался $restarts раз: journalctl -u $svc -n 50"
else
    bad "$svc не работает: systemctl start $svc; журнал: journalctl -u $svc -n 50"
fi
systemctl is-enabled --quiet cs2-updater-autoupdate.timer 2>/dev/null \
    && ok "Автообновление updater'а включено" || warn "Автообновление updater'а выключено: sudo $DIR/autoupdate.sh on"

section "Панель (${PELICAN_URL:-не задана})"
if pelican_node_servers; then
    n="$(printf '%s' "$NODE_SERVERS" | jq 'length')"
    [ "$n" -gt 0 ] && ok "Application-ключ работает, CS2-серверов на ноде: $n" \
        || warn "Application-ключ работает, но CS2-серверов с образом ${PELICAN_IMAGE:-?} на ноде ${PELICAN_NODE_ID:-?} нет"
else
    bad "Список серверов не получен (HTTP $PELICAN_CODE) — подробно: sudo $DIR/test-pelican.sh"
fi
pelican_request GET "$(pelican_base_url)/api/client/account" "${PELICAN_API_TOKEN:-}"
pelican_ok && ok "Client-ключ работает" || bad "Client-ключ не принят (HTTP $PELICAN_CODE): без него серверы не гасятся и не поднимаются"

section "Файлы игры (${BASE_DIR:=/home/cs2_base})"
inf="$BASE_DIR/server/game/csgo/steam.inf"
[ -f "$inf" ] && ok "CS2 установлена: $(grep -m1 PatchVersion "$inf" | tr -d '\r')" || bad "Нет $inf — CS2 не скачана"
[ -x "$(steamcmd_dir)/steamcmd.sh" ] && ok "SteamCMD: $(steamcmd_dir)" || warn "SteamCMD не найден в $(steamcmd_dir) — поставится при первом обновлении"
[ ! -e "$BASE_DIR/server/steamcmd" ] || warn "Остался $BASE_DIR/server/steamcmd (внутри mount) — перенесётся при перезапуске сервиса"
free_gb="$(df -Pk "$BASE_DIR" 2>/dev/null | awk 'NR==2 {print int($4/1048576)}')"
if [ "${free_gb:-0}" -lt 10 ]; then
    bad "Свободно ${free_gb:-?} ГБ на разделе с $BASE_DIR — обновление CS2 может не влезть"
elif [ "$free_gb" -lt 20 ]; then
    warn "Свободно $free_gb ГБ на разделе с $BASE_DIR — впритык для крупного обновления CS2"
else
    ok "Свободно $free_gb ГБ"
fi

section "Wings"
wcfg=""
for f in /etc/pelican/config.yml /etc/pterodactyl/config.yml; do [ -f "$f" ] && { wcfg="$f"; break; }; done
if [ -z "$wcfg" ]; then
    warn "Конфиг Wings не найден — это точно нода?"
else
    systemctl is-active --quiet wings && ok "Wings работает" || bad "Wings не работает: systemctl status wings"
    allowed=0
    while IFS= read -r entry; do
        entry="${entry%/}"
        { [ "$BASE_DIR" = "$entry" ] || [[ "$BASE_DIR" == "$entry/"* ]]; } && allowed=1
    done < <(awk '/^allowed_mounts:/ { f = 1; next } f && /^ *- / { sub(/^ *- */, ""); gsub(/["'"'"']/, ""); print; next } f { f = 0 }' "$wcfg")
    [ "$allowed" -eq 1 ] && ok "$BASE_DIR разрешён в allowed_mounts" || bad "$BASE_DIR нет в allowed_mounts ($wcfg) — Wings не смонтирует файлы игры"
fi

section "Защита от флуда"
if systemctl is-enabled --quiet cs2-guard.timer 2>/dev/null; then
    if nft list table inet cs2guard >/dev/null 2>&1; then
        ports="$(nft -j list set inet cs2guard ports 2>/dev/null | jq -r '[.nftables[]?.set.elem[]?] | length' 2>/dev/null)"
        [ "${ports:-0}" -gt 0 ] && ok "Включена, портов под защитой: $ports" || warn "Включена, но портов нет — проверьте панель выше"
    else
        bad "Таймер включён, а правил нет: sudo $DIR/guard.sh apply"
    fi
else
    warn "Выключена: sudo $DIR/guard.sh on"
fi

section "Наблюдение за консолью"
if systemctl is-active --quiet cs2-watch 2>/dev/null; then
    ok "Работает (защита по консоли: ${GUARD_CONSOLE:-log}, журналы — ${CONSOLE_LOG_DAYS:-14} дн.)"
    recent="$(find /var/lib/cs2-updater/crashes -name '*.log' -mmin -1440 2>/dev/null | wc -l)"
    [ "$recent" -eq 0 ] || warn "Падений серверов за сутки: $recent — sudo $DIR/watch.sh status"
    [ -d /var/lib/cs2-updater ] && ok "Журналы и отчёты занимают $(du -sh /var/lib/cs2-updater 2>/dev/null | cut -f1)"
else
    warn "Выключено: sudo $DIR/watch.sh on"
fi

section "Discord"
if [ -z "${DISCORD_WEBHOOK:-}" ]; then
    warn "Оповещения выключены (DISCORD_WEBHOOK в .env пуст)"
elif name="$(notify_check)"; then
    ok "Вебхук работает: «$name»"
else
    bad "Вебхук не отвечает или неверен — оповещения не дойдут"
fi

printf '\n'
if [ "$FAILS" -gt 0 ]; then
    printf '%sПроблем: %d%s, предупреждений: %d\n' "$R" "$FAILS" "$N" "$WARNS"
    exit 1
fi
printf '%sВсё в порядке%s (предупреждений: %d)\n' "$G" "$N" "$WARNS"
