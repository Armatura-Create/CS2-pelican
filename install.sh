#!/usr/bin/env bash
#
# Установка CS2 Updater на хост Pelican одной командой:
#
#   curl -fsSL https://raw.githubusercontent.com/Armatura-Create/CS2-pelican/master/install.sh | sudo bash
#
# Первый запуск: спрашивает каталог, качает релиз (только service/, без docker/
# и egg/ — на хосте они не нужны), сверяет контрольную сумму и запускает мастер
# настройки configure.sh — он проверит панель, ключи, ноду, Wings и всё остальное.
#
# Повторный запуск на настроенном сервере — меню: обновить, перенастроить, удалить.
#
#   INSTALL_DIR   куда ставить       (по умолчанию спросит, предложит /opt/cs2-updater)
#   VERSION       какую версию       (по умолчанию latest, например v1.0.0)
#   REPO          owner/repo
#   BASE_URL      зеркало вместо GitHub Releases
#
# Всё тело в функции, вызов последней строкой: оборванная закачка не выполнит огрызок.
# `exit` на той же строке, что и вызов, — обязательно: при `curl | bash` оболочка
# читает скрипт со stdin, а установщик переключает stdin на терминал
# (exec </dev/tty), чтобы задавать вопросы. Без exit оболочка после установки
# продолжала читать «скрипт» с клавиатуры — невидимый root-shell без приглашения.
# Строку целиком bash читает до выполнения, так что exit сработает.

set -Eeuo pipefail

