# CS2-Basefiles-Egg

Запуск CS2-серверов в Pelican Panel с общими файлами игры на хосте.

## Три части, три среды исполнения

| Каталог | Где выполняется | Чем запускается |
|---|---|---|
| `service/` | Linux-хост, вне Docker | systemd (`install.sh` создаёт unit) |
| `docker/` | внутри контейнера сервера | Wings, через `entrypoint.sh` |
| `egg/` | нигде, это данные | импортируется в панель |

Один SteamCMD на хосте обновляет `$BASE_DIR/server`. Контейнеры монтируют его
в `/mnt` **только на чтение** и работают через симлинки в `/home/container`.

## Инварианты

**`log_message` пишет в stderr, в stdout идут только возвращаемые значения.**
Функции вроде `stop_running_servers_for_update` и `get_running_servers_by_image`
отдают список серверов через stdout. Если лог уйдёт туда же, вызывающий получит
строки лога вместо идентификаторов и будет дёргать `power_action` на мусоре.
При добавлении функции, которая что-то печатает для `$( )`, — только `printf`/`echo`
с полезной нагрузкой.

**В `/mnt` нельзя писать.** Всё, что контейнер модифицирует, должно быть
исключено из `create_symlinks` (`docker/scripts/update.sh`): сейчас это
`gameinfo.gi`, `game/versions.txt` и `game/csgo/addons/`. Добавляете новый
изменяемый путь — добавьте его туда же, иначе запись уйдёт в read-only mount.

**`egg/pelican.yaml` — источник правды, `egg/pelican.json` генерируется из него.**
Это один и тот же egg в двух форматах экспорта. Правьте YAML и пересобирайте JSON
(рецепт в README). Файлы уже однажды разъезжались по полю `sort`.

**Установка и обновление аддонов — разные вещи.** `ADDON_PLATFORM`
(`none|metamod|swiftly`) и `CSS_ENABLED` решают, что установлено; `*_AUTOUPDATE` —
только подтягивать ли новые версии. Отсутствующий аддон ставится независимо от
автообновления.

**Наличие аддона проверяется по файлу-маркеру, не по каталогу** (`addon_marker`).
CounterStrikeSharp кладёт `addons/metamod/counterstrikesharp.vdf`, поэтому каталог
`addons/metamod` существует и без самого MetaMod.

**Сбой сети не должен мешать серверу стартовать.** Аддоны опциональны:
недоступный GitHub или metamodsource — это `warning`/`error` в консоль, а не
падение `entrypoint.sh`.

**Оповещения о рестарте делает плагин, не updater.** `inform_players_and_wait`
шлёт `css_restart_notify <секунды>` каждую секунду от `UPDATE_COUNTDOWN_TIME` до 1;
тексты и отсечки живут в конфиге плагина
[NotifyMessages](https://github.com/Armatura-Create/NotifyMessages). Секунды
пропускать нельзя — плагин сопоставляет `Thresholds` строгим равенством,
пропуск значения теряет сообщение. Цикл использует абсолютное расписание
(`end_time - s + 1`), чтобы задержки API не копились в дрейф.

## Ловушки bash, на которых тут уже обжигались

Все скрипты работают под `set -Eeuo pipefail` с `trap ... ERR`.

- **`((x++))` при `x=0` возвращает статус 1** и под `set -e` убивает скрипт.
  Пишите `x=$((x+1))`. На этом ломались все циклы ретраев.
- **ERR-трап срабатывает и при `set +e`**, а из-за `-E` наследуется в функции.
  Поэтому `handle_error` обязан делать `return`, а не `exit`: с `exit` блоки
  `set +e` не защищали ничего. Трап глушится только внутри `if`-условия,
  `&&`/`||` и `!`.
- **`response="$(curl ...)"` падает вместе с curl.** Транспортная ошибка (DNS,
  таймаут) роняет присваивание. Используйте `pelican_request` или `|| raw=...`.
- **`cmd | head -n1` при `pipefail`** валит конвейер через SIGPIPE.
  В jq берите `... | first // empty`.
- `head -n -1` — GNU-специфично. Хост Linux, так что можно; в alpine нужен
  `coreutils`.

## Проверка

```bash
find docker service -name '*.sh' -exec bash -n {} \;

# логика аддонов (gameinfo.gi + разбор релизов GitHub)
docker run --rm -v "$PWD/docker:/src" alpine:3 \
    sh -c 'apk add -q bash jq && bash /src/scripts/test-addons.sh'
```

Полный прогон egg'а: собрать образ, подложить фальшивый `/mnt`
(`game/bin/`, `game/csgo/steam.inf`, `game/csgo/gameinfo.gi` с якорем
`Game_LowViolence`) и запустить с `STARTUP='echo OK'`, перебирая
`ADDON_PLATFORM` × `CSS_ENABLED` × `*_AUTOUPDATE`. `--network none` проверяет,
что сервер стартует при недоступном интернете.

## Принятый риск

Строка запуска собирается через `eval` переменных окружения — как в штатных
яйцах Pelican. `$(команда)` в `CUSTOM_PARAMS` выполнится в контейнере.
Не «чинить» молча: это сломает подстановку `{{VAR}}`, на которую завязан egg.
