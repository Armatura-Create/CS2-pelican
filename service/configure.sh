#!/bin/bash
#
# Мастер настройки CS2 Updater.
#
# Спрашивает только то, чего не может узнать сам, и сразу проверяет ответы:
# отвечает ли панель, подходят ли ключи, какая нода — этот сервер, хватит ли
# места, пустит ли Wings mount, создан ли Mount, актуален ли egg. В конце
# показывает итог и пишет .env и systemd-юнит только после подтверждения.
#
# Вызывается из install.sh. Повторный запуск — это перенастройка: значения из
# текущего .env предлагаются по умолчанию, Enter их оставляет.
#
set -Eeuo pipefail

# Работаем от каталога скрипта, чтобы запуск из другого cwd не ломал пути
cd "$(dirname "$(readlink -f "$0")")"

source "./utils/logging.sh"
source "./utils/managerPelican.sh"   # pelican_request: ключ уходит в curl через stdin
trap 'handle_error "$LINENO" "$BASH_COMMAND"' ERR

REPO="${REPO:-Armatura-Create/CS2-pelican}"
EGG_NAME="CS2 with base files"
DEFAULT_IMAGE="docker.io/scrender/base-files-cs2:latest"
AUTOUPDATE_TIMER="cs2-updater-autoupdate.timer"
# Путь обязан совпадать с CYCLE_LOCK в start.sh
CYCLE_LOCK="/run/cs2-updater-cycle.lock"

STEP=0
STEPS=7
NEXT_STEPS=()

########################################
# Вывод и ввод
########################################
B=$'\033[1m'; G=$'\033[0;32m'; Y=$'\033[0;33m'; R=$'\033[0;31m'; N=$'\033[0m'
say()  { printf '%s\n' "$*" >&2; }
ok()   { printf '  %s✓%s %s\n' "$G" "$N" "$*" >&2; }
warn() { printf '  %s!%s %s\n' "$Y" "$N" "$*" >&2; }
fail() { printf '  %s✗%s %s\n' "$R" "$N" "$*" >&2; }
step() { STEP=$((STEP + 1)); printf '\n%s[%d/%d] %s%s\n' "$B" "$STEP" "$STEPS" "$1" "$N" >&2; }
# Без выравнивания колонок: printf %-Ns считает байты, а кириллица — 2 байта на букву
row()  { printf '  %s: %s\n' "$1" "$2" >&2; }
die()  { fail "$1"; exit 1; }

# read с понятной ошибкой: без терминала (или по Ctrl+D) мастер не зацикливается
input() { read -r "$@" || die "Ввод прерван."; }

# ask VAR "Вопрос" [умолчание] — Enter оставляет умолчание
ask() {
    local __var="$1" __q="$2" __def="${3:-}" __ans
    if [ -n "$__def" ]; then
        input -p "  $__q [$__def]: " __ans
    else
        input -p "  $__q: " __ans
    fi
    __ans="${__ans#"${__ans%%[![:space:]]*}"}"
    __ans="${__ans%"${__ans##*[![:space:]]}"}"
    printf -v "$__var" '%s' "${__ans:-$__def}"
}

# ask_yn "Вопрос" y|n — 0 «да», 1 «нет»
ask_yn() {
    local __ans __hint="y/N"
    [ "$2" = "y" ] && __hint="Y/n"
    while true; do
        input -p "  $1 [$__hint]: " __ans
        case "${__ans:-$2}" in
            [YyДд]*) return 0 ;;
            [NnНн]*) return 1 ;;
        esac
    done
}

# ask_number VAR "Вопрос" умолчание мин макс
ask_number() {
    local __var="$1"
    while true; do
        ask "$__var" "$2" "$3"
        if [[ "${!__var}" =~ ^[0-9]+$ ]] && [ "${!__var}" -ge "$4" ] && [ "${!__var}" -le "$5" ]; then
            return 0
        fi
        fail "Нужно число от $4 до $5."
    done
}

# ask_secret VAR "Вопрос" — ввод скрыт; Enter оставляет текущее значение
ask_secret() {
    local __var="$1" __q="$2" __cur="${!1:-}" __ans
    [ -z "$__cur" ] || __q="$__q (Enter — оставить $(mask "$__cur"))"
    input -s -p "  $__q: " __ans
    say ""
    __ans="${__ans//[[:space:]]/}"
    printf -v "$__var" '%s' "${__ans:-$__cur}"
}

# Ключ в итогах и подсказках — только края
mask() {
    local s="$1"
    if [ "${#s}" -le 12 ]; then printf '***'; else printf '%s…%s' "${s:0:5}" "${s: -4}"; fi
}

# pick VAR "Вопрос" умолчание N — номер варианта из показанного списка
pick() {
    local __var="$1"
    ask_number "$__var" "$2" "$3" 1 "$4"
}

