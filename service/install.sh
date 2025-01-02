#!/bin/bash
set -Eeuo pipefail

source "./utils/logging.sh"
trap 'handle_error "$LINENO" "$BASH_COMMAND"' ERR

check_not_empty() {
    local var_val="$1"
    local prompt="$2"
    if [ -z "$var_val" ]; then
        log_message "Значение '$prompt' не может быть пустым. Повторите ввод." "error"
        return 1
    fi
    return 0
}

create_env_file() {
    cat <<EOF > .env
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

VERSION_CHECK_INTERVAL="$VERSION_CHECK_INTERVAL"
UPDATE_COUNTDOWN_TIME="$UPDATE_COUNTDOWN_TIME"
EOF

    log_message ".env создан/обновлён" "success"
}

main() {
    log_message "Добро пожаловать в установщик CS2" "info"

    read -rp "Введите имя systemd-сервиса (например cs2.service): " SERVICE_NAME
    check_not_empty "$SERVICE_NAME" "Имя сервиса" || exit 1

    read -rp "Укажите BASE_DIR (по умолчанию /home/cs2_base): " BASE_DIR
    BASE_DIR="${BASE_DIR:-/home/cs2_base}"
    read -rp "AppID (SRCDS_APPID) (по умолчанию 730): " SRCDS_APPID
    SRCDS_APPID="${SRCDS_APPID:-730}"
    read -rp "Steam User (STEAM_USER), по умолчанию anonymous: " STEAM_USER
    STEAM_USER="${STEAM_USER:-anonymous}"
    read -rp "Steam Pass (STEAM_PASS), можно оставить пустым: " STEAM_PASS
    read -rp "Steam Auth (STEAM_AUTH), можно оставить пустым: " STEAM_AUTH
    read -rp "EXTRA_FLAGS (для SteamCMD), можно оставить пустым: " EXTRA_FLAGS
    
    read -rp "Pelican Application URL (PELICAN_URL) (например https://cp.armaturix.net): " PELICAN_URL
    read -rp "Pelican App Token (PELICAN_APP_TOKEN) (application API): " PELICAN_APP_TOKEN
    read -rp "Pelican Client Token (PELICAN_API_TOKEN) (client API): " PELICAN_API_TOKEN
    read -rp "Pelican образ (PELICAN_IMAGE) (по умолчанию docker.io/scrender/base-files-cs2:dev): " PELICAN_IMAGE
    PELICAN_IMAGE="${PELICAN_IMAGE:-docker.io/scrender/base-files-cs2:dev}"

    read -rp "Интервал проверки версии (сек) (VERSION_CHECK_INTERVAL=300): " VERSION_CHECK_INTERVAL
    VERSION_CHECK_INTERVAL="${VERSION_CHECK_INTERVAL:-300}"
    read -rp "Время отсчёта до рестарта (сек) (UPDATE_COUNTDOWN_TIME=300): " UPDATE_COUNTDOWN_TIME
    UPDATE_COUNTDOWN_TIME="${UPDATE_COUNTDOWN_TIME:-300}"

    create_env_file

    # Создаём systemd unit
    sudo bash -c "cat <<EOF > /etc/systemd/system/$SERVICE_NAME
[Unit]
Description=CS2 Updater Service
After=network-online.target

[Service]
Type=simple
ExecStart=$(pwd)/start.sh
WorkingDirectory=$(pwd)
Restart=always

[Install]
WantedBy=multi-user.target
EOF
"
    sudo systemctl daemon-reload
    sudo systemctl enable "$SERVICE_NAME"

    log_message "Установка завершена. Запустите: sudo systemctl start $SERVICE_NAME" "success"
}

main
