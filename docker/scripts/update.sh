#!/bin/bash
set -Eeuo pipefail

source /utils/logging.sh
trap 'handle_error "$LINENO" "$BASH_COMMAND"' ERR

# ===========================
# Пути по умолчанию
# ===========================
BASE_FILES="/mnt"
CONTAINER_FILES="/home/container"
GAME_DIRECTORY="./game/csgo"
OUTPUT_DIR="./game/csgo/addons"
TEMP_DIR="./temps"
VERSION_FILE="./game/versions.txt"

GAMEINFO_FILE="$CONTAINER_FILES/game/csgo/gameinfo.gi"
GAMEINFO_MNT="$BASE_FILES/game/csgo/gameinfo.gi"

# ===========================
# Реестр аддонов
# ===========================
# Склад аддонов ноды: хост (service/utils/addons-store.sh) готовит каждую нужную
# серверам версию один раз — этим же кодом, через scripts/addon-store.sh — и
# кладёт в $BASE_DIR/server/.cs2-addons, то есть сюда, в /mnt, только на чтение.
# Сервер берёт оттуда и версию (index — без запроса к GitHub: лимит 60 в час
# на IP ноды делят все серверы), и файлы (без скачивания). Склада нет или нужной
# версии на нём нет — качает сам, как раньше.
ADDON_STORE="$BASE_FILES/.cs2-addons"
STORE_FRESH_MIN=120     # индекс старше двух часов: хост его не обновлял — не верим

# .NET для ModSharp: ровно эта версия, ModSharp собран под неё
DOTNET_VERSION="10.0.0"
DOTNET_URL="https://builds.dotnet.microsoft.com/dotnet/Runtime/$DOTNET_VERSION/dotnet-runtime-$DOTNET_VERSION-linux-x64.tar.gz"
SHARP_DIR="./game/sharp"

# Маркер = файл, доказывающий РЕАЛЬНУЮ установку.
# Проверять сам каталог нельзя: CounterStrikeSharp кладёт
# addons/metamod/counterstrikesharp.vdf, из-за чего addons/metamod существует
# даже когда самого MetaMod нет.
addon_marker() {
    case "$1" in
        metamod)  printf '%s' "$OUTPUT_DIR/metamod/bin/linuxsteamrt64/metamod.2.cs2.so" ;;
        css)      printf '%s' "$OUTPUT_DIR/counterstrikesharp/bin/linuxsteamrt64/counterstrikesharp.so" ;;
        swiftly)  printf '%s' "$OUTPUT_DIR/swiftlys2/bin/linuxsteamrt64/swiftlys2.so" ;;
        modsharp) printf '%s' "$SHARP_DIR/bin/libmodsharp.so" ;;
        dotnet)   printf '%s' "$SHARP_DIR/runtime/dotnet" ;;
    esac
}

addon_name() {
    case "$1" in
        metamod)  printf '%s' "Metamod" ;;
        css)      printf '%s' "CSS" ;;
        swiftly)  printf '%s' "Swiftly" ;;
        modsharp) printf '%s' "ModSharp" ;;
        dotnet)   printf '%s' "DotNet" ;;
    esac
}

# Репозиторий GitHub и архив релиза (регулярное выражение по имени файла)
addon_repo() {
    case "$1" in
        css)      printf '%s' "roflmuffin/CounterStrikeSharp" ;;
        swiftly)  printf '%s' "swiftly-solution/swiftlys2" ;;
        modsharp) printf '%s' "Kxnrl/modsharp-public" ;;
    esac
}
addon_asset_re() {
    case "$1" in
        css)      printf '%s' 'counterstrikesharp-with-runtime-linux-.*\.zip' ;;
        swiftly)  printf '%s' 'swiftlys2-linux-v.*-with-runtimes\.zip' ;;
        modsharp) printf '%s' 'ModSharp-git[0-9]+-linux\.zip' ;;
    esac
}

# Включено ли автообновление для конкретного аддона.
# ВАЖНО: значения по умолчанию обязаны совпадать с default_value в egg.
# Сервер на старом egg не передаёт новых переменных вовсе, и расхождение
# означало бы, что аддон молча выключится при первом же рестарте.
addon_autoupdate() {
    case "$1" in
        metamod)  printf '%s' "${METAMOD_AUTOUPDATE:-1}" ;;
        css)      printf '%s' "${CSS_AUTOUPDATE:-1}" ;;
        swiftly)  printf '%s' "${SWIFTLY_AUTOUPDATE:-1}" ;;
        modsharp) printf '%s' "${MODSHARP_AUTOUPDATE:-1}" ;;
        *)        printf '%s' "1" ;;   # .NET — версия задана выше, «новее» не бывает
    esac
}

# Разрешены ли бета-версии (pre-release на GitHub). Дефолт обязан совпадать с egg.
# После обновления CS2 исправления у Swiftly выходят сначала в бете, а
# стабильная версия падает вместе с сервером.
addon_beta() {
    case "$1" in
        swiftly) printf '%s' "${SWIFTLY_BETA:-0}" ;;
        *)       printf '%s' "0" ;;
    esac
}

# store_index latest|beta|pin <аддон> — значение из индекса склада, или пусто
store_index() {
    local idx="$ADDON_STORE/index"
    [ -f "$idx" ] && [ -n "$(find "$idx" -mmin -"$STORE_FRESH_MIN" 2>/dev/null || true)" ] || return 0
    awk -v k="$1" -v a="$2" '$1 == k && $2 == a { print $3; exit }' "$idx" 2>/dev/null || true
}

