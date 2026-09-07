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
# Маркер = файл, доказывающий РЕАЛЬНУЮ установку.
# Проверять сам каталог нельзя: CounterStrikeSharp кладёт
# addons/metamod/counterstrikesharp.vdf, из-за чего addons/metamod существует
# даже когда самого MetaMod нет.
addon_marker() {
    case "$1" in
        metamod) printf '%s' "$OUTPUT_DIR/metamod/bin/linuxsteamrt64/metamod.2.cs2.so" ;;
        css)     printf '%s' "$OUTPUT_DIR/counterstrikesharp/bin/linuxsteamrt64/counterstrikesharp.so" ;;
        swiftly) printf '%s' "$OUTPUT_DIR/swiftlys2/bin/linuxsteamrt64/swiftlys2.so" ;;
    esac
}

addon_name() {
    case "$1" in
        metamod) printf '%s' "Metamod" ;;
        css)     printf '%s' "CSS" ;;
        swiftly) printf '%s' "Swiftly" ;;
    esac
}

# Включено ли автообновление для конкретного аддона.
# ВАЖНО: значения по умолчанию обязаны совпадать с default_value в egg.
# Сервер на старом egg не передаёт новых переменных вовсе, и расхождение
# означало бы, что аддон молча выключится при первом же рестарте.
addon_autoupdate() {
    case "$1" in
        metamod) printf '%s' "${METAMOD_AUTOUPDATE:-1}" ;;
        css)     printf '%s' "${CSS_AUTOUPDATE:-1}" ;;
        swiftly) printf '%s' "${SWIFTLY_AUTOUPDATE:-1}" ;;
    esac
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
github_latest_release() {
    local repo="$1"
    local out_json="$2"

    local -a headers=(-H "Accept: application/vnd.github+json")
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        headers+=(-H "Authorization: Bearer $GITHUB_TOKEN")
    fi

    local code
    code="$(curl -sS -m 30 -o "$out_json" -w '%{http_code}' \
        "${headers[@]}" \
        "https://api.github.com/repos/$repo/releases/latest" 2>/dev/null || echo "000")"

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
        *)
            log_message "GitHub API вернул HTTP $code для $repo." "error"
            return 1
            ;;
    esac
}

# ===========================
# Установка / обновление аддонов
# ===========================

# Устанавливает аддон, если его нет; обновляет, если стоит автообновление.
# Возвращает 0, если после вызова аддон присутствует и пригоден к загрузке.
ensure_addon() {
    local type="$1"
    local name marker installed=0
    name="$(addon_name "$type")"
    marker="$(addon_marker "$type")"

    [ -e "$marker" ] && installed=1

    if [ "$installed" -eq 1 ] && [ "$(addon_autoupdate "$type")" != "1" ]; then
        log_message "$name установлен, автообновление выключено — оставляем текущую версию ($(get_current_version "$name"))." "info"
        return 0
    fi

    local ok=0
    if [ "$type" = "metamod" ]; then
        install_metamod "$installed" && ok=1 || ok=0
    else
        install_github_addon "$type" "$installed" && ok=1 || ok=0
    fi

    if [ "$ok" -eq 1 ]; then
        return 0
    fi

    # Сеть/зеркало недоступны. Если аддон уже стоял — продолжаем на старой версии.
    if [ "$installed" -eq 1 ]; then
        log_message "$name обновить не удалось, продолжаем на установленной версии ($(get_current_version "$name"))." "warning"
        return 0
    fi

    log_message "$name не установлен, и установка не удалась. Сервер стартует без него." "error"
    return 1
}