########################################
# Текущие значения — умолчания для перенастройки
########################################
load_current() {
    if [ -f .env ]; then
        # shellcheck disable=SC1091
        source ./.env
        RECONFIGURE=1
    else
        RECONFIGURE=0
    fi

    CURRENT_SERVICE="$(grep -ls "^WorkingDirectory=$PWD\$" /etc/systemd/system/*.service 2>/dev/null | head -n1 || true)"
    CURRENT_SERVICE="$(basename "${CURRENT_SERVICE:-}" .service)"

    SRCDS_APPID="${SRCDS_APPID:-730}"
    STEAM_USER="${STEAM_USER:-anonymous}"
    STEAM_PASS="${STEAM_PASS:-}"
    STEAM_AUTH="${STEAM_AUTH:-}"
    EXTRA_FLAGS="${EXTRA_FLAGS:-}"
    PELICAN_URL="${PELICAN_URL:-}"
    PELICAN_APP_TOKEN="${PELICAN_APP_TOKEN:-}"
    PELICAN_API_TOKEN="${PELICAN_API_TOKEN:-}"
    PELICAN_IMAGE="${PELICAN_IMAGE:-}"
    PELICAN_NODE_ID="${PELICAN_NODE_ID:-}"
    BASE_DIR="${BASE_DIR:-/home/cs2_base}"
    VERSION_CHECK_INTERVAL="${VERSION_CHECK_INTERVAL:-300}"
    UPDATE_COUNTDOWN_TIME="${UPDATE_COUNTDOWN_TIME:-300}"
    RESTART_NOTIFY_CMD="${RESTART_NOTIFY_CMD:-}"
    LOG_LEVEL="${LOG_LEVEL:-INFO}"
    LOG_FILE_ENABLED="${LOG_FILE_ENABLED:-1}"
    SERVICE_NAME="${CURRENT_SERVICE:-cs2-updater}"

    if [ "$RECONFIGURE" -eq 1 ] && ! systemctl is-enabled --quiet "$AUTOUPDATE_TIMER" 2>/dev/null; then
        SELF_AUTOUPDATE=0
    else
        SELF_AUTOUPDATE=1
    fi
}

########################################
# 1. Зависимости
########################################
step_dependencies() {
    step "Зависимости"
    local -a missing=()
    local p
    # lib32* — для 32-битного SteamCMD
    for p in curl jq unzip lib32gcc-s1 lib32stdc++6; do
        dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p")
    done
    if [ "${#missing[@]}" -eq 0 ]; then
        ok "Всё уже установлено."
        return 0
    fi
    say "  Ставлю: ${missing[*]}..."
    if apt-get update -qq >/dev/null 2>&1 \
        && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" >/dev/null 2>&1; then
        ok "Установлено: ${missing[*]}"
    else
        die "apt не смог установить: ${missing[*]}. Попробуйте вручную: apt-get install -y ${missing[*]}"
    fi
}

########################################
# 2. Панель Pelican
########################################

# Оставляем только схему и хост: из адресной строки часто вставляют
# https://panel.example.com/admin/servers, а API живёт в корне.
normalize_url() {
    local u="${1//[[:space:]]/}"
    case "$u" in
        http://*|https://*) ;;
        *) u="https://$u" ;;
    esac
    printf '%s' "$u" | sed -E 's#^(https?://[^/]+).*#\1#'
}

# Спрашивает ключ, пока панель его не примет. Ввод скрыт.
ask_key() {
    local var="$1" kind="$2" title path want other
    if [ "$kind" = "application" ]; then
        title="Application API ключ"; path="/api/application/servers?per_page=1"
        want="papp_"; other="pacc_"
    else
        title="Client API ключ"; path="/api/client/account"
        want="pacc_"; other="papp_"
    fi

    local key who
    while true; do
        ask_secret "$var" "$title"
        key="${!var}"
        if [ -z "$key" ]; then
            fail "Ключ обязателен."
            continue
        fi

        pelican_request GET "$PELICAN_URL$path" "$key"
        case "$PELICAN_CODE" in
            2??)
                if [ "$kind" = "client" ]; then
                    who="$(printf '%s' "$PELICAN_BODY" | jq -r '.attributes.email // .attributes.username // "?"' 2>/dev/null || echo "?")"
                    ok "Ключ подходит, аккаунт: $who"
                else
                    ok "Ключ подходит."
                fi
                return 0
                ;;
            000) fail "Панель не ответила — проверить ключ нельзя." ;;
            401) fail "Панель не приняла ключ (HTTP 401)." ;;
            403) fail "У ключа не хватает прав (HTTP 403): нужно чтение Servers, Nodes, Eggs и Mounts." ;;
            *)   fail "Панель ответила HTTP $PELICAN_CODE." ;;
        esac
        case "$key" in
            "$other"*) warn "Похоже, это не тот ключ: $title начинается с $want." ;;
        esac
        if ask_yn "Сохранить ключ без проверки?" n; then
            return 0
        fi
        printf -v "$var" '%s' ""   # отвергнутый ключ не предлагаем снова
    done
}

