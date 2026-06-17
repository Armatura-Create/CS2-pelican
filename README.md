# CS2 Basefiles for Pelican Panel

Репозиторий для запуска CS2-серверов в [Pelican Panel](https://pelican.dev/) с **общими base files** на хосте.

## Состав

- **`service/`** — updater на Linux-хосте: SteamCMD, автообновление, управление серверами через Pelican API.  
  → Подробная документация: [service/README.md](service/README.md)
- **`docker/`** — Docker-образ CS2-сервера (SteamRT3).
- **`egg/`** — Pelican egg (`pelican.yaml`).

## Схема

Один экземпляр SteamCMD на хосте обновляет `$BASE_DIR/server`. Все CS2-контейнеры монтируют эту папку в `/mnt` и используют общие файлы игры.

## Быстрый старт

```bash
# 1. Установить updater на хосте
cd service && ./install.sh && ./test-pelican.sh

# 2. Импортировать egg в Pelican (egg/pelican.yaml)

# 3. На каждом CS2-сервере создать mount:
#    source: /home/cs2_base/server
#    target: /mnt
```
