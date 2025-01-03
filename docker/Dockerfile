FROM        registry.gitlab.steamos.cloud/steamrt/sniper/platform:latest-container-runtime-depot

LABEL       author="Armatura" \
            maintainer="alext303@gmail.com" \
            org.opencontainers.image.description="Minimal SteamRT3 base image for Pelican CS2" \
            org.opencontainers.image.source="https://github.com/Armatura-Create/CS2-pelican"

# Prep OS
RUN         mkdir -p /etc/sudoers.d && \
            echo "%sudo ALL=(ALL:ALL) NOPASSWD: ALL" > /etc/sudoers.d/flatdeb && \
            chmod 0440 /etc/sudoers.d/flatdeb

ENV         DEBIAN_FRONTEND=noninteractive
RUN         apt update && \
            apt install -y iproute2 jq unzip expect rsync && \
            apt-get clean

# Create directories and copy files
RUN         mkdir -p /scripts /utils
RUN         mkdir -p /mnt
COPY        ./scripts/* /scripts/
COPY        ./utils/* /utils/
COPY        ./entrypoint.sh /entrypoint.sh
COPY        ./servUpConfig.cfg /servUpConfig.cfg

# Set permissions
RUN         chmod +x /scripts/*.sh && \
            chmod +x /utils/*.sh && \
            chmod +x /entrypoint.sh

USER        container
ENV         USER=container HOME=/home/container
WORKDIR     /home/container

CMD         [ "/bin/bash", "/entrypoint.sh" ]