step_panel() {
    step "Панель Pelican"
    local url code
    while true; do
        ask url "Адрес панели (например https://panel.example.com)" "$PELICAN_URL"
        if [ -z "$url" ]; then
            fail "Адрес обязателен."
            continue
        fi
        PELICAN_URL="$(normalize_url "$url")"
        [ "$PELICAN_URL" = "$url" ] || say "  → использую $PELICAN_URL"

        code="$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 10 --max-time 20 "$PELICAN_URL" 2>/dev/null || true)"
        if [ -n "$code" ] && [ "$code" != "000" ]; then
            ok "Панель отвечает (HTTP $code)."
            break
        fi
        fail "Панель не отвечает с этого сервера. Проверьте адрес, DNS и доступ к ней отсюда."
        if ask_yn "Всё равно продолжить с этим адресом?" n; then
            break
        fi
    done

    say ""
    say "  Нужны два РАЗНЫХ ключа из панели:"
    say "    • application — Admin → API Keys (начинается с papp_): список серверов и нод;"
    say "    • client — меню аккаунта → API Keys (начинается с pacc_): команды и питание серверов."
    ask_key PELICAN_APP_TOKEN application
    ask_key PELICAN_API_TOKEN client
}

########################################
# 3. Нода и CS2-серверы
########################################

# 0, если FQDN ноды указывает на этот сервер
host_is_me() {
    local fqdn="$1" ip
    [ "$fqdn" = "$(hostname -f 2>/dev/null || true)" ] && return 0
    # || true: несуществующий FQDN — обычное дело, не ошибка
    for ip in $(getent ahosts "$fqdn" 2>/dev/null | awk '{print $1}' | sort -u || true); do
        case " $MY_IPS " in
            *" $ip "*) return 0 ;;
        esac
    done
    return 1
}

step_node() {
    step "Нода и CS2-серверы"
    MY_IPS="$(hostname -I 2>/dev/null || true)"

    local nodes=""
    pelican_request GET "$PELICAN_URL/api/application/nodes?per_page=100" "$PELICAN_APP_TOKEN"
    if pelican_ok; then
        nodes="$(printf '%s' "$PELICAN_BODY" | jq -r '.data[].attributes | "\(.id)\t\(.name)\t\(.fqdn)"' 2>/dev/null || true)"
    fi

    if [ -z "$nodes" ]; then
        warn "Список нод получить не удалось (HTTP $PELICAN_CODE)."
        ask_number PELICAN_NODE_ID "ID ноды, на которой CS2-серверы (Admin → Nodes)" "${PELICAN_NODE_ID:-1}" 1 999999
    else
        local -a ids=()
        local id name fqdn mark i=0 cur="" mine="" choice
        say "  Ноды в панели:"
        while IFS=$'\t' read -r id name fqdn; do
            i=$((i + 1))
            ids+=("$id")
            mark=""
            if host_is_me "$fqdn"; then
                mark="  ← этот сервер"
                [ -n "$mine" ] || mine="$i"
            fi
            [ "$id" != "$PELICAN_NODE_ID" ] || cur="$i"
            printf '    %d) %s — %s (ID %s)%s\n' "$i" "$name" "$fqdn" "$id" "$mark" >&2
        done <<< "$nodes"
        [ -n "$mine" ] || [ -n "$cur" ] || warn "Не нашёл ноду, FQDN которой указывает на этот сервер, — выберите вручную."
        pick choice "Нода с CS2-серверами" "${cur:-${mine:-1}}" "$i"
        PELICAN_NODE_ID="${ids[$((choice - 1))]}"
    fi

    # Серверы ноды: какие образы там есть и сколько серверов на каждом
    NODE_SERVERS="[]"
    pelican_request GET "$PELICAN_URL/api/application/servers?per_page=100" "$PELICAN_APP_TOKEN"
    if pelican_ok; then
        NODE_SERVERS="$(printf '%s' "$PELICAN_BODY" | jq -c --argjson n "$PELICAN_NODE_ID" \
            '[.data[].attributes | select(.node == $n)]' 2>/dev/null || echo "[]")"
    fi

    local images
    images="$(printf '%s' "$NODE_SERVERS" | jq -r \
        '[.[].container.image] | group_by(.) | map("\(length)\t\(.[0])") | .[]' 2>/dev/null | sort -rn || true)"

    if [ -z "$images" ]; then
        say "  На этой ноде пока нет серверов — updater найдёт их, когда вы их создадите."
        ask PELICAN_IMAGE "Docker-образ CS2-серверов" "${PELICAN_IMAGE:-$DEFAULT_IMAGE}"
    else
        local -a imgs=()
        local count img i=0 cur="" ours="" choice
        say "  Образы серверов на ноде:"
        while IFS=$'\t' read -r count img; do
            i=$((i + 1))
            imgs+=("$img")
            [ "$img" != "$PELICAN_IMAGE" ] || cur="$i"
            case "$img" in *base-files-cs2*) [ -n "$ours" ] || ours="$i" ;; esac
            printf '    %d) %s — серверов: %s\n' "$i" "$img" "$count" >&2
        done <<< "$images"
        printf '    %d) другой образ\n' "$((i + 1))" >&2
        pick choice "Образ CS2-серверов" "${cur:-${ours:-1}}" "$((i + 1))"
        if [ "$choice" -le "$i" ]; then
            PELICAN_IMAGE="${imgs[$((choice - 1))]}"
        else
            ask PELICAN_IMAGE "Docker-образ" "${PELICAN_IMAGE:-$DEFAULT_IMAGE}"
        fi
    fi

    MATCHED="$(printf '%s' "$NODE_SERVERS" | jq -c --arg img "$PELICAN_IMAGE" \
        '[.[] | select(.container.image == $img)]' 2>/dev/null || echo "[]")"
    local n
    n="$(printf '%s' "$MATCHED" | jq 'length' 2>/dev/null || echo 0)"
    if [ "$n" -gt 0 ]; then
        ok "Updater будет управлять серверами ($n):"
        printf '%s' "$MATCHED" | jq -r '.[] | "      • \(.name) (\(.identifier))"' >&2 || true
    else
        warn "Серверов с образом $PELICAN_IMAGE на ноде пока нет — управлять будет нечем, пока не создадите."
    fi
}