cs2_install() {
    local REPO="${REPO:-Armatura-Create/CS2-pelican}"
    local VERSION="${VERSION:-latest}"
    local ASSET="cs2-updater.tar.gz"
    # Путь обязан совпадать с CYCLE_LOCK в service/start.sh
    local CYCLE_LOCK="/run/cs2-updater-cycle.lock"

    local RED=$'\033[0;31m' GREEN=$'\033[0;32m' YELLOW=$'\033[0;33m' BOLD=$'\033[1m' NC=$'\033[0m'
    local P="${YELLOW}[CS2 Updater]${NC} "
    info() { printf '%s%s\n'     "$P" "$1" >&2; }
    ok()   { printf '%s%s%s%s\n' "$P" "$GREEN"  "$1" "$NC" >&2; }
    warn() { printf '%s%s%s%s\n' "$P" "$YELLOW" "$1" "$NC" >&2; }
    die()  { printf '%s%s%s%s\n' "$P" "$RED"    "$1" "$NC" >&2; exit 1; }

    echo >&2; info "Установка CS2 Updater"; info "─────────────────────"

    # --- права и система ---
    [ "$(id -u)" -eq 0 ] || die "Нужен root. Запустите: curl ... | sudo bash"
    command -v systemctl >/dev/null 2>&1 || die "Не найден systemd."
    command -v apt-get   >/dev/null 2>&1 || die "Поддерживаются Debian и Ubuntu."

    # --- интерактивный ввод ---
    # При `curl | bash` stdin занят телом скрипта, вопросы читать неоткуда
    if [ ! -t 0 ]; then
        if [ -e /dev/tty ] && (exec </dev/tty) 2>/dev/null; then exec </dev/tty
        else die "Нужен интерактивный терминал: установщик задаёт вопросы."; fi
    fi

    # BASE_URL позволяет подставить зеркало или локальный каталог (используется в тестах)
    local url_base="${BASE_URL:-}"
    if [ -z "$url_base" ]; then
        if [ "$VERSION" = "latest" ]; then
            url_base="https://github.com/$REPO/releases/latest/download"
        else
            url_base="https://github.com/$REPO/releases/download/$VERSION"
        fi
    fi

    local tmp=""
    # Качает релиз в $tmp/new и сверяет контрольную сумму
    fetch_release() {
        tmp="$(mktemp -d)"
        # shellcheck disable=SC2064
        trap "rm -rf '$tmp'" EXIT

        info "Качаем релиз ($VERSION)..."
        curl -fsSL --retry 3 --connect-timeout 15 -o "$tmp/$ASSET" "$url_base/$ASSET" \
            || die "Не удалось скачать $url_base/$ASSET
       Проверьте сеть и что релиз опубликован: https://github.com/$REPO/releases"

        if curl -fsSL --retry 3 -o "$tmp/$ASSET.sha256" "$url_base/$ASSET.sha256" 2>/dev/null; then
            ( cd "$tmp" && sha256sum -c --status "$ASSET.sha256" ) \
                || die "Контрольная сумма не сошлась — архив повреждён или подменён. Ничего не изменено."
            ok "Контрольная сумма совпала."
        else
            warn "Файл с контрольной суммой недоступен, пропускаю проверку."
        fi

        mkdir -p "$tmp/new"
        tar -xzf "$tmp/$ASSET" -C "$tmp/new" --strip-components=1 || die "Архив не распаковался."
    }

    # Обновление тем update.sh, что лежит в свежем релизе
    run_update() {
        fetch_release
        [ -f "$tmp/new/update.sh" ] || die "В релизе $VERSION нет update.sh — обновитесь командой из README."
        INSTALL_DIR="$1" BASE_URL="$url_base" VERSION="$VERSION" REPO="$REPO" bash "$tmp/new/update.sh"
    }

    # Ждём конца цикла обновления CS2: остановить сервис посреди него —
    # оставить игровые серверы выключенными
    wait_cycle() {
        if [ -e "$CYCLE_LOCK" ] && ! flock -n "$CYCLE_LOCK" true 2>/dev/null; then
            info "Идёт обновление CS2 — жду его окончания, чтобы не оставить серверы выключенными..."
            flock -w 1800 "$CYCLE_LOCK" true 2>/dev/null || warn "Не дождался конца цикла за 30 минут, продолжаю."
        fi
    }

    uninstall() {
        local d="$1" svc="$2" base answer size
        case "$d" in ""|/) die "Странный каталог установки: '$d'. Удалите вручную." ;; esac
        base="$(grep -oP '^BASE_DIR="\K[^"]+' "$d/.env" 2>/dev/null || true)"

        echo >&2
        warn "Будет удалено: сервис ${svc:-?}.service, таймер автообновления, $d и его бэкапы."
        [ -z "$base" ] || info "Файлы игры ($base) — спрошу отдельно, по умолчанию останутся."
        read -rp "  Для подтверждения введите «удалить»: " answer || answer=""
        if [ "$answer" != "удалить" ]; then
            info "Не подтверждено — ничего не удаляю."
            return 0
        fi

        wait_cycle
        if [ -n "$svc" ]; then
            systemctl disable --now "$svc.service" >/dev/null 2>&1 || true
            rm -f "/etc/systemd/system/$svc.service"
        fi
        systemctl disable --now cs2-updater-autoupdate.timer >/dev/null 2>&1 || true
        rm -f /etc/systemd/system/cs2-updater-autoupdate.service /etc/systemd/system/cs2-updater-autoupdate.timer
        systemctl daemon-reload
        rm -rf "$d" "$d".backup-*
        ok "CS2 Updater удалён."

        if [ -n "$base" ] && [ -d "$base" ]; then
            size="$(du -sh "$base" 2>/dev/null | cut -f1 || echo "?")"
            read -rp "  Удалить и файлы игры $base ($size)? Серверы, которые их монтируют, без них не запустятся [y/N]: " answer || answer=""
            case "$answer" in
                [YyДд]*) rm -rf "$base"; ok "Файлы игры удалены." ;;
                *) info "Файлы игры оставлены: $base" ;;
            esac
        fi
        info "Mount в панели и allowed_mounts в Wings не трогал — уберите сами, если больше не нужны."
    }

    existing_menu() {
        local d="$1" svc ver state choice
        svc="$(grep -ls "^WorkingDirectory=$d\$" /etc/systemd/system/*.service 2>/dev/null | head -n1 || true)"
        svc="$(basename "${svc:-}" .service)"
        ver="$(cat "$d/VERSION" 2>/dev/null || echo "неизвестна")"
        state="не найден"
        [ -z "$svc" ] || state="$svc.service, $(systemctl is-active "$svc.service" 2>/dev/null || true)"

        echo >&2
        info "${BOLD}CS2 Updater уже установлен${NC}: $d, версия $ver, сервис: $state."
        printf '  1) Обновить до последней версии\n' >&2
        printf '  2) Перенастроить — текущие значения будут предложены по умолчанию\n' >&2
        printf '  3) Удалить\n' >&2
        printf '  4) Выйти\n' >&2
        read -rp "  Выбор [1]: " choice || choice=4
        case "${choice:-1}" in
            1) run_update "$d" ;;
            # Сначала обновление: мастер настройки в старых версиях не умел
            # подставлять текущие значения и перезаписал бы .env вслепую
            2) run_update "$d" && "$d/configure.sh" ;;
            3) uninstall "$d" "$svc" ;;
            *) info "Ничего не меняю." ;;
        esac
    }

    # --- уже установлено? ---
    local dir="${INSTALL_DIR:-}" unit=""
    if [ -z "$dir" ]; then
        unit="$(grep -ls 'ExecStart=.*/start\.sh' /etc/systemd/system/*.service 2>/dev/null | head -n1 || true)"
        [ -z "$unit" ] || dir="$(grep -oP '^WorkingDirectory=\K.*' "$unit" | head -n1 || true)"
    fi
    if [ -n "$dir" ] && [ -f "$dir/.env" ]; then
        existing_menu "$dir"
        return 0
    fi

    # --- новая установка ---
    if [ -z "$dir" ]; then
        read -rp "  Каталог установки [/opt/cs2-updater]: " dir || dir=""
        dir="${dir:-/opt/cs2-updater}"
    fi
    case "$dir" in
        /*) ;;
        *) die "Нужен абсолютный путь, например /opt/cs2-updater." ;;
    esac
    dir="${dir%/}"

    info "Ставим зависимости..."
    apt-get update -qq >/dev/null 2>&1 || true
    apt-get install -y -qq curl ca-certificates tar coreutils util-linux >/dev/null 2>&1 \
        || die "apt не смог поставить curl/tar. Проверьте apt-get update."

    fetch_release
    mkdir -p "$dir"
    cp -a "$tmp/new/." "$dir/"
    chmod +x "$dir"/*.sh
    ok "Развёрнута версия $(cat "$dir/VERSION" 2>/dev/null || echo "$VERSION") в $dir"

    "$dir/configure.sh" || die "Настройка прервана. Файлы в $dir оставлены — запустите установку снова, чтобы продолжить."

    cat >&2 <<TXT

$(printf '%s' "$P")${GREEN}Установка завершена.${NC}

  Повторный запуск этой же команды — меню: обновить, перенастроить, удалить.

TXT
}

cs2_install "$@"; exit $?
