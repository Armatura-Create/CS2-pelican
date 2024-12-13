#!/bin/bash

# Set default values
SRCDS_APPID=730
STEAM_USER=anonymous
STEAM_PASS=""
STEAM_AUTH=""
EXTRA_FLAGS=""

# Check if SteamCMD is already installed
if [ -f "/home/cs2_base/server/steamcmd/steamcmd.sh" ]; then
    echo "SteamCMD is already installed"
    exit 0
fi

echo "Installing SteamCMD..."
STEAMCMD_URL="https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz"
max_retries=3
retry=0

# Создаем необходимые директории
mkdir -p /home/cs2_base/server/steamcmd
mkdir -p /home/cs2_base/server/steamapps

# Скачиваем SteamCMD с попытками повторной загрузки
while [ $retry -lt $max_retries ]; do
    if curl -sSL --connect-timeout 30 --max-time 300 -o steamcmd.tar.gz "$STEAMCMD_URL"; then
        break
    fi
    ((retry++))
    echo "Download attempt $retry failed, retrying..."
    sleep 5
done

if [ $retry -eq $max_retries ]; then
    echo "Failed to download SteamCMD after $max_retries attempts"
    exit 1
fi

# Распаковываем SteamCMD
if ! tar -xzvf steamcmd.tar.gz -C /home/cs2_base/server/steamcmd; then
    echo "Failed to extract SteamCMD"
    exit 1
fi
rm steamcmd.tar.gz

# Проверяем наличие директории SteamCMD
if [ ! -d "/home/cs2_base/server/steamcmd" ]; then
    echo "steamcmd directory does not exist"
    exit 1
fi

# Исправляем права доступа
chown -R root:root /home/cs2_base/server/steamcmd
chmod +x /home/cs2_base/server/steamcmd/linux32/steamcmd

# Проверяем зависимости
echo "Installing dependencies..."
apt update
apt install -y lib32gcc-s1 lib32stdc++6

export LD_LIBRARY_PATH=/home/cs2_base/server/steamcmd/linux32:$LD_LIBRARY_PATH

# Устанавливаем игру через SteamCMD
/home/cs2_base/server/steamcmd/steamcmd.sh +force_install_dir /home/cs2_base/server +login ${STEAM_USER} ${STEAM_PASS} ${STEAM_AUTH} +app_update ${SRCDS_APPID} ${EXTRA_FLAGS} +quit

# Настраиваем 32-битные библиотеки
mkdir -p /home/cs2_base/server/.steam/sdk32
cp -v /home/cs2_base/server/steamcmd/linux32/steamclient.so /home/cs2_base/server/.steam/sdk32/steamclient.so || {
    echo "Failed to copy 32-bit libraries"
}

# Настраиваем 64-битные библиотеки
mkdir -p /home/cs2_base/server/.steam/sdk64
cp -v /home/cs2_base/server/steamcmd/linux64/steamclient.so /home/cs2_base/server/.steam/sdk64/steamclient.so || {
    echo "Failed to copy 64-bit libraries"
}

echo "SteamCMD installed successfully"