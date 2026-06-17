# CS2 Base Files Updater

Сервис для хоста Pelican Panel, который **централизованно обновляет файлы CS2** через SteamCMD и **управляет игровыми серверами** при выходе патча.

## Как это работает

```
┌─────────────────────────────────────────────────────────────┐
│  Хост (Linux)                                               │
│                                                             │
│  service/ (этот каталог)                                    │
│  ├── install.sh      → установка, создание .env, systemd    │
│  ├── start.sh        → основной цикл updater'а              │
│  ├── test-pelican.sh → проверка API-ключей Pelican          │
│  └── .env            → все настройки                        │
│                                                             │
│  BASE_DIR/server/    → файлы CS2 (SteamCMD)                 │
│       ↑                                                     │
│       │ mount (read-only)                                   │
│       │                                                     │
│  ┌────┴────────────────────────────────────┐                │
│  │  Pelican: CS2-контейнеры (egg)          │                │
│  │  /mnt → общие game files                │                │
│  └─────────────────────────────────────────┘                │
└─────────────────────────────────────────────────────────────┘
```

1. `start.sh` каждые `VERSION_CHECK_INTERVAL` секунд проверяет версию CS2 через Steam API.
2. Если вышел патч — оповещает игроков (`say`), останавливает running-серверы с нужным образом, обновляет файлы через SteamCMD, запускает серверы обратно.
3. Игровые контейнеры **не качают игру сами** — они монтируют уже обновлённые файлы с хоста.

---

## Быстрый старт

```bash
cd /path/to/CS2-Basefiles-Egg/service
chmod +x install.sh start.sh test-pelican.sh
./install.sh
./test-pelican.sh          # проверить ключи до запуска
sudo systemctl start cs2-updater.service
```

---

## Переменные `.env`

Файл создаётся автоматически при `./install.sh`. Пример: `.env.example`.

### Пути и SteamCMD

| Переменная | Описание | Пример |
|---|---|---|
| `BASE_DIR` | Корневая папка на **хосте**, куда SteamCMD ставит игру | `/home/cs2_base` |
| `SRCDS_APPID` | AppID CS2 | `730` |
| `STEAM_USER` | Логин SteamCMD | `anonymous` |
| `STEAM_PASS` | Пароль (если нужен) | пусто |
| `STEAM_AUTH` | Steam Guard код (если нужен) | пусто |
| `EXTRA_FLAGS` | Доп. флаги SteamCMD | `validate` |

После установки файлы лежат в:

```
$BASE_DIR/server/
├── steamcmd/
├── game/csgo/          ← игровые файлы
└── steamapps/
```

### Pelican API — ключи

В панели Pelican: **Admin → API Credentials**.

| Переменная | Где взять | Для чего |
|---|---|---|
| `PELICAN_URL` | URL панели без `/` в конце | Базовый адрес API |
| `PELICAN_APP_TOKEN` | **Application API** ключ | Список серверов, фильтр по образу и ноде |
| `PELICAN_API_TOKEN` | **Client API** ключ (аккаунт) | stop/start, команды `say`, статус сервера |
| `PELICAN_IMAGE` | Docker-образ из egg | Должен **точно совпадать** с образом серверов |
| `PELICAN_NODE_ID` | ID ноды в панели | Фильтр серверов на конкретной машине |

**Важно:**

- `PELICAN_APP_TOKEN` и `PELICAN_API_TOKEN` — **разные** ключи.
- `PELICAN_IMAGE` должен совпадать с образом в egg, например:
  ```
  docker.io/scrender/base-files-cs2:latest
  ```
- Client API ключ должен иметь права **control** и **command** на управляемые серверы.

Проверка ключей:

```bash
./test-pelican.sh
```

### Тайминги и логи

| Переменная | Описание | По умолчанию |
|---|---|---|
| `VERSION_CHECK_INTERVAL` | Интервал проверки версии (сек) | `300` |
| `UPDATE_COUNTDOWN_TIME` | Отсчёт перед рестартом (сек) | `300` |
| `LOG_LEVEL` | `DEBUG` / `INFO` / `WARNING` / `ERROR` | `INFO` |
| `LOG_FILE_ENABLED` | Писать лог в `logs/` | `1` |

---

## Точка монтирования в Pelican

Для каждого CS2-сервера с этим egg нужен **mount**, чтобы контейнер видел общие файлы игры.

### Пути

| Поле в панели | Значение |
|---|---|
| **Source** (хост) | `$BASE_DIR/server` |
| **Target** (контейнер) | `/mnt` |
| **Read Only** | рекомендуется `true` |

Пример при `BASE_DIR=/home/cs2_base`:

```
Source:  /home/cs2_base/server
Target:  /mnt
```

### Что видит контейнер

Внутри контейнера egg монтирует `/mnt` как общую копию файлов:

```
/mnt/game/csgo/     ← файлы игры с хоста
/home/container/    ← рабочая директория сервера (симлинки на /mnt)
```

`gameinfo.gi` и пользовательские конфиги остаются локальными в контейнере — это учтено в `docker/entrypoint.sh`.

### Создание mount в панели

1. Откройте сервер → вкладка **Mounts** (или **Settings → Mounts**).
2. **Add Mount**:
   - Source: `/home/cs2_base/server` (ваш `BASE_DIR` + `/server`)
   - Target: `/mnt`
   - Read Only: включить
3. Перезапустите сервер.

Убедитесь, что путь на хосте существует и updater уже скачал игру:

```bash
ls /home/cs2_base/server/game/csgo/steam.inf
```

---

## systemd

`install.sh` создаёт unit-файл в `/etc/systemd/system/`.

Имя сервиса можно вводить как `cs2-updater` — `.service` добавится автоматически.

```bash
sudo systemctl daemon-reload
sudo systemctl enable cs2-updater.service
sudo systemctl start cs2-updater.service
sudo systemctl status cs2-updater.service
journalctl -u cs2-updater.service -f
```

---

## Структура репозитория

| Каталог | Назначение |
|---|---|
| `service/` | Updater на хосте (этот README) |
| `docker/` | Docker-образ для egg CS2 |
| `egg/` | Конфигурация Pelican egg (`pelican.yaml`) |

---

## Устранение проблем

### `test-pelican.sh` — Application API OK, серверы не найдены

- Проверьте `PELICAN_IMAGE` — должен совпадать с образом в настройках сервера.
- Проверьте `PELICAN_NODE_ID` — ID ноды, на которой запущен сервер.

### Client API — HTTP 403

- Client API ключ не имеет доступа к серверу.
- Создайте ключ от аккаунта-владельца сервера или выдайте права.

### Сервер не видит файлы игры

- Mount: source = `$BASE_DIR/server`, target = `/mnt`.
- Updater должен хотя бы раз успешно выполнить SteamCMD.

### systemd: `Is a directory`

Исправлено в текущей версии `install.sh`. Переустановите:

```bash
./install.sh
```
