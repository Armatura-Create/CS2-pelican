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
2. Если вышел патч — оповещает игроков через плагин [NotifyMessages](https://github.com/Armatura-Create/NotifyMessages), останавливает running-серверы с нужным образом, обновляет файлы через SteamCMD, запускает серверы обратно.
3. Игровые контейнеры **не качают игру сами** — они монтируют уже обновлённые файлы с хоста.

---

## Быстрый старт

```bash
sudo git clone https://github.com/Armatura-Create/CS2-pelican.git /opt/cs2-updater
cd /opt/cs2-updater/service
sudo ./install.sh
sudo ./test-pelican.sh     # проверить ключи до запуска
sudo systemctl start cs2-updater.service
```

⚠️ Первый запуск качает ~40 ГБ файлов игры — это долго.

**Полная пошаговая инструкция (установка, обновление, откат, удаление):
[INSTALL.md](INSTALL.md).** Этот файл — справочник по переменным и настройке mount.

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

В панели Pelican нужны **два разных** ключа. Это не один и тот же токен.

| Переменная | Где создать | Для чего |
|---|---|---|
| `PELICAN_URL` | URL панели без `/` в конце | Базовый адрес API |
| `PELICAN_APP_TOKEN` | **Admin** → API Credentials → **Application API** | Список серверов, фильтр по образу и ноде |
| `PELICAN_API_TOKEN` | **Account** → API Credentials → **Client API** | stop/start, консольные команды, статус сервера |
| `PELICAN_IMAGE` | Docker-образ из egg | Должен **точно совпадать** с образом серверов |
| `PELICAN_NODE_ID` | ID ноды в панели | Фильтр серверов на конкретной машине |

**Как создать Client API ключ (для `PELICAN_API_TOKEN`):**

1. Войдите в панель под аккаунтом-владельцем серверов (или админом с доступом к ним).
2. Откройте **Account** (профиль) → **API Credentials**.
3. Вкладка **Client API** → **Create New API Key**.
4. Скопируйте ключ в `PELICAN_API_TOKEN` в `.env`.

**Важно:**

- `PELICAN_APP_TOKEN` и `PELICAN_API_TOKEN` — **разные** ключи из разных разделов панели.
- Если подставить Application ключ в `PELICAN_API_TOKEN`, Client API вернёт **HTTP 403**.
- `PELICAN_IMAGE` должен совпадать с образом в egg, например:
  ```
  docker.io/scrender/base-files-cs2:latest
  ```
- Client API ключ должен принадлежать пользователю, у которого есть права **control** и **command** на управляемые серверы.

Проверка ключей:

```bash
./test-pelican.sh
```

### Оповещение игроков — плагин NotifyMessages

Updater не шлёт `say` и не хранит тексты у себя. Он вызывает консольную команду
плагина [NotifyMessages](https://github.com/Armatura-Create/NotifyMessages):

```
css_restart_notify <осталось секунд>
```

Команда отправляется **каждую секунду** от `UPDATE_COUNTDOWN_TIME` до 1 — по одной
на каждый running-сервер с нужным образом. Пропускать секунды нельзя: плагин
сопоставляет отсечки строгим равенством, и пропуск, скажем, `10` потерял бы
сообщение «10 секунд».

Что именно увидит игрок, решает **плагин**, а не updater —
`RestartNotify` в его `Settings.json`:

| Поле | Что делает |
|---|---|
| `Enabled` | включает обработку `css_restart_notify` |
| `Thresholds` | точные отсечки: `"60"` → шаблон сообщения |
| `DefaultMessage` | шаблон для всех остальных секунд; **пустая строка = молчать** |
| `MessageType` | канал: `Chat`, `Center`, `CenterHtml`, `Console`, `Alert` |

То есть чтобы игроки видели оповещения только на 300/60/30/10/5/1 — задайте эти
ключи в `Thresholds` и оставьте `DefaultMessage` пустым. Тексты и переводы берутся
из `Messages.json` плагина, каждый игрок видит их на своём языке.

Если плагин не установлен, команда просто игнорируется сервером — updater
отработает отсчёт и перезапустит серверы как обычно.

> Объём запросов: одна команда на сервер в секунду. При `UPDATE_COUNTDOWN_TIME=300`
> и пяти серверах это 1500 запросов к панели за цикл обновления. Уменьшайте
> `UPDATE_COUNTDOWN_TIME`, если панель к этому чувствительна.

---

### Тайминги и логи

| Переменная | Описание | По умолчанию |
|---|---|---|
| `VERSION_CHECK_INTERVAL` | Интервал проверки версии (сек) | `300` |
| `UPDATE_COUNTDOWN_TIME` | Отсчёт перед рестартом (сек) — он же длительность оповещения | `300` |
| `LOG_LEVEL` | `DEBUG` / `INFO` / `WARNING` / `ERROR` | `INFO` |
| `LOG_FILE_ENABLED` | Писать лог в `logs/Base_file_log.txt-ГГГГ-ММ-ДД` (хранится 7 дней) | `1` |

> `.env` содержит пароль Steam и оба токена панели. `install.sh` создаёт его с
> правами `600`. Если файл делался вручную — выставьте их сами:
> ```bash
> chmod 600 .env
> ```

---

## Точка монтирования в Pelican

Для каждого CS2-сервера с этим egg нужен **mount**, чтобы контейнер видел общие файлы игры.

Настройка состоит из **трёх шагов** — без любого из них контейнер не увидит `/mnt/game/bin`.

### Шаг 1. Wings — разрешить путь (`allowed_mounts`)

По умолчанию Wings **не монтирует** произвольные папки с хоста. Путь нужно явно разрешить в конфиге демона на ноде.

На сервере-ноде (где крутится Wings):

```bash
sudo nano /etc/pelican/config.yml
```

Найдите или добавьте секцию `allowed_mounts`. Укажите **родительскую** папку вашего `BASE_DIR` — все подпапки тоже станут доступны:

```yaml
allowed_mounts:
  - /home/cs2
```

Примеры для других путей:

```yaml
allowed_mounts:
  - /home/cs2_base
```

или несколько путей:

```yaml
allowed_mounts:
  - /home/cs2
  - /var/lib/pelican/mounts
```

Сохраните файл и перезапустите Wings:

```bash
sudo systemctl restart wings
sudo systemctl status wings
```

> Документация Pelican: [Using Mounts](https://pelican.dev/docs/guides/mounts/)

### Шаг 2. Панель — создать mount

**Admin** → **Mounts** → **Create Mount**

| Поле | Значение |
|---|---|
| **Name** | `Base Files CS2` (любое) |
| **Source** (хост) | `$BASE_DIR/server` |
| **Target** (контейнер) | `/mnt` |
| **Read Only** | `Только чтение` — рекомендуется |
| **User Mountable** | по желанию |

Пример при `BASE_DIR=/home/cs2`:

```
Source:  /home/cs2/server
Target:  /mnt
```

После создания привяжите mount к:

- **Egg**: `CS2 with base files` (ваш egg)
- **Node**: нода, на которой запущен сервер (например `ovhservers`)

### Шаг 3. Панель — добавить mount на сервер

Создания mount и привязки к egg/node **недостаточно** — mount нужно добавить на **конкретный сервер**:

1. **Admin** → откройте сервер (например `Test`)
2. Вкладка **Mounts**
3. Кнопка **+** → выберите `Base Files CS2`
4. **Перезапустите** сервер

### Проверка

На хосте — файлы игры должны существовать **до** запуска контейнера:

```bash
grep BASE_DIR /home/cs2/.env
ls "$BASE_DIR/server/game/bin"
ls "$BASE_DIR/server/game/csgo/steam.inf"
```

В контейнере — временно смените **Startup Command** на:

```bash
ls -la /mnt && ls -la /mnt/game/bin
```

Ожидаемый вывод: папки `game`, `steamapps` и т.д. внутри `/mnt`.

Если `/mnt` пустой — проверьте шаги 1–3 (чаще всего не добавлен `allowed_mounts` или mount не привязан к серверу).

> Mount **не виден** в файловом менеджере панели и через SFTP — только внутри запущенного контейнера.

### Что видит контейнер

Внутри контейнера egg использует `/mnt` как общую копию файлов:

```
/mnt/game/csgo/     ← файлы игры с хоста
/mnt/game/bin/      ← бинарники
/home/container/    ← рабочая директория сервера (симлинки на /mnt)
```

`gameinfo.gi` и пользовательские конфиги остаются локальными в контейнере — это учтено в `docker/entrypoint.sh`.

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

Самая частая причина: в `PELICAN_API_TOKEN` указан **Application API** ключ вместо **Client API**.

- `PELICAN_APP_TOKEN` → Admin → API Credentials → Application API
- `PELICAN_API_TOKEN` → Account → API Credentials → Client API

После создания Client ключа обновите `.env` и снова запустите `./test-pelican.sh`.

### Client API — HTTP 403 (другие причины)

- Client API ключ не имеет доступа к серверу.
- Создайте ключ от аккаунта-владельца сервера или выдайте права.

### Сервер не видит файлы игры / `change_dir "/mnt/game/bin" failed`

Проверьте по порядку:

1. **Wings `allowed_mounts`** — в `/etc/pelican/config.yml` должен быть путь к `BASE_DIR`, затем `systemctl restart wings`
2. **Mount в панели** — source = `$BASE_DIR/server`, target = `/mnt`
3. **Mount на сервере** — Admin → сервер → Mounts → **+** → перезапуск
4. **Файлы на хосте** — updater скачал игру: `ls $BASE_DIR/server/game/bin`

Типичная ошибка: mount создан в панели, но **не добавлен `allowed_mounts`** в Wings — контейнер видит пустой `/mnt`.

### Application API — HTTP 404 при обновлении

Updater не может получить список серверов. Проверьте на хосте:

```bash
grep PELICAN /path/to/service/.env
./test-pelican.sh
```

Частые причины:

- неверный `PELICAN_URL` (опечатка, лишний путь, `/` в конце)
- истёк или отозван `PELICAN_APP_TOKEN`
- панель недоступна с этого хоста (`ns3170054` ≠ другой сервер с рабочим `.env`)

Пример правильного `.env`:

```env
PELICAN_URL="https://gameserv.vortanode.com"
PELICAN_APP_TOKEN="ключ из Admin → Application API"
PELICAN_API_TOKEN="ключ из Account → Client API"
PELICAN_IMAGE="docker.io/scrender/base-files-cs2:latest"
PELICAN_NODE_ID="2"
```

Updater **не падает** при ошибке Pelican API — продолжит SteamCMD-обновление,
но не сможет stop/start серверы и слать оповещения.

Аналогично при сбое SteamCMD: остановленные перед обновлением серверы
**в любом случае запускаются обратно** на старой версии игры.

### systemd: `Is a directory`

Исправлено в текущей версии `install.sh`. Переустановите:

```bash
./install.sh
```
