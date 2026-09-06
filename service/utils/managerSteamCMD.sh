#!/bin/bash
set -Eeuo pipefail
trap 'handle_error "$LINENO" "$BASH_COMMAND"' ERR

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/logging.sh"

STEAMCMD_URL="https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz"

install_steamcmd() {
    local base_dir="$1"

    log_message "Устанавливаем SteamCMD..." "running"
    mkdir -p "$base_dir/server/steamcmd" "$base_dir/server/steamapps"

    local tarball
    tarball="$(mktemp -t steamcmd.XXXXXX.tar.gz)"

    local max_retries=3 retry=0 ok=0
    while [ "$retry" -lt "$max_retries" ]; do
        if curl -fsSL --connect-timeout 30 --max-time 300 -o "$tarball" "$STEAMCMD_URL"; then
            ok=1
            break
        fi
        # NB: НЕ ((retry++)) — при retry=0 постинкремент возвращает статус 1,
        # и под `set -e` цикл ретраев умирал на первой же попытке.
        retry=$((retry + 1))
        log_message "Попытка загрузки SteamCMD #$retry из $max_retries провалилась, повтор через 5 сек..." "warning"
        sleep 5
    done

    if [ "$ok" -ne 1 ]; then
        rm -f "$tarball"
        log_message "Не удалось скачать SteamCMD после $max_retries попыток." "error"
        return 1
    fi

    if ! tar -xzf "$tarball" -C "$base_dir/server/steamcmd"; then
        rm -f "$tarball"
        log_message "Не удалось распаковать архив SteamCMD." "error"
        return 1
    fi
    rm -f "$tarball"

    chmod +x "$base_dir/server/steamcmd/linux32/steamcmd"
    log_message "SteamCMD установлен." "success"
    return 0
}

install_or_update() {
    local SRCDS_APPID="${SRCDS_APPID:-730}"
    local STEAM_USER="${STEAM_USER:-anonymous}"
    local STEAM_PASS="${STEAM_PASS:-}"
    local STEAM_AUTH="${STEAM_AUTH:-}"
    local EXTRA_FLAGS="${EXTRA_FLAGS:-}"
    local BASE_DIR="${BASE_DIR:-/home/cs2_base}"

    if [ ! -f "$BASE_DIR/server/steamcmd/steamcmd.sh" ]; then
        # 32-битные библиотеки ставит install.sh: здесь sudo недоступен —
        # start.sh крутится под systemd без TTY.
        install_steamcmd "$BASE_DIR" || return 1
    fi

    # Пустые аргументы login ломают steamcmd, поэтому собираем их по факту
    local -a login_args=("$STEAM_USER")
    [ -n "$STEAM_PASS" ] && login_args+=("$STEAM_PASS")
    [ -n "$STEAM_AUTH" ] && login_args+=("$STEAM_AUTH")

    log_message "Запускаем SteamCMD для установки/обновления CS2 (appid $SRCDS_APPID)..." "running"

    # `if !` вместо проверки $? после команды: под `set -e` до неё было не дойти.
    # EXTRA_FLAGS намеренно без кавычек — это список флагов.
    # shellcheck disable=SC2086
    if ! "$BASE_DIR/server/steamcmd/steamcmd.sh" \
        +force_install_dir "$BASE_DIR/server" \
        +login "${login_args[@]}" \
        +app_update "$SRCDS_APPID" $EXTRA_FLAGS \
        +quit
    then
        local sc_exit=$?
        log_message "SteamCMD завершился с кодом $sc_exit. Проверьте: доступность Steam, креды, свободное место." "error"
        return "$sc_exit"
    fi

    mkdir -p "$BASE_DIR/server/.steam/sdk32" "$BASE_DIR/server/.steam/sdk64"
    cp "$BASE_DIR/server/steamcmd/linux32/steamclient.so" "$BASE_DIR/server/.steam/sdk32/" 2>/dev/null || true
    cp "$BASE_DIR/server/steamcmd/linux64/steamclient.so" "$BASE_DIR/server/.steam/sdk64/" 2>/dev/null || true

    log_message "CS2 успешно установлена/обновлена." "success"
    return 0
}