# store_tree <аддон> <версия> — готовое дерево файлов на складе, или код 1
store_tree() {
    [[ "$2" =~ ^[A-Za-z0-9._+-]+$ ]] || return 1
    local d="$ADDON_STORE/$1/$2"
    [ -f "$d/.ready" ] && [ -d "$d/tree" ] || return 1
    printf '%s' "$d/tree"
}

# Зафиксированная версия или пусто — выбирать самим. Сначала своя у сервера
# (переменная egg), потом общая для ноды (PIN_* у хоста, приходит индексом
# склада). Значение уходит в URL запроса, поэтому пропускаем только теги.
addon_pin() {
    local pin="" re
    case "$1" in
        metamod)  pin="${METAMOD_VERSION:-}";  re='^([0-9]+\.[0-9]+\.[0-9]+-)?git[0-9]+$' ;;
        css)      pin="${CSS_VERSION:-}";      re='^v?[0-9][0-9A-Za-z.-]*$' ;;
        swiftly)  pin="${SWIFTLY_VERSION:-}";  re='^v?[0-9][0-9A-Za-z.-]*$' ;;
        modsharp) pin="${MODSHARP_VERSION:-}"; re='^git-?[0-9]+$' ;;
        *)        return 0 ;;
    esac
    [ -n "$pin" ] || pin="$(store_index pin "$1")"
    [ -n "$pin" ] || return 0
    if [[ "$pin" =~ $re ]]; then
        # ModSharp тегирует git-197, а пишут и git197
        [ "$1" != modsharp ] || pin="git-${pin#git}"; pin="${pin/git--/git-}"
        printf '%s' "$pin"
    else
        log_message "Некорректная версия '$pin' для $(addon_name "$1") — ожидается тег вида $(
            case "$1" in metamod) echo git1380 ;; modsharp) echo git-197 ;; *) echo v1.4.10 ;; esac). Игнорирую." "error"
    fi
}

# 0, если версия $1 новее $2. Бета «v1.4.11-beta.10» новее «v1.4.10», но
# старше «v1.4.11». Строковое сравнение тут не годится: «beta.10» < «beta.2»,
# а GitHub отдаёт релизы не по порядку версий. `-` → `~`: в sort -V тильда
# сортируется раньше конца строки, ровно как пре-релиз в semver.
version_gt() {
    [ "$1" != "$2" ] || return 1
    local a="${1#v}" b="${2#v}"
    a="${a/-/\~}"; b="${b/-/\~}"
    [ "$(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -n1)" = "$a" ]
}

# Выбранная платформа аддонов: none | metamod | swiftly
addon_platform() {
    local p="${ADDON_PLATFORM:-metamod}"
    case "$p" in
        none|metamod|swiftly) printf '%s' "$p" ;;
        *)
            log_message "Некорректный ADDON_PLATFORM='$p'. Допустимо: none, metamod, swiftly. Использую 'none'." "error"
            printf '%s' "none"
            ;;
    esac
}

# ===========================
# Проверка mount
# ===========================
validate_mount() {
    local missing=0

    if [ ! -d "$BASE_FILES" ] || [ -z "$(ls -A "$BASE_FILES" 2>/dev/null || true)" ]; then
        log_message "Mount $BASE_FILES пуст или не смонтирован." "error"
        log_message "В Pelican укажите: source = \$BASE_DIR/server на хосте, target = /mnt" "error"
        missing=1
    fi

    for required_path in "game/bin" "game/csgo"; do
        if [ ! -d "$BASE_FILES/$required_path" ]; then
            log_message "Не найдено: $BASE_FILES/$required_path" "error"
            missing=1
        fi
    done

    if [ ! -f "$BASE_FILES/game/csgo/steam.inf" ]; then
        log_message "Не найден $BASE_FILES/game/csgo/steam.inf — CS2 ещё не установлена на хосте." "error"
        log_message "На хосте запустите updater: sudo systemctl start <ваш-сервис> или ./start.sh" "error"
        missing=1
    fi

    if [ "$missing" -ne 0 ]; then
        log_message "Проверьте на хосте: ls -la \$BASE_DIR/server/game/" "error"
        log_message "Пример mount: source /home/cs2/server → target /mnt (если BASE_DIR=/home/cs2)" "error"
        exit 1
    fi

    log_message "Mount $BASE_FILES проверен, файлы игры на месте." "success"
}

# ===========================
# Копирование папки bin
# ===========================
copy_bin() {
    validate_mount

    log_message "Копируем /game/bin из $BASE_FILES в $CONTAINER_FILES (rsync --delete)..." "running"
    mkdir -p "$CONTAINER_FILES/game/bin"

    rsync -a --delete \
        --exclude='linuxsteamrt64/steamapps/' \
        "$BASE_FILES/game/bin/" \
        "$CONTAINER_FILES/game/bin/"

    if [ -d "$BASE_FILES/steamapps" ]; then
        rsync -a --ignore-existing \
            "$BASE_FILES/steamapps/" \
            "$CONTAINER_FILES/steamapps/"
    fi

    log_message "Копирование bin завершено." "success"
}

# ===========================
# Копирование только недостающих cfg
# ===========================
copy_cfg() {
    log_message "Копируем /game/csgo/cfg из $BASE_FILES в $CONTAINER_FILES (только недостающие)..." "running"
    mkdir -p "$CONTAINER_FILES/game/csgo/cfg"

    if [ -d "$BASE_FILES/game/csgo/cfg" ]; then
        rsync -a --ignore-existing \
            "$BASE_FILES/game/csgo/cfg/" \
            "$CONTAINER_FILES/game/csgo/cfg/"
    fi

    log_message "Копирование cfg завершено." "success"
}