########################################
# 4. Оповещения игроков
########################################

# Какой фреймворк стоит на большинстве серверов — такую команду и предложим
detect_notify_choice() {
    printf '%s' "$MATCHED" | jq -r '
        [ .[].container.environment
          | if .ADDON_PLATFORM == "swiftly" then 1
            elif .ADDON_PLATFORM == "metamod" and (.CSS_ENABLED // "1" | tostring) == "1" then 2
            elif .ADDON_PLATFORM == "metamod" then 3
            else empty end ]
        | if length == 0 then "" else group_by(.) | max_by(length) | .[0] | tostring end' 2>/dev/null || true
}

# prompt_notify_cmd [вариант по умолчанию 1-4]
# Команда зависит от фреймворка: плагин NotifyMessages регистрирует её со
# своим префиксом. К ней updater допишет число секунд.
prompt_notify_cmd() {
    local def="${1:-1}" custom_def="${RESTART_NOTIFY_CMD:-}"
    echo "  Команда оповещения игроков о рестарте (плагин NotifyMessages):"
    echo "    1) sw_restart_notify   — Swiftly"
    echo "    2) css_restart_notify  — CounterStrikeSharp"
    echo "    3) mm_restart_notify   — MetaMod"
    echo "    4) своя команда"

    local choice
    while true; do
        input -p "  Выбор [$def]: " choice
        case "${choice:-$def}" in
            1) RESTART_NOTIFY_CMD="sw_restart_notify";  return 0 ;;
            2) RESTART_NOTIFY_CMD="css_restart_notify"; return 0 ;;
            3) RESTART_NOTIFY_CMD="mm_restart_notify";  return 0 ;;
            4) break ;;
            *) fail "Введите число от 1 до 4." ;;
        esac
    done

    case "$custom_def" in sw_restart_notify|css_restart_notify|mm_restart_notify) custom_def="" ;; esac
    while true; do
        ask RESTART_NOTIFY_CMD "Команда (число секунд допишется само)" "$custom_def"
        # Одно слово: консоль CS2 считает ';' разделителем команд, а пробел
        # сдвинул бы число секунд во второй аргумент.
        if [[ "$RESTART_NOTIFY_CMD" =~ ^[A-Za-z0-9_.-]+$ ]]; then
            return 0
        fi
        fail "Нужно одно слово из латиницы, цифр и _ . - (например my_restart_notify)."
    done
}

step_notify() {
    step "Оповещения игроков"
    local detected def
    detected="$(detect_notify_choice)"
    case "$RESTART_NOTIFY_CMD" in
        sw_restart_notify)  def=1 ;;
        css_restart_notify) def=2 ;;
        mm_restart_notify)  def=3 ;;
        "")                 def="${detected:-1}" ;;
        *)                  def=4 ;;
    esac
    case "$detected" in
        1) say "  На серверах Swiftly — предлагаю sw_restart_notify." ;;
        2) say "  На серверах CounterStrikeSharp — предлагаю css_restart_notify." ;;
        3) say "  На серверах MetaMod — предлагаю mm_restart_notify." ;;
    esac
    prompt_notify_cmd "$def"
    ask_number UPDATE_COUNTDOWN_TIME "За сколько секунд предупреждать игроков о рестарте (0 — не предупреждать)" \
        "$UPDATE_COUNTDOWN_TIME" 0 3600
}

