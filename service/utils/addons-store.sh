#!/bin/bash
#
# Склад аддонов ноды — как файлы игры: одна копия на ноду, серверы берут её
# из /mnt вместо того, чтобы каждый ходил на GitHub и качал сам.
#
#   $BASE_DIR/server/.cs2-addons/            (в контейнере — /mnt/.cs2-addons, только чтение)
#     index                                  какие версии «последние» и закреплённые
#     <аддон>/<версия>/tree/                 файлы ровно в том виде, как ложатся на сервер
#     <аддон>/<версия>/.ready                версия готова (и когда она была нужна)
#
# Что нужно — видно по переменным серверов в панели: платформа, CSS, бета
# Swiftly, ModSharp, закреплённые версии. Плюс закрепления на всю ноду из .env:
# PIN_METAMOD, PIN_CSS, PIN_SWIFTLY, PIN_MODSHARP — серверы без своей версии
# ставят эту, в том числе более старую (откат всей ноды).
#
# Готовит версии одноразовый контейнер из образа серверов (scripts/addon-store.sh):
# тот же код, что ставит аддон на сервер, поэтому раскладка не расходится.
# Контейнер запускается от nobody и видит только свой временный каталог.
# Образ старше v1.4.0 такого скрипта не знает — тогда склад просто не ведётся.
#
# Сбой склада ничему не мешает: серверы скачают аддоны сами, как раньше.

ADDON_STORE_DIR="${BASE_DIR:-/home/cs2_base}/server/.cs2-addons"
ADDON_VERSION_RE='^[A-Za-z0-9._+-]+$'