install_github_addon() {
    local type="$1"
    local installed="$2"

    local repo pattern name
    name="$(addon_name "$type")"
    case "$type" in
        css)
            repo="roflmuffin/CounterStrikeSharp"
            pattern="counterstrikesharp-with-runtime-linux-.*\\.zip"
            ;;
        swiftly)
            repo="swiftly-solution/swiftlys2"
            pattern="swiftlys2-linux-v.*-with-runtimes\\.zip"
            ;;
        *)
            log_message "Неизвестный тип аддона: $type" "error"
            return 1
            ;;
    esac

    local temp_dir="$TEMP_DIR/$type"
    local json="$TEMP_DIR/$type-release.json"
    rm -rf "$temp_dir"
    mkdir -p "$temp_dir" "$OUTPUT_DIR"

    log_message "Проверка обновлений для $name..." "running"
    github_latest_release "$repo" "$json" || return 1

    local new_version
    new_version="$(jq -r '.tag_name // empty' "$json" 2>/dev/null || true)"
    if [ -z "$new_version" ]; then
        log_message "Не удалось определить версию для $name (некорректный ответ GitHub)." "error"
        return 1
    fi

    if [ "$installed" -eq 1 ]; then
        local current_version
        current_version="$(get_current_version "$name")"
        if [ "$current_version" = "$new_version" ]; then
            log_message "У $name актуальная версия: $current_version" "success"
            return 0
        fi
        log_message "Новая версия для $name: $new_version (была ${current_version:-неизвестна})" "running"
    else
        log_message "$name не установлен. Устанавливаю версию $new_version..." "running"
    fi

    # first вместо `| head -n1`: под `set -o pipefail` SIGPIPE в head уронил бы конвейер
    local asset_url
    asset_url="$(jq -r --arg re "$pattern" \
        '[.assets[]?.browser_download_url | select(test($re))] | first // empty' "$json")"

    if [ -z "$asset_url" ]; then
        log_message "В релизе $name не найден файл по паттерну: $pattern" "error"
        jq -r '.assets[]?.name' "$json" 2>/dev/null | while read -r a; do
            log_message "  доступно: $a" "debug"
        done
        return 1
    fi

    log_message "Найден файл: $(basename "$asset_url")" "debug"
    handle_download_and_extract "$asset_url" "$temp_dir/download.zip" "$temp_dir" "zip" || return 1

    local addons_src
    addons_src="$(find "$temp_dir" -maxdepth 2 -type d -name 'addons' | head -n1 || true)"
    if [ -z "$addons_src" ] || [ ! -d "$addons_src" ]; then
        log_message "Структура архива $name не содержит папку addons/ (проверено до глубины 2)" "error"
        return 1
    fi

    # Swiftly в некоторых релизах кладёт свой metamod — им управляем отдельно
    if [ "$type" = "swiftly" ] && [ -d "$addons_src/metamod" ]; then
        log_message "Удаляем metamod из архива Swiftly (управляется отдельно)" "debug"
        rm -rf "$addons_src/metamod"
    fi

    cp -rf "$addons_src/." "$OUTPUT_DIR/" || {
        log_message "Не удалось скопировать файлы $name в $OUTPUT_DIR" "error"
        return 1
    }

    update_version_file "$name" "$new_version"
    log_message "$name установлен/обновлён до версии $new_version" "success"
    return 0
}