# ===========================
# Создание символьных ссылок (прочие файлы)
# ===========================
create_symlinks() {
    log_message "Создаём символьные ссылки из $BASE_FILES в $CONTAINER_FILES..." "running"

    find "$BASE_FILES" -type f -print0 | while IFS= read -r -d '' file; do
        case "$file" in
            # Копируются отдельно
            "$BASE_FILES/game/bin/"*|"$BASE_FILES/game/csgo/cfg/"*|"$BASE_FILES/steamapps/"*)
                continue ;;
            # Склад аддонов ноды: из него ставят, а не запускают — ссылки не нужны
            "$BASE_FILES/.cs2-addons/"*)
                continue ;;
            # КРИТИЧЕСКИ ВАЖНО: контейнер ПИШЕТ в эти пути. Симлинк увёл бы запись
            # в /mnt, который смонтирован только на чтение.
            "$BASE_FILES/game/csgo/gameinfo.gi"|"$BASE_FILES/game/versions.txt"|"$BASE_FILES/game/csgo/addons/"*)
                continue ;;
        esac

        local relative_path="${file#"$BASE_FILES"/}"
        local symlink_path="$CONTAINER_FILES/$relative_path"

        [ -L "$symlink_path" ] && continue

        mkdir -p "$(dirname "$symlink_path")"

        if ln -s "$file" "$symlink_path" 2>/dev/null; then
            log_message "Создана символическая ссылка: $symlink_path -> $file" "debug"
            continue
        fi

        rm -f "$symlink_path" 2>/dev/null || true
        if ln -s "$file" "$symlink_path" 2>/dev/null; then
            log_message "Символьная ссылка создана повторно: $symlink_path -> $file" "debug"
        else
            log_message "Не удалось создать ссылку: $symlink_path -> $file" "error"
        fi
    done
}

# ===========================
# Удаление битых символьных ссылок
# ===========================
remove_stale_symlinks() {
    log_message "Ищем и удаляем битые ссылки в $CONTAINER_FILES..." "running"

    find "$CONTAINER_FILES" -type l -print0 | while IFS= read -r -d '' symlink; do
        if [ ! -e "$symlink" ]; then
            rm -f "$symlink" && \
                log_message "Удалена битая ссылка: $symlink" "debug"
        fi
    done
}

# ===========================
# Работа с versions.txt
# ===========================
get_current_version() {
    local addon="$1"
    [ -f "$VERSION_FILE" ] || { echo ""; return 0; }

    local line
    line="$(grep "^$addon=" "$VERSION_FILE" || true)"
    if [ -n "$line" ]; then
        echo "${line#*=}"
    else
        echo ""
    fi
}

update_version_file() {
    local addon="$1"
    local new_version="$2"

    mkdir -p "$(dirname "$VERSION_FILE")"
    if [ -f "$VERSION_FILE" ] && grep -q "^$addon=" "$VERSION_FILE"; then
        sed -i "s/^$addon=.*/$addon=$new_version/" "$VERSION_FILE"
    else
        echo "$addon=$new_version" >> "$VERSION_FILE"
    fi
}

# ===========================
# Универсальная загрузка и распаковка
# ===========================
handle_download_and_extract() {
    local url="$1"
    local output_file="$2"
    local extract_dir="$3"
    local file_type="$4" # "zip" | "tar.gz"

    log_message "Загрузка файла: $url" "debug"

    local max_retries=3
    local retry=0
    local downloaded=0

    while [ "$retry" -lt "$max_retries" ]; do
        if curl -fsSL -m 300 -o "$output_file" "$url"; then
            downloaded=1
            break
        fi
        # NB: НЕ ((retry++)) — при retry=0 постинкремент возвращает 0,
        # статус 1, и под `set -e` цикл ретраев убивал бы весь запуск.
        retry=$((retry + 1))
        log_message "Не удалось скачать файл (попытка $retry из $max_retries). Повтор через 5 сек..." "warning"
        sleep 5
    done

    if [ "$downloaded" -ne 1 ]; then
        log_message "Скачивание не удалось после $max_retries попыток: $url" "error"
        return 1
    fi

    if [ ! -s "$output_file" ]; then
        log_message "Скачанный файл пуст: $url" "error"
        return 1
    fi

    log_message "Распаковка в $extract_dir..." "debug"
    mkdir -p "$extract_dir"

    case "$file_type" in
        zip)
            unzip -qq -o "$output_file" -d "$extract_dir" || {
                log_message "Ошибка распаковки zip-файла: $url" "error"
                return 1
            }
            ;;
        tar.gz)
            tar -xzf "$output_file" -C "$extract_dir" || {
                log_message "Ошибка распаковки tar.gz: $url" "error"
                return 1
            }
            ;;
    esac
    return 0
}

