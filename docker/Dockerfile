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

# Устанавливаем пакеты.
#
# SteamRT3 sniper — это Debian 11 bullseye, поддержка которого закончилась
# 31.08.2026, и bullseye-security переезжает в archive.debian.org. Во время
# переезда индекс на deb.debian.org ещё отдаётся, а файлы пакетов уже 404 —
# сборка падала на apt-get install. Поэтому по порядку:
#   1) как в образе (deb.debian.org/debian-security);
#   2) тот же security-репозиторий, но из archive.debian.org — туда он переедет;
#   3) без security: пакеты из основного bullseye. Хуже по безопасности,
#      но это последний шанс собрать образ вообще.
RUN set -e; \
    PKGS="iproute2 jq unzip expect rsync bc"; \
    try() { apt-get update && apt-get install -y --no-install-recommends $PKGS; }; \
    try \
    || { echo ">>> bullseye-security недоступен на deb.debian.org, пробую archive.debian.org"; \
         sed -i 's|deb.debian.org/debian-security|archive.debian.org/debian-security|' /etc/apt/sources.list && try; } \
    || { echo ">>> bullseye-security недоступен нигде, ставлю пакеты из основного bullseye"; \
         sed -i '/debian-security/d' /etc/apt/sources.list && try; }; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*

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