install_metamod() {
    local installed="$1"
    local branch="${METAMOD_BRANCH:-master}"   # stable | dev | master

    local downloads_page="https://www.metamodsource.net/downloads.php?branch=${branch}"
    local page
    page="$(curl -fsSL -m 30 "$downloads_page" 2>/dev/null || true)"
    if [ -z "$page" ]; then
        log_message "Страница загрузок Metamod недоступна: $downloads_page" "error"
        return 1
    fi

    # Берём linux-архив с максимальным номером билда gitNNNN
    local file_name
    file_name="$(
        printf '%s' "$page" \
        | grep -oE 'mmsource-[^"]*-linux\.tar\.gz' \
        | tr -d '\r' \
        | awk '{fn=$0; if (match($0,/git[0-9]+/)) {g=substr($0,RSTART+3,RLENGTH-3); print g" "fn}}' \
        | sort -nr | head -n1 | awk '{ $1=""; sub(/^ /,""); print }' \
        || true
    )"

    if [ -z "$file_name" ]; then
        log_message "Не удалось найти ссылку на linux-архив на странице $downloads_page" "error"
        return 1
    fi

    local new_version
    new_version="$(printf '%s' "$file_name" | grep -oE 'git[0-9]+' | tr -d '\r' || true)"
    if [ -z "$new_version" ]; then
        log_message "Не удалось распознать номер билда из имени: $file_name" "error"
        return 1
    fi

    if [ "$installed" -eq 1 ]; then
        local current_version
        current_version="$(get_current_version "Metamod")"
        if [ "$current_version" = "$new_version" ]; then
            log_message "У Metamod актуальная версия: $current_version" "success"
            return 0
        fi
        log_message "Новая версия для Metamod: $new_version (была ${current_version:-неизвестна})" "running"
    else
        log_message "Metamod не установлен. Устанавливаю версию $new_version..." "running"
    fi

    local url="https://www.sourcemm.net/mmsdrop/2.0/${file_name}"
    local tmp_tar="$TEMP_DIR/metamod.tar.gz"
    rm -f "$tmp_tar"
    rm -rf "$TEMP_DIR/metamod"
    mkdir -p "$TEMP_DIR" "$OUTPUT_DIR"

    handle_download_and_extract "$url" "$tmp_tar" "$TEMP_DIR/metamod" "tar.gz" || return 1

    local addons_src
    addons_src="$(find "$TEMP_DIR/metamod" -maxdepth 2 -type d -name 'addons' | head -n1 || true)"
    if [ -z "$addons_src" ]; then
        log_message "Не нашли папку addons/ после распаковки Metamod" "error"
        return 1
    fi

    cp -rf "$addons_src/." "$OUTPUT_DIR/" || {
        log_message "Не удалось скопировать файлы Metamod в $OUTPUT_DIR" "error"
        return 1
    }

    update_version_file "Metamod" "$new_version"
    log_message "Metamod установлен/обновлён до $new_version" "success"
    return 0
}

# ===========================
# gameinfo.gi
# ===========================

# Идемпотентно приводит gameinfo.gi к переданному набору аддонов:
# сносит ВСЕ строки `Game csgo/addons/*` и вставляет нужные после Game_LowViolence
# в порядке аргументов. Остальные строки файла не трогаются, поэтому ручные правки
# пользователя сохраняются. Повторный вызов с теми же аргументами ничего не меняет.
sync_gameinfo() {
    local -a wanted=("$@")

    if [ ! -f "$GAMEINFO_FILE" ]; then
        log_message "Файл gameinfo.gi не найден: $GAMEINFO_FILE" "error"
        return 1
    fi

    local block="" entry
    for entry in ${wanted[@]+"${wanted[@]}"}; do
        block+=$'\t\t\tGame\tcsgo/addons/'"$entry"$'\n'
    done

    local tmp="${GAMEINFO_FILE}.tmp"
    if ! awk -v block="$block" '
            /[Gg]ame[[:blank:]]+csgo\/addons\// { next }
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

# Предупреждаем, если Valve обновила gameinfo.gi на хосте, а в контейнере
# лежит старая копия (или пользователь правил файл руками).
gameinfo_drift_check() {
    [ -f "$GAMEINFO_MNT" ] && [ -f "$GAMEINFO_FILE" ] || return 0

    if ! diff -q <(grep -v 'csgo/addons/' "$GAMEINFO_FILE") \
                 <(grep -v 'csgo/addons/' "$GAMEINFO_MNT") >/dev/null 2>&1; then
        log_message "gameinfo.gi в контейнере отличается от версии на хосте (/mnt)." "warning"
        log_message "Если это не ваши правки — удалите game/csgo/gameinfo.gi и перезапустите сервер." "warning"
    fi
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
                entries+=("metamod")
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
                entries+=("swiftlys2")
            fi
            ;;
        none)
            log_message "ADDON_PLATFORM=none — аддоны не устанавливаются, записи из gameinfo.gi убраны." "info"
            ;;
    esac

    # Файлы отключённых аддонов НЕ удаляем: плагины и конфиги пользователя остаются,
    # обратное переключение платформы мгновенное.
    sync_gameinfo ${entries[@]+"${entries[@]}"} || true

    if [ "${UPDATE_CFG_FILE:-0}" = "1" ]; then
        update_server_cfg
    fi

    rm -rf "$TEMP_DIR"
}