# ===========================
# GitHub API
# ===========================
# github_api <owner/repo> <путь: releases/latest | releases?per_page=30 | releases/tags/TAG> <файл>
github_api() {
    local repo="$1"
    local path="$2"
    local out_json="$3"

    # Токен — через stdin (`-H @-`), не аргументом: иначе он виден в `ps`.
    local -a headers=(-H "Accept: application/vnd.github+json")
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        headers+=(-H @-)
    fi

    # `|| true`, а не `|| echo 000`: при сетевой ошибке curl сам печатает 000
    # через -w, и echo давал «000000» — ветка 000 ниже не срабатывала никогда.
    local code
    code="$(printf 'Authorization: Bearer %s\n' "${GITHUB_TOKEN:-}" \
        | curl -sS -m 30 -o "$out_json" -w '%{http_code}' \
            "${headers[@]}" \
            "https://api.github.com/repos/$repo/$path" 2>/dev/null || true)"
    code="${code:-000}"

    case "$code" in
        200) return 0 ;;
        403|429)
            log_message "GitHub API отклонил запрос (HTTP $code) для $repo." "error"
            log_message "Скорее всего исчерпан лимит 60 запросов/час на IP ноды — его делят все контейнеры." "warning"
            log_message "Поднять лимит: задайте переменную окружения GITHUB_TOKEN." "warning"
            return 1
            ;;
        000)
            log_message "GitHub API недоступен (сеть или таймаут) для $repo." "error"
            return 1
            ;;
        404)
            log_message "GitHub: не найдено $repo/$path — проверьте, что такая версия есть." "error"
            return 1
            ;;
        *)
            log_message "GitHub API вернул HTTP $code для $repo." "error"
            return 1
            ;;
    esac
}

# Печатает тег лучшего релиза из ответа GitHub (объект или список).
# Черновики и релизы без нужного архива отбрасываются. Бета проходит, если
# beta=1 или версия зафиксирована явно (тогда ставим ровно то, что сказали).
# pick_release <json> <regex архива> <beta 0|1> <pin>
pick_release() {
    local tags best="" t
    tags="$(jq -r --arg re "$2" --arg beta "$3" --arg pin "$4" '
        (if type == "array" then . else [.] end)[]
        | select(.draft | not)
        | select($pin != "" or $beta == "1" or (.prerelease | not))
        | select([.assets[]?.browser_download_url | test($re)] | any)
        | .tag_name // empty' "$1" 2>/dev/null || true)"

    while IFS= read -r t; do
        [ -n "$t" ] || continue
        if [ -z "$best" ] || version_gt "$t" "$best"; then best="$t"; fi
    done <<< "$tags"
    printf '%s' "$best"
}

# release_asset_url <json> <regex архива> <тег>
release_asset_url() {
    jq -r --arg re "$2" --arg t "$3" '
        [(if type == "array" then . else [.] end)[] | select(.tag_name == $t)
         | .assets[]?.browser_download_url | select(test($re))] | first // empty' "$1"
}

# ===========================
# Установка / обновление аддонов
# ===========================

# --- какую версию ставить -----------------------------------------------------

# Последняя версия по GitHub. Ответ API остаётся в $TEMP_DIR/<аддон>-release.json:
# по нему prepare_tree найдёт архив без второго запроса.
github_latest() {
    local type="$1" beta="$2" path json="$TEMP_DIR/$1-release.json"
    if [ "$beta" = "1" ]; then path="releases?per_page=30"; else path="releases/latest"; fi
    github_api "$(addon_repo "$type")" "$path" "$json" || return 1
    pick_release "$json" "$(addon_asset_re "$type")" "$beta" ""
}

# Последний билд Metamod со страницы загрузок: печатает gitNNNN,
# имя архива оставляет в $TEMP_DIR/metamod-file
metamod_latest() {
    local branch="${METAMOD_BRANCH:-master}" page file
    [[ "$branch" =~ ^[a-z0-9.-]+$ ]] || { log_message "Некорректный METAMOD_BRANCH='$branch'." "error"; return 1; }
    page="$(curl -fsSL -m 30 "https://www.metamodsource.net/downloads.php?branch=${branch}" 2>/dev/null || true)"
    if [ -z "$page" ]; then
        log_message "Страница загрузок Metamod недоступна (ветка $branch)." "error"
        return 1
    fi
    # linux-архив с максимальным номером билда gitNNNN
    file="$(
        printf '%s' "$page" \
        | grep -oE 'mmsource-[^"]*-linux\.tar\.gz' \
        | tr -d '\r' \
        | awk '{fn=$0; if (match($0,/git[0-9]+/)) {g=substr($0,RSTART+3,RLENGTH-3); print g" "fn}}' \
        | sort -nr | head -n1 | awk '{ $1=""; sub(/^ /,""); print }' \
        || true
    )"
    if [[ ! "$file" =~ (git[0-9]+) ]]; then
        log_message "Не удалось найти linux-архив Metamod на странице загрузок." "error"
        return 1
    fi
    mkdir -p "$TEMP_DIR"
    printf '%s' "$file" > "$TEMP_DIR/metamod-file"
    printf '%s' "${BASH_REMATCH[1]}"
}

# Какую версию ставить: закреплённую, из индекса склада или по GitHub. Печатает версию.
addon_target() {
    local type="$1" pin beta v
    pin="$(addon_pin "$type")"
    if [ -n "$pin" ]; then
        # у Metamod версия — номер билда: 2.0.0-git1380 → git1380
        if [ "$type" = metamod ]; then printf 'git%s' "${pin##*git}"; else printf '%s' "$pin"; fi
        return 0
    fi
    if [ "$type" = dotnet ]; then printf '%s' "$DOTNET_VERSION"; return 0; fi
    beta="$(addon_beta "$type")"
    # склад готовит Metamod только с основной ветки
    if [ "$type" != metamod ] || [ "${METAMOD_BRANCH:-master}" = master ]; then
        v="$(store_index "$([ "$beta" = 1 ] && echo beta || echo latest)" "$type")"
        if [ -n "$v" ]; then
            log_message "$(addon_name "$type"): версия из склада ноды — $v" "debug"
            printf '%s' "$v"
            return 0
        fi
    fi
    if [ "$type" = metamod ]; then
        metamod_latest
    else
        log_message "Проверка обновлений для $(addon_name "$type") ($([ "$beta" = 1 ] && echo "включая бета-версии" || echo "только стабильные"))..." "running"
        github_latest "$type" "$beta"
    fi
}