# Что нужно серверам ноды, по строке:
#   need <аддон> <latest|beta>     — «последняя» версия этого канала
#   want <аддон> <версия>          — закреплённая версия сервера
addon_needs() {
    printf '%s' "$NODE_SERVERS" | jq -r '
        def flag($v; $d): (($v // $d) | tostring);
        .[] | (.container.environment // {}) as $e | flag($e.ADDON_PLATFORM; "metamod") as $p
        | ( if $p == "metamod" then "need metamod latest",
                (if flag($e.CSS_ENABLED; "1") != "0" then "need css latest" else empty end)
            else empty end ),
          ( if $p == "swiftly" then
                "need swiftly \(if flag($e.SWIFTLY_BETA; "0") == "1" then "beta" else "latest" end)"
            else empty end ),
          ( if flag($e.MODSHARP_ENABLED; "0") == "1" then "need modsharp latest", "need dotnet latest" else empty end ),
          ( [["metamod","METAMOD_VERSION"],["css","CSS_VERSION"],["swiftly","SWIFTLY_VERSION"],["modsharp","MODSHARP_VERSION"]][]
            as [$a, $k] | flag($e[$k]; "") | select(. != "") | "want \($a) \(.)" )' 2>/dev/null | sort -u
}

# Одноразовый контейнер со scripts/addon-store.sh. Ничего, кроме /out, не видит.
# GITHUB_TOKEN (если задан) — файлом переменных: аргумент docker run виден в ps.
store_helper() {
    local out="$1"; shift
    docker run --rm --pull=never --user 65534:65534 -e HOME=/tmp \
        --env-file "$STORE_ENV" ${STORE_EXTRA_ENV:+-e "$STORE_EXTRA_ENV"} \
        ${out:+-v "$out:/out"} --entrypoint /scripts/addon-store.sh "$PELICAN_IMAGE" "$@"
}

# store_prepare <аддон> <версия> [закрепление Metamod как есть: 2.0.0-git1380]
store_prepare() {
    local a="$1" v="$2" raw="${3:-}" d tmp
    [[ "$v" =~ $ADDON_VERSION_RE ]] || return 0
    d="$ADDON_STORE_DIR/$a/$v"
    if [ -f "$d/.ready" ]; then
        touch "$d/.ready"   # нужна и сейчас — уборка её не тронет
        return 0
    fi
    tmp="$(mktemp -d -p "$ADDON_STORE_DIR" .prep.XXXXXX)"
    chmod 777 "$tmp"
    local STORE_EXTRA_ENV=""
    [ -z "$raw" ] || STORE_EXTRA_ENV="METAMOD_VERSION=$raw"
    if store_helper "$tmp" prepare "$a" "$v" /out/tree >/dev/null 2>"$tmp.log" && [ -d "$tmp/tree" ]; then
        chown -R root:root "$tmp"
        chmod -R a+rX,go-w "$tmp"
        chmod 755 "$tmp"
        mkdir -p "$ADDON_STORE_DIR/$a"
        rm -rf "$d"
        mv "$tmp" "$d"
        touch "$d/.ready"
        log_message "Склад аддонов: $a $v готов." "success"
    else
        log_message "Склад аддонов: $a $v подготовить не удалось — серверы скачают сами. $(tail -n 2 "$tmp.log" 2>/dev/null | tr '\n' ' ')" "warning"
        rm -rf "$tmp"
    fi
    rm -f "$tmp.log"
}

refresh_addon_store() {
    command -v docker >/dev/null 2>&1 || return 0
    [ -n "${PELICAN_IMAGE:-}" ] || return 0
    if ! docker image inspect "$PELICAN_IMAGE" >/dev/null 2>&1; then
        log_message "Склад аддонов: образа $PELICAN_IMAGE на ноде ещё нет — подожду, пока Wings его скачает." "debug"
        return 0
    fi
    if ! docker run --rm --pull=never --entrypoint test "$PELICAN_IMAGE" -x /scripts/addon-store.sh >/dev/null 2>&1; then
        log_message "Склад аддонов: образ $PELICAN_IMAGE старше v1.4.0 — склад не веду, серверы качают сами." "debug"
        return 0
    fi
    pelican_node_servers || { log_message "Склад аддонов: список серверов не получен — повторю позже." "debug"; return 0; }

    umask 022
    mkdir -p "$ADDON_STORE_DIR"
    chmod 755 "$ADDON_STORE_DIR"
    STORE_ENV="$(umask 077; mktemp -p /run cs2-store-env.XXXXXX 2>/dev/null || mktemp)"
    printf 'GITHUB_TOKEN=%s\n' "${GITHUB_TOKEN:-}" > "$STORE_ENV"

    local index="" kind a x v pin
    while read -r kind a x; do
        [ -n "$kind" ] || continue
        case "$kind" in
            need)
                v="$(store_helper "" resolve "$a" "$x" 2>/dev/null | tail -n1 || true)"
                if [[ "$v" =~ $ADDON_VERSION_RE ]]; then
                    index+="$x $a $v"$'\n'
                    store_prepare "$a" "$v"
                else
                    log_message "Склад аддонов: последнюю версию $a ($x) узнать не удалось." "warning"
                fi
                ;;
            want)
                # у Metamod версия на складе — номер билда, а закрепление может быть 2.0.0-git1380
                if [ "$a" = metamod ]; then store_prepare metamod "git${x##*git}" "$x"
                elif [ "$a" = modsharp ]; then v="git-${x#git}"; store_prepare modsharp "${v/git--/git-}"
                else store_prepare "$a" "$x"
                fi
                ;;
        esac
    done < <(addon_needs)

    # Закрепление на всю ноду
    for a in metamod css swiftly modsharp; do
        x="PIN_${a^^}"
        pin="${!x:-}"
        [ -n "$pin" ] || continue
        if [[ ! "$pin" =~ $ADDON_VERSION_RE ]]; then
            log_message "$x='$pin' — не версия, пропускаю." "warning"
            continue
        fi
        index+="pin $a $pin"$'\n'
        if [ "$a" = metamod ]; then store_prepare metamod "git${pin##*git}" "$pin"
        elif [ "$a" = modsharp ]; then v="git-${pin#git}"; store_prepare modsharp "${v/git--/git-}"
        else store_prepare "$a" "$pin"
        fi
    done

    { printf 'updated %s\n' "$(date +%s)"; printf '%s' "$index"; } > "$ADDON_STORE_DIR/index.tmp"
    chmod 644 "$ADDON_STORE_DIR/index.tmp"
    mv "$ADDON_STORE_DIR/index.tmp" "$ADDON_STORE_DIR/index"
    rm -f "$STORE_ENV"

    # Уборка: версии, которые 30 дней никому не были нужны, и недоделанные
    find "$ADDON_STORE_DIR" -mindepth 3 -maxdepth 3 -name .ready -mtime +30 -printf '%h\n' 2>/dev/null \
        | xargs -r rm -rf
    find "$ADDON_STORE_DIR" -mindepth 1 -maxdepth 1 -name '.prep.*' -mmin +120 -exec rm -rf {} + 2>/dev/null || true
    find "$ADDON_STORE_DIR" -mindepth 1 -maxdepth 1 -type d -empty -delete 2>/dev/null || true
    return 0
}
