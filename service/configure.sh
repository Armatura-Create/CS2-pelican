#!/bin/bash
#
# Интерактивный настройщик: спрашивает параметры, пишет .env и systemd-юнит.
# Его вызывает install.sh при установке. Вручную запускать НЕ нужно —
# он перезапишет .env с вашими токенами. Для обновления есть update.sh.
#
set -Eeuo pipefail

# Работаем от каталога скрипта, чтобы запуск из другого cwd не ломал пути
cd "$(dirname "$(readlink -f "$0")")"

source "./utils/logging.sh"
trap 'handle_error "$LINENO" "$BASH_COMMAND"' ERR

########################################
# Установка необходимых зависимостей
########################################
install_dependencies() {
    log_message "Устанавливаем системные зависимости (apt)..." "running"
    sudo apt-get update -y
    sudo apt-get install -y curl jq unzip lib32gcc-s1 lib32stdc++6
    log_message "Зависимости успешно установлены." "success"
}

########################################
# Функция ввода (непустое)
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
            # printf -v, а не eval: eval исполнял бы ввод пользователя
            printf -v "$var_name" '%s' "$val"
            break
        fi
    done
}

########################################
# Функция ввода (по умолчанию)
########################################
prompt_with_default() {
    local var_name="$1"
    local question="$2"
    local default_val="$3"

    read -rp "$question [$default_val]: " val
    if [ -z "$val" ]; then
        val="$default_val"
    fi
    printf -v "$var_name" '%s' "$val"
}

########################################
# Создание файла .env
########################################
create_env_file() {
    # 600 ДО записи: в .env лежат пароль Steam и оба токена Pelican
    rm -f .env
    (umask 077; : > .env)
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

LOG_LEVEL="$LOG_LEVEL"
LOG_FILE_ENABLED="$LOG_FILE_ENABLED"
EOF

    chmod 600 .env
    log_message ".env файл создан/обновлён (права 600)." "success"
}

########################################
# Основной процесс установки
########################################
main() {
    log_message "Добро пожаловать в настройщик CS2 Updater!" "info"

    # 1) Устанавливаем зависимости
    install_dependencies

    # 2) Сбор значений
    prompt_required SERVICE_NAME \
        "Введите имя systemd-сервиса (например cs2.service):" \
        "Имя сервиса не может быть пустым!"

    prompt_with_default BASE_DIR \
        "Укажите BASE_DIR" \
        "/home/cs2_base"

    prompt_with_default SRCDS_APPID \
        "AppID (SRCDS_APPID)" \
        "730"

    prompt_with_default STEAM_USER \
        "Steam User (STEAM_USER)" \
        "anonymous"

    read -rsp "Steam Pass (STEAM_PASS) (можно пусто, ввод скрыт): " STEAM_PASS; echo
    read -rsp "Steam Auth (STEAM_AUTH) (можно пусто, ввод скрыт): " STEAM_AUTH; echo
    read -rp "EXTRA_FLAGS (для SteamCMD, можно пусто): " EXTRA_FLAGS

    prompt_required PELICAN_URL \
        "Pelican URL (например https://cp.armaturix.net):" \
        "PELICAN_URL не может быть пустым!"

    prompt_required PELICAN_APP_TOKEN \
        "Pelican App Token (application API):" \
        "PELICAN_APP_TOKEN не может быть пустым!"

    prompt_required PELICAN_API_TOKEN \
        "Pelican Client Token (client API):" \
        "PELICAN_API_TOKEN не может быть пустым!"

    prompt_with_default PELICAN_IMAGE \
        "Образ для Pelican (PELICAN_IMAGE)" \
        "docker.io/scrender/base-files-cs2:latest"

    prompt_with_default PELICAN_NODE_ID \
        "Pelican NODE ID" \
        "1"

    prompt_with_default VERSION_CHECK_INTERVAL \
        "Интервал проверки версии (сек)" \
        "300"

    prompt_with_default UPDATE_COUNTDOWN_TIME \
        "Время отсчёта перед рестартом (сек)" \
        "300"

    # Параметры логирования
    prompt_with_default LOG_LEVEL \
        "Укажите уровень логирования (DEBUG/INFO/WARNING/ERROR)" \
        "INFO"
    prompt_with_default LOG_FILE_ENABLED \
        "Включить лог в файл? (1 - да, 0 - нет)" \
        "1"

    # 3) Создаём .env
    create_env_file

    # systemd запускает start.sh напрямую — бит выполнения обязателен
    chmod +x start.sh test-pelican.sh

    # 4) Создаём systemd unit
    local service_dir
    service_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    if [[ "$SERVICE_NAME" != *.service ]]; then
        SERVICE_NAME="${SERVICE_NAME}.service"
    fi

    if [[ "$SERVICE_NAME" == *"/"* ]]; then
        log_message "Имя systemd-сервиса не должно содержать '/': $SERVICE_NAME" "error"
        exit 1
    fi

    sudo tee "/etc/systemd/system/${SERVICE_NAME}" > /dev/null <<EOF
[Unit]
Description=CS2 Updater Service
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
ExecStart=${service_dir}/start.sh
WorkingDirectory=${service_dir}
Restart=always

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable "$SERVICE_NAME"

    log_message "Настройка завершена. Запуск: sudo systemctl start $SERVICE_NAME" "success"
}

main
