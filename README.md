# CS2 Basefiles for Pelican Panel

Репозиторий для запуска CS2-серверов в [Pelican Panel](https://pelican.dev/) с **общими base files** на хосте.

## Состав

- **`service/`** — updater на Linux-хосте: SteamCMD, автообновление, управление серверами через Pelican API. Публикуется релизами.  
  → Установка и обновление: [service/INSTALL.md](service/INSTALL.md)  
  → Справочник по переменным и mount: [service/README.md](service/README.md)
- **`install.sh` / `update.sh`** — bootstrap-скрипты для `curl | bash`.
- **`docker/`** — Docker-образ CS2-сервера (SteamRT3).
- **`egg/`** — Pelican egg: `pelican.yaml` (основной) и `pelican.json` (тот же egg в старом формате экспорта).

## Схема

Один экземпляр SteamCMD на хосте обновляет `$BASE_DIR/server`. Все CS2-контейнеры монтируют эту папку в `/mnt` и используют общие файлы игры.

## Быстрый старт

Установка updater'а на хост — одной командой:

```bash
curl -fsSL https://raw.githubusercontent.com/Armatura-Create/CS2-pelican/master/install.sh | sudo bash
```

Обновление — тоже:

```bash
curl -fsSL https://raw.githubusercontent.com/Armatura-Create/CS2-pelican/master/update.sh | sudo bash
```

Скрипты качают архив релиза (только `service/`, без `docker/` и `egg/`), сверяют
контрольную сумму и всё настраивают. `update.sh` умеет откатываться сам, если
сервис после обновления не поднялся.

Дальше — настроить mount в Wings и панели и импортировать `egg/pelican.yaml`.
Пошагово: **[service/INSTALL.md](service/INSTALL.md)**.

---

## Аддоны: платформа и обновления

Установка и автообновление — **разные настройки**. Что ставить, задаёт платформа;
`Auto Update` решает только, подтягивать ли новые версии дальше.

### Выбор платформы — `Addons - Platform` (`ADDON_PLATFORM`)

Варианты взаимоисключающие:

| Значение | Что ставится | Комментарий |
|---|---|---|
| `none` | ничего | чистый сервер |
| `metamod` | MetaMod:Source | плюс CounterStrikeSharp, если включён `CSS_ENABLED` |
| `swiftly` | SwiftlyS2 | самостоятельный фреймворк, MetaMod ему не нужен |

`Addons - CounterStrikeSharp` (`CSS_ENABLED`) работает **только** при
`ADDON_PLATFORM=metamod`: CSS является плагином MetaMod и без него не запускается.
При `swiftly` и `none` эта опция игнорируется.

### Отдельные переключатели обновления

| Переменная | Что делает |
|---|---|
| `METAMOD_AUTOUPDATE` | обновлять MetaMod при каждом запуске |
| `CSS_AUTOUPDATE` | обновлять CounterStrikeSharp при каждом запуске |
| `SWIFTLY_AUTOUPDATE` | обновлять Swiftly при каждом запуске |

Логика для каждого аддона одинаковая:

| Состояние | `AUTOUPDATE=0` | `AUTOUPDATE=1` |
|---|---|---|
| выбран, не установлен | **ставится** последняя версия | **ставится** последняя версия |
| выбран, установлен | версия фиксируется, ничего не качается | сверяется с релизом, обновляется при расхождении |
| не выбран | файлы остаются, запись убирается из `gameinfo.gi` | то же самое |

То есть выключенное автообновление больше не мешает установке — это была отдельная
проблема прошлой схемы.

### Переключение платформы

Файлы аддона **не удаляются**. Убирается только запись `Game csgo/addons/...` из
`gameinfo.gi`, поэтому плагины и конфиги остаются на месте, а обратное переключение
срабатывает сразу. Чтобы освободить место — удалите папку в
`game/csgo/addons/` через файловый менеджер панели.

### Что происходит при недоступном GitHub

Аддоны опциональны, поэтому сбой сети **не мешает серверу стартовать**:

- аддон уже установлен → сервер запускается на текущей версии, в консоли `warning`;
- аддон не установлен → сервер запускается без него, в консоли `error`.

GitHub API даёт 60 запросов в час **на IP ноды** — лимит общий для всех контейнеров.
Если серверов много и в логах появляется `HTTP 403`, задайте переменную окружения
`GITHUB_TOKEN` (обычный read-only PAT), лимит поднимется до 5000 запросов в час.

---

## Оповещение игроков о рестарте

Updater не рассылает `say` — он вызывает команду плагина
[NotifyMessages](https://github.com/Armatura-Create/NotifyMessages):

```
css_restart_notify <осталось секунд>
```

Команда уходит каждую секунду от `UPDATE_COUNTDOWN_TIME` до 1. Тексты, отсечки,
цвета и переводы живут в конфиге плагина (`RestartNotify` в `Settings.json`),
а не в updater'е. Подробности — в [service/README.md](service/README.md).

---

## Известные риски

### Переменные сервера проходят через `eval`

Строка запуска собирается так же, как в штатных яйцах Pelican: значения переменных
подставляются через `eval`. Значение вида `$(команда)` в `CUSTOM_PARAMS`
(и в любой другой переменной, попадающей в строку запуска) **будет выполнено внутри
контейнера** от пользователя `container`.

Редактировать эти переменные может только владелец сервера, у которого и так есть
консоль сервера, — поэтому новых прав это не даёт. Но если вы выдаёте подсерверам
права на редактирование переменных, помните: это равносильно доступу к shell
контейнера.

### RCON

`Using Rcon` (`RCON_ENABLED`) добавляет `-usercon` и биндит сервер на `0.0.0.0`.
При пустом `RCON_PASSWORD` egg **не включит RCON** и напишет ошибку в консоль:
RCON без пароля — это полный контроль над сервером для любого, кто дотянется до порта.

---

## Релизы и CI

`service/` публикуется GitHub-релизами. Версия берётся из имени тега:

```bash
git tag v1.0.0 && git push origin v1.0.0
```

Дальше [`.github/workflows/release.yml`](.github/workflows/release.yml) сам
проверит скрипты, соберёт `cs2-updater.tar.gz` (содержимое `service/` плюс файл
`VERSION`), посчитает `sha256`, убедится, что архив разворачивается и не содержит
`.env`, и опубликует релиз. `install.sh` и `update.sh` на дедиках берут именно эти
файлы, поэтому сломанный архив до серверов не доедет.

[`.github/workflows/ci.yml`](.github/workflows/ci.yml) на каждый push и PR гоняет
`bash -n`, `shellcheck -S error`, самопроверку логики аддонов, сверку
`pelican.yaml` с `pelican.json` и проверку, что `-usercon` добавляется только при
`RCON_ENABLED=1`. Плюс сборку docker-образа.

---

## Проверка изменений

```bash
# синтаксис всех скриптов
find docker service -name '*.sh' -exec bash -n {} \;

# самопроверка логики аддонов (gameinfo.gi + разбор релизов)
docker run --rm -v "$PWD/docker:/src" alpine:3 \
    sh -c 'apk add -q bash jq && bash /src/scripts/test-addons.sh'

# egg: оба файла должны совпадать по смыслу
python3 - <<'PY'
import json, yaml
y = yaml.safe_load(open('egg/pelican.yaml'))
j = json.load(open('egg/pelican.json'))
assert [v['env_variable'] for v in y['variables']] == [v['env_variable'] for v in j['variables']]
assert json.loads(j['config']['files']) == y['config']['files']
print('egg OK:', len(y['variables']), 'переменных')
PY
```

`egg/pelican.json` генерируется из `egg/pelican.yaml` — правьте YAML и пересобирайте JSON,
иначе файлы разъедутся (однажды уже разъехались по полю `sort`).