# --- откуда взять файлы --------------------------------------------------------

# URL архива релиза с тегом $2. Ответ про «последний» уже лежит в $TEMP_DIR;
# для закреплённой версии — запрос releases/tags/<тег>.
release_url() {
    local type="$1" tag="$2" re="${3:-$(addon_asset_re "$1")}" json="$TEMP_DIR/$1-release.json" url=""
    [ -f "$json" ] && url="$(release_asset_url "$json" "$re" "$tag" 2>/dev/null || true)"
    if [ -z "$url" ]; then
        json="$TEMP_DIR/$type-tag.json"
        github_api "$(addon_repo "$type")" "releases/tags/$tag" "$json" || return 1
        url="$(release_asset_url "$json" "$re" "$tag" 2>/dev/null || true)"
    fi
    if [ -z "$url" ]; then
        log_message "В релизе $(addon_name "$type") $tag нет архива под шаблон: $re" "error"
        return 1
    fi
    printf '%s' "$url"
}

# Скачивает и раскладывает версию $2 аддона в каталог $3 — ровно в том виде,
# в каком она ложится на сервер. Этим же кодом склад ноды готовит свои версии
# (scripts/addon-store.sh), поэтому раскладка у них не расходится.
#   metamod, css, swiftly — содержимое addons/;  modsharp — sharp/ и shared/
#   (расширения);  dotnet — сам .NET.
prepare_tree() {
    local type="$1" version="$2" dest="$3" work="$TEMP_DIR/prep-$1" url src file pin mmver
    rm -rf "$work"; mkdir -p "$work" "$dest"
    case "$type" in
        metamod)
            pin="$(addon_pin metamod)"
            # точное имя архива — со страницы загрузок (там же, где версию узнали)
            if [ -z "$pin" ] && ! grep -qs -- "-$version-" "$TEMP_DIR/metamod-file"; then
                metamod_latest >/dev/null || true
            fi
            if grep -qs -- "-$version-" "$TEMP_DIR/metamod-file"; then
                file="$(cat "$TEMP_DIR/metamod-file")"
            else
                # закреплённый билд: 2.0.0-git1380 или просто git1380 (тогда 2.0.0)
                mmver="${pin%git*}"; mmver="${mmver%-}"
                file="mmsource-${mmver:-2.0.0}-${version}-linux.tar.gz"
            fi
            mmver="${file#mmsource-}"; mmver="${mmver%%-*}"
            handle_download_and_extract "https://www.sourcemm.net/mmsdrop/${mmver%.*}/${file}" \
                "$work/metamod.tar.gz" "$work/x" "tar.gz" || return 1
            ;;
        css|swiftly)
            url="$(release_url "$type" "$version")" || return 1
            handle_download_and_extract "$url" "$work/download.zip" "$work/x" "zip" || return 1
            ;;
        modsharp)
            url="$(release_url modsharp "$version")" || return 1
            handle_download_and_extract "$url" "$work/core.zip" "$work/x" "zip" || return 1
            [ -d "$work/x/sharp" ] || { log_message "В архиве ModSharp нет каталога sharp/" "error"; return 1; }
            cp -r "$work/x/sharp" "$dest/sharp"
            url="$(release_url modsharp "$version" 'ModSharp-git[0-9]+-linux-extensions\.zip')" || return 1
            handle_download_and_extract "$url" "$work/ext.zip" "$dest/shared" "zip" || return 1
            return 0
            ;;
        dotnet)
            handle_download_and_extract "$DOTNET_URL" "$work/dotnet.tar.gz" "$dest" "tar.gz" || return 1
            return 0
            ;;
        *) log_message "Неизвестный тип аддона: $type" "error"; return 1 ;;
    esac

    src="$(find "$work/x" -maxdepth 2 -type d -name 'addons' | head -n1 || true)"
    if [ -z "$src" ]; then
        log_message "В архиве $(addon_name "$type") нет папки addons/ (проверено до глубины 2)" "error"
        return 1
    fi
    # Swiftly в некоторых релизах кладёт свой metamod — им управляем отдельно
    if [ "$type" = swiftly ] && [ -d "$src/metamod" ]; then
        log_message "Удаляем metamod из архива Swiftly (управляется отдельно)" "debug"
        rm -rf "$src/metamod"
    fi
    cp -r "$src/." "$dest/"
}

# --- разложить на сервере ------------------------------------------------------

# .NET ссылками на склад вместо копии — как VPK из /mnt: ~100 МБ на сервер не
# занимают квоту. Включается переменной egg: проверено не на всех плагинах.
shared_runtime() {
    [ "${ADDONS_SHARED_RUNTIME:-0}" = "1" ] && [[ "$1" == "$ADDON_STORE/"* ]]
}

