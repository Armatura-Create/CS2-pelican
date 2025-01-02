#!/bin/bash
set -Eeuo pipefail

source "./utils/logging.sh"
trap 'handle_error "$LINENO" "$BASH_COMMAND"' ERR

if [ -f ".env" ]; then
    source ".env"
else
    log_message "Файл .env не найден. Сначала запустите install.sh" "error"
    exit 1
fi

source "./utils/managerSteamCMD.sh"
source "./utils/version.sh"

# При первом запуске проверим, что SteamCMD и CS2-файлы вообще есть
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
        check_server_version
        local status=$?
        if [ $status -eq 2 ]; then
            UPDATE_IN_PROGRESS=1

            # Обратный отсчёт и уведомление игроков — только на тех, что running
            local cd_time="${UPDATE_COUNTDOWN_TIME:-300}"
            log_message "Оповещаем игроков и ждём $cd_time сек. перед рестартом..." "running"
            inform_players_and_wait "$cd_time"

            # Останавливаем только running сервера. Сохраняем их список
            log_message "Останавливаем нужные сервера..." "running"
            local running_list
            running_list="$(stop_running_servers_for_update)"

            # Ждём немного перед обновлением
            sleep 10

            # Выполняем обновление через SteamCMD
            install_or_update

            # Запускаем только те, что были running
            log_message "Запускаем обратно сервера, которые были запущены..." "running"
            start_servers_with_delay "$running_list"

            UPDATE_IN_PROGRESS=0
        fi

        sleep "${VERSION_CHECK_INTERVAL:-300}"
    done
}

check_initial_install
log_message "CS2 Updater запущен" "info"
main_loop
