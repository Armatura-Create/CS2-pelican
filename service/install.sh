#!/bin/bash
set -Eeuo pipefail

source "./utils/logging.sh"
trap 'handle_error "$LINENO" "$BASH_COMMAND"' ERR

########################################
# Устанавливаем зависимости
########################################
install_dependencies() {
    log_message "Устанавливаем системные зависимости..." "running"
    # Для apt-based систем (Debian/Ubuntu)
    sudo apt-get update -y
    sudo apt-get install -y curl jq unzip lib32gcc-s1 lib32stdc++6
    log_message "Все необходимые зависимости установлены." "success"
}

########################################
# Спрашивает у пользователя значение,
# пока не введёт непустую строку.
# Usage: prompt_required VAR "Question?" "Error message"
########################################
prompt_required() {
    local var_name="$1"
    local question="$2"
    local error_msg="$3"

    while true; do
        read -rp "$question " val
        if [ -z "$val" ]; then
            log_message "$error_msg" "error"
        else
            # Записываем результат в нужную переменную
            eval "$var_name=\"$val\""
            break
        fi
    done
}

########################################
# Спрашивает у пользователя значение,
# если пусто, берёт default.
# Usage: prompt_with_default VAR "Question?" "DefaultVal"
########################################
prompt_with_default() {
    local var_name="$1"
    local question="$2"
    local default_val="$3"

    read -rp "$question [$default_val]: " val
    if [ -z "$val" ]; then
        val="$default_val"
    fi
    eval "$var_name=\"$val\""
}

########################################
# Создание .env файла
########################################
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
PELICAN_NODE_ID="$PELICAN_NODE_ID"

VERSION_CHECK_INTERVAL="$VERSION_CHECK_INTERVAL"
UPDATE_COUNTDOWN_TIME="$UPDATE_COUNTDOWN_TIME"
EOF

    log_message ".env создан/обновлён" "success"
}

########################################
# Основная логика установки
########################################
main() {
    log_message "Добро пожаловать в установщик CS2" "info"

    # 1. Ставим зависимости
    install_dependencies

    # 2. Собираем переменные окружения
    #    a) Пример: требуется непустое имя сервиса
    prompt_required SERVICE_NAME \
        "Введите имя systemd-сервиса (например cs2.service):" \
        "Имя сервиса не может быть пустым!"

    #    b) Путь BASE_DIR с дефолтом /home/cs2_base
    prompt_with_default BASE_DIR \
        "Укажите BASE_DIR" \
        "/home/cs2_base"

    #    c) AppID с дефолтом 730
    prompt_with_default SRCDS_APPID \
        "AppID (SRCDS_APPID)" \
        "730"

    #    d) Steam User (может быть пустым -> тогда anon)
    prompt_with_default STEAM_USER \
        "Steam User (STEAM_USER)" \
        "anonymous"

    #    e) Steam Pass (может быть пустым)
    read -rp "Steam Pass (STEAM_PASS), можно оставить пустым: " STEAM_PASS

    #    f) Steam Auth (может быть пустым)
    read -rp "Steam Auth (STEAM_AUTH), можно оставить пустым: " STEAM_AUTH

    #    g) EXTRA_FLAGS (пусто — ок)
    read -rp "EXTRA_FLAGS (для SteamCMD), можно оставить пустым: " EXTRA_FLAGS

    #    h) Pelican URL (обязательное — предполагаем?)
    prompt_required PELICAN_URL \
        "Pelican Application URL (PELICAN_URL) (например https://cp.armaturix.net):" \
        "PELICAN_URL не может быть пустым!"

    #    i) Pelican App Token (обязательное)
    prompt_required PELICAN_APP_TOKEN \
        "Pelican App Token (PELICAN_APP_TOKEN) (application API):" \
        "PELICAN_APP_TOKEN не может быть пустым!"

    #    j) Pelican Client Token (обязательное)
    prompt_required PELICAN_API_TOKEN \
        "Pelican Client Token (PELICAN_API_TOKEN) (client API):" \
        "PELICAN_API_TOKEN не может быть пустым!"

    #    k) Pelican образ
    prompt_with_default PELICAN_IMAGE \
        "Pelican образ (PELICAN_IMAGE)" \
        "docker.io/scrender/base-files-cs2:dev"

    #    l) Pelican NODE ID (дефолт 1)
    prompt_with_default PELICAN_NODE_ID \
        "Pelican NODE ID (PELICAN_NODE_ID)" \
        "1"

    #    m) VERSION_CHECK_INTERVAL
    prompt_with_default VERSION_CHECK_INTERVAL \
        "Интервал проверки версии (сек) (VERSION_CHECK_INTERVAL)" \
        "300"

    #    n) UPDATE_COUNTDOWN_TIME
    prompt_with_default UPDATE_COUNTDOWN_TIME \
        "Время отсчёта до рестарта (сек) (UPDATE_COUNTDOWN_TIME)" \
        "300"

    # 3. Создаём .env
    create_env_file

    # 4. Создаём systemd unit
    sudo bash -c "cat <<EOF > /etc/systemd/system/\$SERVICE_NAME
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