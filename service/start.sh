#!/bin/bash
set -Eeuo pipefail

source "./utils/logging.sh"
trap 'handle_error "$LINENO" "$BASH_COMMAND"' ERR

if [ -f ".env" ]; then
    source ".env"
else
    log_message "Файл .env не найден. Сначала запустите ./install.sh" "error"
    exit 1
fi

source "./utils/managerSteamCMD.sh"
source "./utils/version.sh"

# Проверка, установлены ли SteamCMD и CS2-файлы
check_initial_install() {
    if [ ! -f "${BASE_DIR:-/home/cs2_base}/server/steamcmd/steamcmd.sh" ] || [ ! -d "${BASE_DIR:-/home/cs2_base}/server/game/csgo" ]; then
        log_message "Выполняем первоначальную установку CS2..." "running"
        install_or_update
    else
        log_message "CS2 и SteamCMD уже присутствуют. Продолжаем..." "debug"
    fi
}

main_loop() {
    while true; do
        set +e
        check_server_version
        local status=$?
        set -e

        # 200 — есть новая версия
        if [ "$status" -eq 200 ]; then
            UPDATE_IN_PROGRESS=1

            # Ждём N секунд, оповещаем игроков
            local cd_time="${UPDATE_COUNTDOWN_TIME:-300}"
            log_message "Оповещаем игроков и ждём $cd_time сек. перед перезапуском..." "running"
            inform_players_and_wait "$cd_time"

            # Останавливаем сервера, которые были в состоянии running
            log_message "Останавливаем нужные сервера..." "running"
            local running_list
            running_list="$(stop_running_servers_for_update)"

            sleep 10

            # Обновляем CS2
            install_or_update

            # Запускаем обратно те, что были running
            log_message "Запускаем обратно остановленные сервера..." "running"
            start_servers_with_delay "$running_list"

            UPDATE_IN_PROGRESS=0
        fi

        sleep "${VERSION_CHECK_INTERVAL:-300}"
    done
}

check_initial_install
log_message "CS2 Updater запущен." "info"
main_loop