# Ссылки на файлы $1 вместо копий; каталоги — настоящие
link_tree() {
    local src="$1" dst="$2" rel
    rm -rf "$dst"
    mkdir -p "$dst"
    while IFS= read -r rel; do mkdir -p "$dst/$rel"; done < <(cd "$src" && find . -mindepth 1 -type d)
    while IFS= read -r rel; do ln -s "$src/${rel#./}" "$dst/${rel#./}"; done < <(cd "$src" && find . \( -type f -o -type l \))
}

# Каталог .NET с прошлого раза мог состоять из ссылок на склад — копия поверх
# них ушла бы в /mnt, а он только на чтение. Убираем, если там ссылки.
drop_links() {
    [ -d "$1" ] && [ -n "$(find "$1" -type l -lname "$ADDON_STORE/*" -print -quit 2>/dev/null)" ] && rm -rf "$1"
    return 0
}

apply_tree() {
    local type="$1" src="$2" f keep="$TEMP_DIR/sharp-keep"
    mkdir -p "$OUTPUT_DIR"
    case "$type" in
        metamod|swiftly)
            rsync -a "$src/" "$OUTPUT_DIR/"
            ;;
        css)
            local rt="$OUTPUT_DIR/counterstrikesharp/dotnet"
            if shared_runtime "$src" && [ -d "$src/counterstrikesharp/dotnet" ]; then
                rsync -a --exclude='/counterstrikesharp/dotnet/' "$src/" "$OUTPUT_DIR/"
                link_tree "$src/counterstrikesharp/dotnet" "$rt"
            else
                drop_links "$rt"
                rsync -a "$src/" "$OUTPUT_DIR/"
            fi
            ;;
        modsharp)
            # настройки сервера переживают обновление: в архиве — свои по умолчанию
            rm -rf "$keep"; mkdir -p "$keep"
            for f in core.json admins.jsonc; do
                [ ! -f "$SHARP_DIR/configs/$f" ] || cp "$SHARP_DIR/configs/$f" "$keep/"
            done
            mkdir -p "$SHARP_DIR/shared"
            rsync -a "$src/sharp/" "$SHARP_DIR/"
            [ ! -d "$src/shared" ] || rsync -a "$src/shared/" "$SHARP_DIR/shared/"
            for f in core.json admins.jsonc; do
                [ ! -f "$keep/$f" ] || cp "$keep/$f" "$SHARP_DIR/configs/$f"
            done
            ;;
        dotnet)
            if shared_runtime "$src"; then
                link_tree "$src" "$SHARP_DIR/runtime"
            else
                drop_links "$SHARP_DIR/runtime"
                mkdir -p "$SHARP_DIR/runtime"
                rsync -a "$src/" "$SHARP_DIR/runtime/"
            fi
            ;;
    esac
}

# Устанавливает аддон, если его нет; обновляет, если стоит автообновление.
# Возвращает 0, если после вызова аддон присутствует и пригоден к загрузке.
ensure_addon() {
    local type="$1"
    local name marker installed=0 pin want current tree
    name="$(addon_name "$type")"
    marker="$(addon_marker "$type")"
    pin="$(addon_pin "$type")"

    [ -e "$marker" ] && installed=1

    if [ "$installed" -eq 1 ] && [ "$(addon_autoupdate "$type")" != "1" ] && [ -z "$pin" ]; then
        log_message "$name установлен, автообновление выключено — оставляем текущую версию ($(get_current_version "$name"))." "info"
        return 0
    fi

    want="$(addon_target "$type" || true)"
    if [[ ! "$want" =~ ^[A-Za-z0-9._+-]+$ ]]; then
        if [ "$installed" -eq 1 ]; then
            log_message "$name: новую версию узнать не удалось, продолжаем на установленной ($(get_current_version "$name"))." "warning"
            return 0
        fi
        log_message "$name не установлен, и версию узнать не удалось. Сервер стартует без него." "error"
        return 1
    fi

    current="$(get_current_version "$name")"
    if [ "$installed" -eq 1 ]; then
        if [ "$current" = "$want" ]; then
            log_message "У $name актуальная версия: $current" "success"
            return 0
        fi
        # Без фиксации — только вперёд. Иначе выключенная бета откатила бы
        # v1.4.11-beta.10 на стабильную v1.4.10, которая как раз и падает с
        # текущей CS2. Обновимся, когда выйдет стабильная новее стоящей беты.
        if [ -z "$pin" ] && [ -n "$current" ] && version_gt "$current" "$want"; then
            log_message "У $name стоит $current — новее последней подходящей ($want). Оставляем." "info"
            return 0
        fi
        log_message "$name: ${current:-неизвестна} → $want" "running"
    else
        log_message "$name не установлен. Устанавливаю версию $want..." "running"
    fi

    if tree="$(store_tree "$type" "$want")"; then
        log_message "$name $want — со склада ноды, без скачивания." "info"
    else
        tree="$TEMP_DIR/$type-tree"
        rm -rf "$tree"
        if ! prepare_tree "$type" "$want" "$tree"; then
            if [ "$installed" -eq 1 ]; then
                log_message "$name обновить не удалось, продолжаем на установленной версии ($current)." "warning"
                return 0
            fi
            log_message "$name не установлен, и установка не удалась. Сервер стартует без него." "error"
            return 1
        fi
    fi

    if ! apply_tree "$type" "$tree"; then
        log_message "Не удалось разложить файлы $name" "error"
        return 1
    fi
    update_version_file "$name" "$want"
    log_message "$name установлен/обновлён до версии $want" "success"
    return 0
}

# ===========================
# gameinfo.gi
# ===========================

# Идемпотентно приводит gameinfo.gi к переданному набору аддонов (пути
# поиска: csgo/addons/metamod, sharp, …): сносит ВСЕ строки `Game csgo/addons/*`
# и `Game sharp` и вставляет нужные после Game_LowViolence в порядке аргументов. Остальные строки файла не трогаются, поэтому ручные правки
# пользователя сохраняются. Повторный вызов с теми же аргументами ничего не меняет.
sync_gameinfo() {
    local -a wanted=("$@")

    if [ ! -f "$GAMEINFO_FILE" ]; then
        log_message "Файл gameinfo.gi не найден: $GAMEINFO_FILE" "error"
        return 1
    fi

    local block="" entry
    for entry in ${wanted[@]+"${wanted[@]}"}; do
        block+=$'\t\t\tGame\t'"$entry"$'\n'
    done

    local tmp="${GAMEINFO_FILE}.tmp"
    if ! awk -v block="$block" '
            /[Gg]ame[[:blank:]]+(csgo\/addons\/|sharp[[:space:]]*$)/ { next }
            { print }
            /Game_LowViolence/ && !inserted { printf "%s", block; inserted = 1 }
            END { if (!inserted) exit 3 }
        ' "$GAMEINFO_FILE" > "$tmp"
    then
        rm -f "$tmp"
        log_message "В gameinfo.gi нет якоря Game_LowViolence — аддоны не будут подключены." "error"
        log_message "Удалите game/csgo/gameinfo.gi и перезапустите сервер, чтобы взять файл с хоста." "error"
        return 1
    fi

    mv "$tmp" "$GAMEINFO_FILE"

    if [ "${#wanted[@]}" -eq 0 ]; then
        log_message "gameinfo.gi: аддоны не подключены." "info"
    else
        log_message "gameinfo.gi: активны — ${wanted[*]}" "success"
    fi
    return 0
}

# 0, если файлы различаются не только строками, которые ставим сами:
# аддоны (sync_gameinfo) и RequireLoginForDedicatedServers (apply_tokenless)
gameinfo_differs() {
    local own='csgo/addons/|[Gg]ame[[:blank:]]+sharp|RequireLoginForDedicatedServers'
    ! diff -q <(grep -Ev "$own" "$1" | tr -d '\r') \
              <(grep -Ev "$own" "$2" | tr -d '\r') >/dev/null 2>&1
}

# ALLOW_TOKENLESS=1 — сервер стартует без GSLT (в публичный список не попадёт,
# подключиться можно по IP): RequireLoginForDedicatedServers "0". Иначе — "1".
apply_tokenless() {
    local want=1
    [ "${ALLOW_TOKENLESS:-0}" = "1" ] && want=0
    [ -f "$GAMEINFO_FILE" ] || return 0
    if ! grep -q 'RequireLoginForDedicatedServers' "$GAMEINFO_FILE"; then
        [ "$want" = 1 ] || log_message "ALLOW_TOKENLESS=1, но в gameinfo.gi нет RequireLoginForDedicatedServers — без GSLT сервер может не запуститься." "warning"
        return 0
    fi
    sed -i -E "s/(RequireLoginForDedicatedServers\"?[[:space:]]+\"?)[0-9]/\1$want/" "$GAMEINFO_FILE"
    [ "$want" = 1 ] || log_message "ALLOW_TOKENLESS=1: сервер запустится без GSLT — в публичный список не попадёт, подключение по IP." "info"
}

# Контейнер держит СВОЮ копию gameinfo.gi: дописывает туда аддоны, а /mnt —
# только на чтение. Valve меняет этот файл с обновлениями CS2 (в 1.41.8.2 —
# настройки Steam Audio и пути панорамы), и копия устаревает. Раньше тут было
# лишь предупреждение «удалите файл руками» — на каждом сервере после каждого
# обновления игры.
#
# Рядом лежит gameinfo.gi.host — версия с хоста, из которой сделана копия.
# По ней отличаем обновление Valve от правок пользователя:
#   хост совпадает с .host → Valve файл не меняла: копию и ваши правки не трогаем;
#   хост изменился         → берём новый файл, прежний кладём в gameinfo.gi.bak.
# Строки аддонов после этого заново расставит sync_gameinfo.
refresh_gameinfo() {
    local base="$GAMEINFO_FILE.host"

    if [ ! -f "$GAMEINFO_MNT" ]; then
        log_message "На хосте нет gameinfo.gi ($GAMEINFO_MNT) — проверьте, что SteamCMD установил игру." "error"
        return 0
    fi

    # Симлинк увёл бы запись в /mnt, смонтированный только на чтение
    if [ -L "$GAMEINFO_FILE" ]; then
        rm -f "$GAMEINFO_FILE"
    fi

    if [ -f "$GAMEINFO_FILE" ] && [ -f "$base" ] && cmp -s "$GAMEINFO_MNT" "$base"; then
        return 0
    fi

    mkdir -p "$(dirname "$GAMEINFO_FILE")"
    if [ ! -f "$GAMEINFO_FILE" ]; then
        log_message "Копируем gameinfo.gi с хоста." "info"
    elif [ ! -f "$base" ] && ! gameinfo_differs "$GAMEINFO_FILE" "$GAMEINFO_MNT"; then
        # Файл актуален, базы ещё нет (сервер старше этой логики) — запоминаем её
        cp "$GAMEINFO_MNT" "$base"
        return 0
    else
        cp "$GAMEINFO_FILE" "$GAMEINFO_FILE.bak"
        log_message "gameinfo.gi устарел: на хосте новая версия от Valve (обновление CS2). Берём её." "warning"
        log_message "Прежний файл — game/csgo/gameinfo.gi.bak. Если в нём были ваши правки, перенесите их." "warning"
    fi

    cp "$GAMEINFO_MNT" "$GAMEINFO_FILE"
    cp "$GAMEINFO_MNT" "$base"
}

# ===========================
# server.cfg
# ===========================
update_server_cfg() {
    log_message "Обновление server.cfg..." "running"

    local ROOT_CFG="/servUpConfig.cfg"
    local SERVER_CFG="${GAME_DIRECTORY}/cfg/${CFG_FILE:-server.cfg}"

    if [ ! -f "$ROOT_CFG" ]; then
        log_message "servUpConfig.cfg не найден, пропускаем обновление." "error"
        return 0
    fi

    if [ ! -f "$SERVER_CFG" ]; then
        cp "$ROOT_CFG" "$SERVER_CFG"
        log_message "Создан $SERVER_CFG на основе servUpConfig.cfg" "success"
        return 0
    fi

    while IFS= read -r line || [[ -n "$line" ]]; do
        local trimmed_line
        trimmed_line="$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        [[ -z "$trimmed_line" ]] && continue
        [[ "$trimmed_line" =~ ^// ]] && continue

        local first_word
        first_word="$(echo "$trimmed_line" | awk '{print $1}')"
        # -F: имя квара берём буквально, чтобы спецсимволы не стали regex
        if ! grep -qF -- "$first_word" "$SERVER_CFG"; then
            echo "$trimmed_line" >> "$SERVER_CFG"
            log_message "Добавлена строка в server.cfg: $trimmed_line" "debug"
        fi
    done < "$ROOT_CFG"
}

initialize_server_cfg() {
    local ROOT_CFG="/servUpConfig.cfg"
    local SERVER_CFG="${GAME_DIRECTORY}/cfg/${CFG_FILE:-server.cfg}"

    if [ ! -f "$SERVER_CFG" ] || [ ! -s "$SERVER_CFG" ]; then
        log_message "Инициализация server.cfg..." "running"
        cp "$ROOT_CFG" "$SERVER_CFG"
        log_message "Создан $SERVER_CFG на основе servUpConfig.cfg." "success"

        sed -i "s/^hostname .*/hostname \"${HOST_NAME:-ServUp-CS2}\"/" "$SERVER_CFG"
        sed -i "s/^sv_tags .*/sv_tags \"${SERVER_TAGS:-servup}\"/" "$SERVER_CFG"
    fi
}

# ===========================
# Главная процедура
# ===========================
cleanup_and_update() {
    if [ "${CLEANUP_ENABLED:-0}" = "1" ]; then
        cleanup || log_message "Очистка завершилась с ошибкой, продолжаем." "warning"
    fi

    mkdir -p "$TEMP_DIR" "$OUTPUT_DIR"

    local platform
    platform="$(addon_platform)"
    log_message "Платформа аддонов: $platform" "info"

    # Записи для gameinfo.gi. MetaMod обязан идти первым.
    local -a entries=()

    case "$platform" in
        metamod)
            if ensure_addon metamod; then
                entries+=("csgo/addons/metamod")
                # дефолт 1 — как в egg: иначе старый egg + новый образ = CSS молча пропал
                if [ "${CSS_ENABLED:-1}" = "1" ]; then
                    # CSS — плагин MetaMod: своей записи в gameinfo.gi не имеет,
                    # грузится через addons/metamod/counterstrikesharp.vdf
                    ensure_addon css || true
                else
                    log_message "CounterStrikeSharp отключён (CSS_ENABLED=0)." "info"
                fi
            else
                log_message "MetaMod недоступен — CounterStrikeSharp пропущен, он без MetaMod не работает." "error"
            fi
            ;;
        swiftly)
            if ensure_addon swiftly; then
                entries+=("csgo/addons/swiftlys2")
            fi
            ;;
        none)
            log_message "ADDON_PLATFORM=none — аддоны не устанавливаются, записи из gameinfo.gi убраны." "info"
            ;;
    esac

    # ModSharp — отдельный переключатель, как CounterStrikeSharp. С MetaMod
    # уживается, с CounterStrikeSharp и Swiftly — нет: предупреждаем, решает владелец.
    if [ "${MODSHARP_ENABLED:-0}" = "1" ]; then
        [ "$platform" != swiftly ] || log_message "ModSharp и Swiftly несовместимы — сервер может не запуститься. Оставьте что-то одно." "warning"
        [ "$platform" != metamod ] || [ "${CSS_ENABLED:-1}" != "1" ] \
            || log_message "ModSharp и CounterStrikeSharp несовместимы — сервер может не запуститься. Выключите один (CSS_ENABLED или MODSHARP_ENABLED)." "warning"
        if ensure_addon dotnet && ensure_addon modsharp; then
            entries+=("sharp")
        else
            log_message "ModSharp не подключён: без него и его .NET сервер стартует как есть." "error"
        fi
    fi

    # Файлы отключённых аддонов НЕ удаляем: плагины и конфиги пользователя остаются,
    # обратное переключение платформы мгновенное.
    sync_gameinfo ${entries[@]+"${entries[@]}"} || true
    apply_tokenless || true

    if [ "${UPDATE_CFG_FILE:-0}" = "1" ]; then
        update_server_cfg
    fi

    rm -rf "$TEMP_DIR"
}