########################################
# 5. Файлы игры
########################################
step_game_files() {
    step "Файлы игры"
    say "  Одна копия CS2 на все серверы ноды: контейнеры монтируют её только на чтение."
    local avail inf
    while true; do
        ask BASE_DIR "Каталог для файлов игры" "$BASE_DIR"
        case "$BASE_DIR" in
            /*) ;;
            *) fail "Нужен абсолютный путь, например /home/cs2_base."; continue ;;
        esac
        BASE_DIR="${BASE_DIR%/}"
        if ! mkdir -p "$BASE_DIR" 2>/dev/null; then
            fail "Не удалось создать $BASE_DIR."
            continue
        fi

        avail="$(df -Pk "$BASE_DIR" | awk 'NR==2 {print int($4/1048576)}')"
        inf="$BASE_DIR/server/game/csgo/steam.inf"
        if [ -f "$inf" ]; then
            ok "CS2 уже скачана ($(grep -m1 PatchVersion "$inf" | tr -d '\r')) — заново качать не придётся. Свободно ${avail} ГБ."
            break
        fi
        if [ "${avail:-0}" -ge 50 ]; then
            ok "Свободно ${avail} ГБ — хватит (CS2 занимает ~40 ГБ)."
            break
        fi
        warn "Свободно только ${avail} ГБ, а CS2 занимает ~40 ГБ и растёт с обновлениями."
        if ! ask_yn "Выбрать другой каталог?" y; then
            break
        fi
    done
}

########################################
# 6. Wings и панель: mount должен быть разрешён, создан и привязан
########################################

# Добавляет BASE_DIR в allowed_mounts, сохраняя отступ списка. Код 3 — не разобрали.
add_allowed_mount() {
    awk -v dir="$BASE_DIR" '
        done_ { print; next }
        /^allowed_mounts:[[:space:]]*\[\][[:space:]]*$/ { print "allowed_mounts:"; print "- " dir; done_ = 1; next }
        /^allowed_mounts:[[:space:]]*\[/ { bad = 1 }
        /^allowed_mounts:[[:space:]]*$/ { print; key = 1; next }
        key {
            ind = ""
            if (match($0, /^ *- /)) ind = substr($0, 1, RLENGTH - 2)
            print ind "- " dir; print; key = 0; done_ = 1; next
        }
        { print }
        END {
            if (key) { print "- " dir; done_ = 1 }
            if (bad) exit 3
            if (!done_) { print "allowed_mounts:"; print "- " dir }
        }
    ' "$1"
}

wings_allowed_mounts() {
    local cfg="" f
    for f in /etc/pelican/config.yml /etc/pterodactyl/config.yml; do
        if [ -f "$f" ]; then cfg="$f"; break; fi
    done
    if [ -z "$cfg" ]; then
        warn "Wings на этом сервере не найден."
        NEXT_STEPS+=("На ноде с Wings в config.yml добавьте $BASE_DIR в allowed_mounts и перезапустите Wings.")
        return 0
    fi

    # Wings пускает mount, если его путь начинается с разрешённого
    local entry
    while IFS= read -r entry; do
        entry="${entry%/}"
        if [ -n "$entry" ] && { [ "$BASE_DIR" = "$entry" ] || [[ "$BASE_DIR" == "$entry/"* ]]; }; then
            ok "Wings: $BASE_DIR разрешён в allowed_mounts ($entry)."
            return 0
        fi
    done < <(awk '/^allowed_mounts:/ { f = 1; next } f && /^ *- / { sub(/^ *- */, ""); gsub(/["'"'"']/, ""); print; next } f { f = 0 }' "$cfg")

    warn "Wings не пустит mount: $BASE_DIR нет в allowed_mounts ($cfg)."
    if ! ask_yn "Добавить и перезапустить Wings? Игровые серверы при этом не останавливаются." y; then
        NEXT_STEPS+=("В $cfg добавьте $BASE_DIR в allowed_mounts и выполните: systemctl restart wings")
        return 0
    fi

    local backup rc=0
    backup="$cfg.bak-$(date +%Y%m%d-%H%M%S)"
    cp -a "$cfg" "$backup"
    add_allowed_mount "$cfg" > "$cfg.tmp" || rc=$?
    if [ "$rc" -ne 0 ]; then
        rm -f "$cfg.tmp"
        warn "Не разобрал формат allowed_mounts — поправьте вручную."
        NEXT_STEPS+=("В $cfg добавьте $BASE_DIR в allowed_mounts и выполните: systemctl restart wings")
        return 0
    fi
    cat "$cfg.tmp" > "$cfg" && rm -f "$cfg.tmp"

    if ! systemctl list-unit-files wings.service >/dev/null 2>&1; then
        ok "Добавлено в $cfg (копия: $backup). Перезапустите Wings сами."
        return 0
    fi
    systemctl restart wings 2>/dev/null || true
    sleep 3
    if systemctl is-active --quiet wings; then
        ok "Добавлено, Wings перезапущен (копия конфига: $backup)."
    else
        fail "Wings не поднялся после правки — возвращаю конфиг."
        cp -a "$backup" "$cfg"
        systemctl restart wings 2>/dev/null || true
        NEXT_STEPS+=("Добавьте $BASE_DIR в allowed_mounts в $cfg вручную — автоматическая правка не прошла.")
    fi
}

