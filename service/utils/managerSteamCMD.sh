#!/bin/bash
set -Eeuo pipefail
trap 'handle_error "$LINENO" "$BASH_COMMAND"' ERR

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/logging.sh"

install_or_update() {
    local SRCDS_APPID="${SRCDS_APPID:-730}"
    local STEAM_USER="${STEAM_USER:-anonymous}"
    local STEAM_PASS="${STEAM_PASS:-}"
    local STEAM_AUTH="${STEAM_AUTH:-}"
    local EXTRA_FLAGS="${EXTRA_FLAGS:-}"
    local BASE_DIR="${BASE_DIR:-/home/cs2_base}"
    local STEAMCMD_URL="https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz"

    # Проверка наличия steamcmd.sh
    if [ ! -f "$BASE_DIR/server/steamcmd/steamcmd.sh" ]; then
        log_message "Устанавливаем SteamCMD..." "running"
        mkdir -p "$BASE_DIR/server/steamcmd" "$BASE_DIR/server/steamapps"

        local max_retries=3
        local retry=0
        while [ $retry -lt $max_retries ]; do
            if curl -sSL --connect-timeout 30 --max-time 300 -o steamcmd.tar.gz "$STEAMCMD_URL"; then
                break
            fi
            ((retry++))
            log_message "Попытка загрузки SteamCMD #$retry провалилась, повтор..." "error"
            sleep 5
        done
        if [ $retry -eq $max_retries ]; then
            log_message "Не удалось скачать SteamCMD после $max_retries попыток" "error"
            exit 1
        fi

        tar -xzvf steamcmd.tar.gz -C "$BASE_DIR/server/steamcmd"
        rm -f steamcmd.tar.gz
        chmod +x "$BASE_DIR/server/steamcmd/linux32/steamcmd"
        # Ставим 32-битные библиотеки
        sudo apt-get update -y
        sudo apt-get install -y lib32gcc-s1 lib32stdc++6
    fi

    log_message "Запускаем SteamCMD для установки/обновления CS2..." "running"
    "$BASE_DIR/server/steamcmd/steamcmd.sh" \
        +force_install_dir "$BASE_DIR/server" \
        +login "$STEAM_USER" "$STEAM_PASS" "$STEAM_AUTH" \
        +app_update "$SRCDS_APPID" $EXTRA_FLAGS \
        +quit
    local sc_exit=$?
    if [ "$sc_exit" -ne 0 ]; then
        # Если SteamCMD вернул не 0, логируем ошибку
        log_message "SteamCMD завершился с кодом $sc_exit. Возможные проблемы: недоступен Steam, неправильные креды, недостаточно места..." "error"
        return "$sc_exit"
    fi

    # Копируем steamclient.so
    mkdir -p "$BASE_DIR/server/.steam/sdk32"
    cp -v "$BASE_DIR/server/steamcmd/linux32/steamclient.so" "$BASE_DIR/server/.steam/sdk32/" || true

    mkdir -p "$BASE_DIR/server/.steam/sdk64"
    cp -v "$BASE_DIR/server/steamcmd/linux64/steamclient.so" "$BASE_DIR/server/.steam/sdk64/" || true

    log_message "CS2 успешно установлена/обновлена." "success"
}
