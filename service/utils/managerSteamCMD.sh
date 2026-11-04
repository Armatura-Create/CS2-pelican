#!/bin/bash
set -Eeuo pipefail
trap 'handle_error "$LINENO" "$BASH_COMMAND"' ERR

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/logging.sh"

STEAMCMD_URL="https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz"

# SteamCMD живёт РЯДОМ с файлами игры, а не внутри $BASE_DIR/server: тот каталог
# смонтирован в /mnt каждого контейнера, а SteamCMD кэширует в своём config/
# токен входа в Steam-аккаунт — его прочитал бы любой сервер ноды.
steamcmd_dir() {
    printf '%s' "${BASE_DIR:-/home/cs2_base}/steamcmd"
}

# До v1.2.12 SteamCMD стоял в $BASE_DIR/server/steamcmd. Переносим один раз:
# тот же раздел, mv мгновенный. Симлинки на старый путь в контейнерах станут
# битыми, и remove_stale_symlinks уберёт их при следующем старте сервера.
migrate_steamcmd_dir() {
    local old="${BASE_DIR:-/home/cs2_base}/server/steamcmd" new
    new="$(steamcmd_dir)"
    [ -d "$old" ] && [ ! -e "$new" ] || return 0
    if mv "$old" "$new"; then
        log_message "SteamCMD перенесён из общих файлов игры в $new: контейнеры его больше не видят." "info"
    else
        log_message "Не удалось перенести SteamCMD из $old в $new — поставлю заново при надобности." "warning"
    fi
}

install_steamcmd() {
    local dir
    dir="$(steamcmd_dir)"

    log_message "Устанавливаем SteamCMD..." "running"
    mkdir -p "$dir" "${BASE_DIR:-/home/cs2_base}/server/steamapps"

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

    if ! tar -xzf "$tarball" -C "$dir"; then
        rm -f "$tarball"
        log_message "Не удалось распаковать архив SteamCMD." "error"
        return 1
    fi
    rm -f "$tarball"

    chmod +x "$dir/linux32/steamcmd"
    log_message "SteamCMD установлен." "success"
    return 0
}

# install_or_update [таймаут, сек]
# Таймаут — для цикла обновления: серверы в это время выключены, и зависший
# SteamCMD держал их выключенными часами. Первую установку (~40 ГБ) не ограничиваем.
install_or_update() {
    local limit="${1:-0}"
    local SRCDS_APPID="${SRCDS_APPID:-730}"
    local STEAM_USER="${STEAM_USER:-anonymous}"
    local STEAM_PASS="${STEAM_PASS:-}"
    local STEAM_AUTH="${STEAM_AUTH:-}"
    local EXTRA_FLAGS="${EXTRA_FLAGS:-}"
    local BASE_DIR="${BASE_DIR:-/home/cs2_base}"
    local dir
    dir="$(steamcmd_dir)"

    if [ ! -f "$dir/steamcmd.sh" ]; then
        # 32-битные библиотеки ставит install.sh: здесь sudo недоступен —
        # start.sh крутится под systemd без TTY.
        install_steamcmd || return 1
    fi

    log_message "Запускаем SteamCMD для установки/обновления CS2 (appid $SRCDS_APPID)..." "running"

    # Пароль Steam — НЕ аргументом: аргументы видны всем пользователям хоста в
    # `ps` и /proc/<pid>/cmdline. Для входа с паролем команды идут файлом
    # +runscript с правами 600 в /run (tmpfs, только root), файл удаляется сразу.
    local -a cmd=("$dir/steamcmd.sh")
    local script=""
    # shellcheck disable=SC2086
    if [ "$STEAM_USER" = "anonymous" ] || [ -z "$STEAM_PASS" ]; then
        cmd+=(+force_install_dir "$BASE_DIR/server" +login "$STEAM_USER" +app_update "$SRCDS_APPID" $EXTRA_FLAGS +quit)
    else
        script="$(umask 077; mktemp -p /run cs2-steamcmd.XXXXXX 2>/dev/null || mktemp)"
        printf '@ShutdownOnFailedCommand 1\n@NoPromptForPassword 1\nforce_install_dir %s\nlogin %s %s %s\napp_update %s %s\nquit\n' \
            "$BASE_DIR/server" "$STEAM_USER" "$STEAM_PASS" "$STEAM_AUTH" "$SRCDS_APPID" "$EXTRA_FLAGS" > "$script"
        cmd+=(+runscript "$script")
    fi
    [ "$limit" -gt 0 ] 2>/dev/null && cmd=(timeout --kill-after=60 "$limit" "${cmd[@]}")

    # `|| sc_exit=$?`, а НЕ `if ! cmd; then sc_exit=$?`: внутри ветки `then`
    # у `if ! cmd` в $? лежит статус самого отрицания, то есть всегда 0.
    # Из-за этого код возврата SteamCMD терялся: в лог шло «код 0», функция
    # возвращала успех, и провалившееся обновление игры выдавалось за успешное.
    # Форма `cmd || var=$?` заодно глушит errexit — до проверки мы дойдём.
    local sc_exit=0
    "${cmd[@]}" || sc_exit=$?
    [ -z "$script" ] || rm -f "$script"

    if [ "$sc_exit" -eq 124 ] || [ "$sc_exit" -eq 137 ]; then
        log_message "SteamCMD не уложился в $limit сек. и остановлен. Серверы поднимем на том, что есть." "error"
        return "$sc_exit"
    fi
    if [ "$sc_exit" -ne 0 ]; then
        log_message "SteamCMD завершился с кодом $sc_exit. Проверьте: доступность Steam, креды, свободное место." "error"
        return "$sc_exit"
    fi

    mkdir -p "$BASE_DIR/server/.steam/sdk32" "$BASE_DIR/server/.steam/sdk64"
    cp "$dir/linux32/steamclient.so" "$BASE_DIR/server/.steam/sdk32/" 2>/dev/null || true
    cp "$dir/linux64/steamclient.so" "$BASE_DIR/server/.steam/sdk64/" 2>/dev/null || true

    log_message "CS2 успешно установлена/обновлена." "success"
    return 0
}