panel_mount_check() {
    local src="$BASE_DIR/server" found
    local howto="Admin → Mounts → Create: Source $src, Target /mnt, Read Only; привяжите к нему egg «$EGG_NAME» и ноду."
    pelican_request GET "$PELICAN_URL/api/application/mounts?per_page=100" "$PELICAN_APP_TOKEN"
    if ! pelican_ok; then
        warn "Не удалось проверить Mount в панели (HTTP $PELICAN_CODE)."
        NEXT_STEPS+=("Проверьте Mount: $howto")
        return 0
    fi
    found="$(printf '%s' "$PELICAN_BODY" | jq -r --arg s "$src" \
        '[.data[].attributes | select((.source | rtrimstr("/")) == $s and .target == "/mnt")] | first // empty | "\(.name)\t\(.read_only)"' 2>/dev/null || true)"
    if [ -z "$found" ]; then
        warn "В панели нет Mount с $src → /mnt."
        NEXT_STEPS+=("Создайте Mount: $howto")
    elif [ "${found#*$'\t'}" != "true" ]; then
        warn "Mount «${found%%$'\t'*}» есть, но он не Read Only — контейнеры смогут писать в общие файлы игры."
        NEXT_STEPS+=("Включите Read Only у Mount «${found%%$'\t'*}» (Admin → Mounts).")
    else
        ok "Mount в панели есть: «${found%%$'\t'*}» ($src → /mnt, только чтение)."
    fi
}

panel_egg_check() {
    local howto="Admin → Eggs → Import: https://raw.githubusercontent.com/$REPO/master/egg/pelican.yaml"
    pelican_request GET "$PELICAN_URL/api/application/eggs?per_page=100" "$PELICAN_APP_TOKEN"
    if ! pelican_ok; then
        warn "Не удалось проверить egg в панели (HTTP $PELICAN_CODE)."
        NEXT_STEPS+=("Проверьте, что egg «$EGG_NAME» импортирован: $howto")
        return 0
    fi

    local egg_id
    egg_id="$(printf '%s' "$PELICAN_BODY" | jq -r --arg n "$EGG_NAME" \
        '[.data[].attributes | select(.name == $n) | .id] | first // empty' 2>/dev/null || true)"
    if [ -z "$egg_id" ]; then
        warn "Egg «$EGG_NAME» в панели не найден (если переименовали — проверьте сами)."
        NEXT_STEPS+=("Импортируйте egg: $howto")
        return 0
    fi

    # Актуальность: сравниваем переменные с egg из репозитория
    local have want missing
    pelican_request GET "$PELICAN_URL/api/application/eggs/$egg_id?include=variables" "$PELICAN_APP_TOKEN"
    have="$(printf '%s' "$PELICAN_BODY" | jq -r '.attributes.relationships.variables.data[]?.attributes.env_variable' 2>/dev/null | sort || true)"
    want="$(curl -fsSL --max-time 20 "https://raw.githubusercontent.com/$REPO/master/egg/pelican.json" 2>/dev/null \
        | jq -r '.variables[].env_variable' 2>/dev/null | sort || true)"
    if [ -z "$have" ] || [ -z "$want" ]; then
        ok "Egg «$EGG_NAME» импортирован (ID $egg_id). Актуальность проверить не удалось."
        return 0
    fi
    local count
    missing="$(comm -13 <(printf '%s\n' "$have") <(printf '%s\n' "$want") || true)"
    count="$(printf '%s' "$missing" | grep -c . || true)"
    if [ "$count" -eq 0 ]; then
        ok "Egg «$EGG_NAME» импортирован и актуален."
    else
        missing="$(printf '%s\n' "$missing" | head -n 5 | tr '\n' ' ' || true)"
        missing="${missing% }"
        [ "$count" -le 5 ] || missing="$missing и ещё $((count - 5))"
        warn "Egg в панели устарел, нет переменных: $missing"
        NEXT_STEPS+=("Обновите egg «$EGG_NAME» (Admin → Eggs → egg → Import, поверх существующего): https://raw.githubusercontent.com/$REPO/master/egg/pelican.yaml")
    fi
}

step_wings_panel() {
    step "Wings и панель"
    wings_allowed_mounts
    panel_mount_check
    panel_egg_check
}

