#!/bin/bash
set -Eeuo pipefail

source "./utils/logging.sh"
trap 'handle_error "$LINENO" "$BASH_COMMAND"' ERR

# Проверяем наличие .env
if [ -f ".env" ]; then
    source ".env"
else
    log_message "Файл .env не найден. Сначала запустите ./install.sh" "error"
    exit 1
fi

source "./utils/managerSteamCMD.sh"
source "./utils/version.sh"

# 1) Проверка, установлены ли SteamCMD и файлы CS2
check_initial_install() {
    if [ ! -f "${BASE_DIR:-/home/cs2_base}/server/steamcmd/steamcmd.sh" ] \
       || [ ! -d "${BASE_DIR:-/home/cs2_base}/server/game/csgo" ]; then
        log_message "Выполняем первоначальную установку CS2..." "running"
        install_or_update
    else
        log_message "CS2 и SteamCMD уже присутствуют. Продолжаем..." "debug"
    fi
}

# 2) Основной цикл
main_loop() {
    while true; do
        # Даем возможность функции check_server_version вернуть «особый» код
        set +e
        check_server_version
        local status=$?
        set -e

        if [ "$status" -eq 200 ]; then
            UPDATE_IN_PROGRESS=1

            local cd_time="${UPDATE_COUNTDOWN_TIME:-300}"
            log_message "Оповещаем игроков и ждём $cd_time сек. перед перезапуском..." "running"
            set +e
            inform_players_and_wait "$cd_time"

            log_message "Останавливаем нужные сервера..." "running"
            local running_list
            running_list="$(stop_running_servers_for_update)"
            set -e

            sleep 10

            install_or_update

            log_message "Запускаем обратно остановленные сервера..." "running"
            set +e
            start_servers_with_delay "$running_list"
            set -e

            UPDATE_IN_PROGRESS=0
        fi

        # 2.5) Ждём перед следующей проверкой версии
        sleep "${VERSION_CHECK_INTERVAL:-300}"
    done
}

check_initial_install
log_message "CS2 Updater запущен." "info"
main_loop
