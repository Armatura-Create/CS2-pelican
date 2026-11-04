#!/bin/bash
#
# Оповещения в Discord. Без DISCORD_WEBHOOK в .env не отправляется ничего.
#
# URL вебхука — сам по себе секрет: по нему кто угодно может писать в канал.
# Поэтому curl получает его конфигом через stdin (-K -), а не аргументом:
# аргументы видны всем пользователям хоста в ps. Формат URL проверяем строго —
# он попадает в конфиг curl в кавычках, и кавычка в значении стала бы инъекцией.
#
# Оповещение не имеет права ронять вызывающего: любой сбой — warning и return 0.

DISCORD_WEBHOOK_RE='^https://(discord|discordapp)\.com/api/webhooks/[0-9]+/[A-Za-z0-9_-]+$'

# notify <info|ok|warn|error> <заголовок> [текст]
notify() {
    local level="$1" title="$2" text="${3:-}" color payload code
    [ -n "${DISCORD_WEBHOOK:-}" ] || return 0
    if [[ ! "$DISCORD_WEBHOOK" =~ $DISCORD_WEBHOOK_RE ]]; then
        log_message "DISCORD_WEBHOOK в .env не похож на вебхук Discord — оповещение не отправлено." "warning"
        return 0
    fi
    case "$level" in
        ok)    color=3066993 ;;    # зелёный
        warn)  color=15105570 ;;   # оранжевый
        error) color=15158332 ;;   # красный
        *)     color=3447003 ;;    # синий
    esac
    payload="$(jq -nc --arg t "$title" --arg d "$text" --argjson c "$color" --arg host "$(hostname)" '
        {username: "CS2 Updater",
         embeds: [{title: ($t | .[0:256]), description: ($d | .[0:4000]), color: $c,
                   footer: {text: $host}, timestamp: (now | todate)}]}' 2>/dev/null)" || return 0
    code="$(printf 'url = "%s"\n' "$DISCORD_WEBHOOK" \
        | curl -sS -m 15 -K - -o /dev/null -w '%{http_code}' \
            -H 'Content-Type: application/json' --data-binary "$payload" 2>/dev/null || true)"
    case "$code" in
        2??) return 0 ;;
    esac
    log_message "Discord не принял оповещение «$title» (HTTP ${code:-000})." "warning"
    return 0
}

# Проверка вебхука без отправки сообщения: GET на URL вебхука отдаёт его описание.
# 0 — вебхук живой; печатает имя канала-вебхука.
notify_check() {
    [[ "${DISCORD_WEBHOOK:-}" =~ $DISCORD_WEBHOOK_RE ]] || return 1
    local body
    body="$(printf 'url = "%s"\n' "$DISCORD_WEBHOOK" | curl -fsS -m 15 -K - 2>/dev/null)" || return 1
    printf '%s' "$body" | jq -r '.name // "?"' 2>/dev/null
}