########################################
# 7. Сервис
########################################
step_advanced() {
    ask_number SRCDS_APPID "AppID сервера CS2" "$SRCDS_APPID" 1 99999999
    ask STEAM_USER "Steam-логин (anonymous — без аккаунта, для CS2 этого хватает)" "$STEAM_USER"
    if [ "$STEAM_USER" = "anonymous" ]; then
        STEAM_PASS=""
        STEAM_AUTH=""
    else
        ask_secret STEAM_PASS "Steam-пароль"
        ask_secret STEAM_AUTH "Код Steam Guard (можно пусто)"
    fi
    ask EXTRA_FLAGS "Флаги SteamCMD для app_update, например «-beta имя» (- очистить)" "$EXTRA_FLAGS"
    [ "$EXTRA_FLAGS" != "-" ] || EXTRA_FLAGS=""
    ask_number VERSION_CHECK_INTERVAL "Как часто проверять обновления CS2, секунд" "$VERSION_CHECK_INTERVAL" 60 86400
    while true; do
        ask LOG_LEVEL "Подробность логов: DEBUG, INFO, WARNING или ERROR" "$LOG_LEVEL"
        LOG_LEVEL="${LOG_LEVEL^^}"
        case "$LOG_LEVEL" in DEBUG|INFO|WARNING|ERROR) break ;; esac
        fail "Одно из: DEBUG, INFO, WARNING, ERROR."
    done
    if ask_yn "Писать лог ещё и в файлы logs/ (хранятся 7 дней)?" "$([ "$LOG_FILE_ENABLED" = 1 ] && echo y || echo n)"; then
        LOG_FILE_ENABLED=1
    else
        LOG_FILE_ENABLED=0
    fi
}

