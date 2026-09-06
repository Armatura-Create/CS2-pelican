FROM registry.gitlab.steamos.cloud/steamrt/sniper/platform:latest-container-runtime-depot

LABEL author="Armatura" \
      maintainer="alext303@gmail.com" \
      org.opencontainers.image.description="Minimal SteamRT3 base image for Pelican CS2" \
      org.opencontainers.image.source="https://github.com/Armatura-Create/CS2-pelican"

# Подготавливаем окружение
ENV DEBIAN_FRONTEND=noninteractive

# ВАЖНО: не оставляем NOPASSWD-правило sudo.
# Базовый образ содержит sudo; правило "%sudo ALL=(ALL:ALL) NOPASSWD: ALL"
# из flatdeb-заготовки давало бы passwordless root любому процессу в группе
# sudo. Скриптам egg'а sudo не нужен ни на одном шаге.
RUN rm -f /etc/sudoers.d/flatdeb

# Устанавливаем пакеты
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       iproute2 jq unzip expect rsync bc \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Пользователь container. Базовый образ его НЕ содержит, из-за чего образ
# невозможно было запустить напрямую (`docker run` падал с "unable to find user
# container"); под Wings это не всплывало, потому что он задаёт uid численно.
RUN useradd -m -d /home/container -s /bin/bash container

# Создаём директории и копируем файлы
RUN mkdir -p /scripts /utils /mnt

COPY ./scripts/ /scripts/
COPY ./utils/ /utils/
COPY ./entrypoint.sh /entrypoint.sh
COPY ./servUpConfig.cfg /servUpConfig.cfg

# Устанавливаем права на выполнение
RUN chmod +x /scripts/*.sh \
    && chmod +x /utils/*.sh \
    && chmod +x /entrypoint.sh

USER container
ENV USER=container HOME=/home/container
WORKDIR /home/container

# По умолчанию запуск
CMD [ "/bin/bash", "/entrypoint.sh" ]
