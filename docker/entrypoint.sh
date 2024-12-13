#!/bin/bash

source /scripts/cleanup.sh
source /scripts/update.sh
source /scripts/filter.sh

# Enhanced error handling
trap 'handle_error ${LINENO} "$BASH_COMMAND"' ERR

# Путь к базовым файлам и файлам в контейнере
BASE_FILES="/home/base_files"
CONTAINER_FILES="/home/container"
MERGED_DIR="/home/container/merged"

mkdir -p /home/container/userFiles
mkdir -p /home/container/serverfiles
mkdir -p $MERGED_DIR

mount -t overlay overlay -o lowerdir=$BASE_FILES,upperdir=/home/container/userFiles,workdir=/home/container/serverfiles $MERGED_DIR

cd $MERGED_DIR
sleep 1

# Get internal Docker IP
INTERNAL_IP=$(ip route get 1 | awk '{print $NF;exit}')

# Initial setup and sync
clean_old_logs
initialize_server_cfg
configure_metamod

# Run cleanup and setup message filter
cleanup_and_update
setup_message_filter

# Prepare startup command
MODIFIED_STARTUP=$(eval echo $(echo ${STARTUP} | sed -e 's/{{/${/g' -e 's/}}/}/g'))
MODIFIED_STARTUP="unbuffer -p ${MODIFIED_STARTUP}"

# Log censored startup command
LOGGED_STARTUP=$(echo "${MODIFIED_STARTUP#unbuffer -p }" | \
    sed -E 's/(\+sv_setsteamaccount\s+[A-Z0-9]{32})/+sv_setsteamaccount ************************/g')
log_message "Starting server with command: ${LOGGED_STARTUP}" "running"

# Run the server with output handling
$MODIFIED_STARTUP 2>&1 | while IFS= read -r line; do
    line="${line%[[:space:]]}"
    [[ "$line" =~ Segmentation\ fault.*"${GAMEEXE}" ]] && continue
    handle_server_output "$line"
done

# Kill all background processes
pkill -P $$ 2>/dev/null || true

log_message "Server has stopped successfully." "success"