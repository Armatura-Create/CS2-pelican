#!/bin/bash
set -Eeuo pipefail

# Работаем от каталога скрипта: systemd задаёт WorkingDirectory, но запуск
# вручную из другого каталога ломал относительные пути (./utils, ./.env).
cd "$(dirname "$(readlink -f "$0")")"

source "./utils/logging.sh"
trap 'handle_error "$LINENO" "$BASH_COMMAND"' ERR

if [ -f ".env" ]; then
    # shellcheck disable=SC1091
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
        if ! install_or_update; then
            log_message "Первоначальная установка не удалась. Повторим на следующей итерации." "error"
        fi
    else
        log_message "CS2 и SteamCMD уже присутствуют. Продолжаем..." "debug"
    fi
}

# Лок держится весь цикл обновления CS2 — от оповещения игроков до запуска
# серверов. По нему update.sh (в том числе ночной автоматический) видит, что
# останавливать сервис сейчас нельзя. flock снимается ядром вместе со смертью
# процесса, поэтому «зависшего» лока после падения не бывает.
# Путь обязан совпадать с CYCLE_LOCK в update.sh.
CYCLE_LOCK="/run/cs2-updater-cycle.lock"

# 2) Обновление: оповестить, остановить, обновить, поднять обратно
run_update_cycle() {
    # Без лока цикл всё равно идёт: обновить игру важнее, чем защитить его
    # от одновременного обновления самого апдейтера.
    local lock_fd=""
    if { exec {lock_fd}>"$CYCLE_LOCK"; } 2>/dev/null; then
        flock "$lock_fd" || true
    else
        log_message "Не удалось открыть $CYCLE_LOCK — update.sh не увидит, что идёт обновление CS2." "warning"
    fi

    local cd_time="${UPDATE_COUNTDOWN_TIME:-300}"
    log_message "Оповещаем игроков и ждём $cd_time сек. перед перезапуском..." "running"
    inform_players_and_wait "$cd_time" || true

    log_message "Останавливаем нужные сервера..." "running"
    local running_list
    running_list="$(stop_running_servers_for_update || true)"

    sleep 10

    # КРИТИЧНО: что бы ни случилось со SteamCMD, остановленные серверы обязаны
    # вернуться. Раньше падение install_or_update убивало сервис и оставляло
    # все игровые серверы выключенными.
    if ! install_or_update; then
        log_message "Обновление CS2 не удалось. Поднимаем серверы на старой версии." "error"
    fi

    log_message "Запускаем обратно остановленные сервера..." "running"
    start_servers_with_delay "$running_list" || true
    verify_servers_started "$running_list" || true

    [ -z "$lock_fd" ] || exec {lock_fd}>&-
    log_message "Цикл обновления CS2 завершён." "info"
}

main_loop() {
    while true; do
        if update_available; then
            run_update_cycle
        fi
        sleep "${VERSION_CHECK_INTERVAL:-300}"
    done
}

check_initial_install
log_message "CS2 Updater запущен." "info"
main_loop