step_service() {
    step "Сервис"
    local unit
    while true; do
        ask SERVICE_NAME "Имя systemd-сервиса" "$SERVICE_NAME"
        SERVICE_NAME="${SERVICE_NAME%.service}"
        if [[ ! "$SERVICE_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9_.@-]*$ ]]; then
            fail "Только латиница, цифры и _ . @ -"
            continue
        fi
        unit="/etc/systemd/system/$SERVICE_NAME.service"
        if [ -f "$unit" ] && ! grep -q "^WorkingDirectory=$PWD\$" "$unit"; then
            warn "Сервис $SERVICE_NAME.service уже есть и запускает другое: $(grep -m1 '^ExecStart=' "$unit" || true)"
            if ! ask_yn "Перезаписать его?" n; then
                continue
            fi
        fi
        break
    done

    if ask_yn "Обновлять сам CS2 Updater автоматически — каждую ночь, с откатом при сбое?" \
        "$([ "$SELF_AUTOUPDATE" = 1 ] && echo y || echo n)"; then
        SELF_AUTOUPDATE=1
    else
        SELF_AUTOUPDATE=0
    fi

    if ask_yn "Изменить дополнительные настройки (Steam-аккаунт, AppID, интервал проверки, логи)?" n; then
        step_advanced
    fi
}

########################################
# Итог и применение
########################################
summary() {
    say ""
    say "${B}Проверьте настройки:${N}"
    row "Каталог" "$PWD"
    row "Сервис" "$SERVICE_NAME.service"
    row "Панель" "$PELICAN_URL"
    row "Application ключ" "$(mask "$PELICAN_APP_TOKEN")"
    row "Client ключ" "$(mask "$PELICAN_API_TOKEN")"
    row "Нода" "ID $PELICAN_NODE_ID"
    row "Образ серверов" "$PELICAN_IMAGE"
    row "Оповещение" "$RESTART_NOTIFY_CMD, за $UPDATE_COUNTDOWN_TIME с до рестарта"
    row "Файлы игры" "$BASE_DIR/server"
    row "Steam" "$STEAM_USER, AppID $SRCDS_APPID${EXTRA_FLAGS:+, флаги: $EXTRA_FLAGS}"
    row "Проверка обновлений CS2" "каждые $VERSION_CHECK_INTERVAL с"
    row "Логи" "$LOG_LEVEL$([ "$LOG_FILE_ENABLED" = 1 ] && echo ', в journald и logs/' || echo ', только journald')"
    row "Автообновление сервиса" "$([ "$SELF_AUTOUPDATE" = 1 ] && echo 'да, каждую ночь' || echo 'нет')"
}

write_env() {
    # 600 ДО записи: в .env лежат ключи панели и, возможно, пароль Steam
    rm -f .env
    (umask 077; : > .env)
    cat <<EOF > .env
# Создан мастером настройки. Перенастроить: sudo $PWD/configure.sh
BASE_DIR="$BASE_DIR"
SRCDS_APPID="$SRCDS_APPID"
STEAM_USER="$STEAM_USER"
STEAM_PASS="$STEAM_PASS"
STEAM_AUTH="$STEAM_AUTH"
EXTRA_FLAGS="$EXTRA_FLAGS"

PELICAN_URL="$PELICAN_URL"
PELICAN_APP_TOKEN="$PELICAN_APP_TOKEN"
PELICAN_API_TOKEN="$PELICAN_API_TOKEN"
PELICAN_IMAGE="$PELICAN_IMAGE"
PELICAN_NODE_ID="$PELICAN_NODE_ID"

VERSION_CHECK_INTERVAL="$VERSION_CHECK_INTERVAL"
UPDATE_COUNTDOWN_TIME="$UPDATE_COUNTDOWN_TIME"
# sw_restart_notify (Swiftly), css_restart_notify (CounterStrikeSharp), mm_restart_notify (MetaMod) или своя
RESTART_NOTIFY_CMD="$RESTART_NOTIFY_CMD"

LOG_LEVEL="$LOG_LEVEL"
LOG_FILE_ENABLED="$LOG_FILE_ENABLED"
EOF
    chmod 600 .env
}

write_unit() {
    cat > "/etc/systemd/system/$SERVICE_NAME.service" <<EOF
[Unit]
Description=CS2 Updater Service
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
ExecStart=$PWD/start.sh
WorkingDirectory=$PWD
Restart=always
# Без паузы systemd успевает сделать StartLimitBurst (5) рестартов за доли
# секунды, упирается в лимит и гасит юнит насовсем — «Start request repeated
# too quickly». Для апдейтера это худший исход: его сбои обычно временные
# (кончилось место, пропала сеть), и он обязан продолжать попытки.
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
}

apply() {
    say ""
    local svc="$SERVICE_NAME.service"

    # Перезапуск посреди цикла обновления CS2 оставил бы игровые серверы
    # выключенными: ждём, пока start.sh отпустит лок.
    if [ -e "$CYCLE_LOCK" ] && ! flock -n "$CYCLE_LOCK" true 2>/dev/null; then
        say "  Сейчас идёт обновление CS2 — жду его окончания, чтобы не оставить серверы выключенными..."
        flock -w 1800 "$CYCLE_LOCK" true 2>/dev/null || warn "Не дождался конца цикла за 30 минут, продолжаю."
    fi

    # Сменили имя сервиса — старый юнит убираем, иначе будет два апдейтера
    if [ -n "$CURRENT_SERVICE" ] && [ "$CURRENT_SERVICE" != "$SERVICE_NAME" ]; then
        systemctl disable --now "$CURRENT_SERVICE.service" >/dev/null 2>&1 || true
        rm -f "/etc/systemd/system/$CURRENT_SERVICE.service"
        ok "Старый сервис $CURRENT_SERVICE.service убран."
    fi

    write_env
    ok ".env сохранён (права 600)."

    # systemd запускает скрипты напрямую — бит выполнения обязателен
    chmod +x ./*.sh
    write_unit
    systemctl daemon-reload
    systemctl enable "$svc" >/dev/null 2>&1
    ok "Сервис $svc создан и включён в автозапуск."

    if [ "$SELF_AUTOUPDATE" = "1" ]; then
        ./autoupdate.sh on >/dev/null 2>&1 && ok "Автообновление включено: каждую ночь между 04:00 и 05:00." \
            || warn "Автообновление не включилось. Позже: sudo $PWD/autoupdate.sh on"
    else
        ./autoupdate.sh off >/dev/null 2>&1 || true
    fi

    if systemctl is-active --quiet "$svc"; then
        systemctl restart "$svc"
        ok "Сервис перезапущен с новыми настройками."
    elif ask_yn "Запустить сервис сейчас?$([ -f "$BASE_DIR/server/game/csgo/steam.inf" ] || echo ' Первый запуск скачает ~40 ГБ игры: от 20 минут до нескольких часов.')" y; then
        systemctl start "$svc"
    else
        NEXT_STEPS+=("Запустите сервис: systemctl start $svc")
        return 0
    fi

    sleep 5
    if systemctl is-active --quiet "$svc"; then
        ok "Сервис работает. Последние строки лога:"
        journalctl -u "$svc" -n 4 --no-pager -o cat 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g; s/^/      /' >&2 || true
    else
        fail "Сервис не поднялся. Смотрите: journalctl -u $svc -n 50"
    fi
}

finish() {
    say ""
    if [ "${#NEXT_STEPS[@]}" -eq 0 ]; then
        ok "${B}Всё настроено.${N}"
    else
        say "${Y}Осталось сделать:${N}"
        local s i=0
        for s in "${NEXT_STEPS[@]}"; do
            i=$((i + 1))
            say "  $i. $s"
        done
    fi
    say ""
    say "  Лог:             journalctl -u $SERVICE_NAME.service -f"
    say "  Перенастроить:   sudo $PWD/configure.sh"
    say "  Автообновление:  sudo $PWD/autoupdate.sh status"
}

main() {
    [ "$(id -u)" -eq 0 ] || die "Нужен root: sudo $0"
    [ -t 0 ] || die "Нужен интерактивный терминал."

    load_current
    say ""
    if [ "$RECONFIGURE" -eq 1 ]; then
        say "${B}Перенастройка CS2 Updater.${N} Текущие значения — в [скобках], Enter их оставляет."
    else
        say "${B}Настройка CS2 Updater.${N} Значения по умолчанию — в [скобках], Enter их принимает."
    fi

    step_dependencies
    while true; do
        STEP=1
        NEXT_STEPS=()
        step_panel
        step_node
        step_notify
        step_game_files
        step_wings_panel
        step_service
        summary
        if ask_yn "Всё верно? Сохранить и применить" y; then
            break
        fi
        say "  Пройдём ещё раз — ваши ответы станут значениями по умолчанию."
    done
    apply
    finish
}

main "$@"
