#!/usr/bin/env bash
#
# Установка CS2 Updater на хост Pelican одной командой:
#
#   curl -fsSL https://raw.githubusercontent.com/Armatura-Create/CS2-pelican/master/install.sh | sudo bash
#
# Качает архив последнего релиза (только service/, без docker/ и egg/ —
# на хосте они не нужны), проверяет контрольную сумму, разворачивает,
# запускает настройку и проверяет связь с панелью.
#
#   INSTALL_DIR   куда ставить       (по умолчанию /opt/cs2-updater)
#   VERSION       какую версию       (по умолчанию latest, например v1.0.0)
#   REPO          owner/repo
#   BASE_URL      зеркало вместо GitHub Releases
#
# Обновление — отдельный скрипт update.sh.
#
# Всё тело в функции, вызов последней строкой: оборванная закачка не выполнит огрызок.

set -Eeuo pipefail

cs2_install() {
    local INSTALL_DIR="${INSTALL_DIR:-/opt/cs2-updater}"
    local REPO="${REPO:-Armatura-Create/CS2-pelican}"
    local VERSION="${VERSION:-latest}"
    local ASSET="cs2-updater.tar.gz"

    local RED=$'\033[0;31m' GREEN=$'\033[0;32m' YELLOW=$'\033[0;33m' NC=$'\033[0m'
    local P="${YELLOW}[CS2 Updater]${NC} "
    info() { printf '%s%s\n'     "$P" "$1" >&2; }
    ok()   { printf '%s%s%s%s\n' "$P" "$GREEN"  "$1" "$NC" >&2; }
    warn() { printf '%s%s%s%s\n' "$P" "$YELLOW" "$1" "$NC" >&2; }
    die()  { printf '%s%s%s%s\n' "$P" "$RED"    "$1" "$NC" >&2; exit 1; }

    echo >&2; info "Установка CS2 Updater"; info "─────────────────────"

    # --- права ---
    local SUDO=""
    if [ "$(id -u)" -ne 0 ]; then
        command -v sudo >/dev/null 2>&1 || die "Нужен root. Запустите: curl ... | sudo bash"
        SUDO="sudo"; sudo -v || die "sudo недоступен."
    fi

    command -v systemctl >/dev/null 2>&1 || die "Не найден systemd."
    command -v apt-get   >/dev/null 2>&1 || die "Поддерживаются Debian и Ubuntu."

    # --- уже стоит? ---
    if [ -f "$INSTALL_DIR/.env" ]; then
        warn "CS2 Updater уже установлен в $INSTALL_DIR (версия $(cat "$INSTALL_DIR/VERSION" 2>/dev/null || echo неизвестна))."
        printf '\n  curl -fsSL https://raw.githubusercontent.com/%s/master/update.sh | sudo bash\n\n' "$REPO" >&2
        die "Повторная установка затёрла бы .env с вашими токенами. Используйте update.sh."
    fi

    # --- интерактивный ввод ---
    # При `curl | bash` stdin занят телом скрипта, вопросы настройщика читать неоткуда
    if [ ! -t 0 ]; then
        if [ -e /dev/tty ] && (exec </dev/tty) 2>/dev/null; then exec </dev/tty
        else die "Нужен интерактивный терминал — настройщик спросит токены панели."; fi
    fi

    # --- зависимости ---
    info "Ставим зависимости..."
    $SUDO apt-get update -qq
    $SUDO apt-get install -y -qq curl ca-certificates tar coreutils sudo >/dev/null
    ok "Зависимости готовы."

    # --- скачивание релиза ---
    # BASE_URL позволяет подставить зеркало или локальный каталог (используется в тестах)
    local url_base="${BASE_URL:-}"
    if [ -z "$url_base" ]; then
        if [ "$VERSION" = "latest" ]; then
            url_base="https://github.com/$REPO/releases/latest/download"
        else
            url_base="https://github.com/$REPO/releases/download/$VERSION"
        fi
    fi

    local tmp; tmp="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf '$tmp'" RETURN

    info "Качаем релиз ($VERSION)..."
    curl -fsSL --retry 3 --connect-timeout 15 -o "$tmp/$ASSET" "$url_base/$ASSET" \
        || die "Не удалось скачать $url_base/$ASSET
       Проверьте сеть и что релиз опубликован: https://github.com/$REPO/releases"

    if curl -fsSL --retry 3 -o "$tmp/$ASSET.sha256" "$url_base/$ASSET.sha256" 2>/dev/null; then
        ( cd "$tmp" && sha256sum -c --status "$ASSET.sha256" ) \
            || die "Контрольная сумма не сошлась — архив повреждён или подменён. Установка прервана."
        ok "Контрольная сумма совпала."
    else
        warn "Файл с контрольной суммой недоступен, пропускаю проверку."
    fi

    # --- разворачиваем ---
    $SUDO mkdir -p "$INSTALL_DIR"
    $SUDO tar -xzf "$tmp/$ASSET" -C "$INSTALL_DIR" --strip-components=1 \
        || die "Не удалось распаковать архив."
    $SUDO chmod +x "$INSTALL_DIR"/*.sh
    local ver; ver="$($SUDO cat "$INSTALL_DIR/VERSION" 2>/dev/null || echo "$VERSION")"
    ok "Развёрнута версия $ver в $INSTALL_DIR"

    cd "$INSTALL_DIR"

    # --- настройка ---
    echo >&2
    info "Сейчас настройщик задаст вопросы. Приготовьте:"
    info "  • URL панели без / в конце"
    info "  • Application API токен (панель → Admin → API Credentials)"
    info "  • Client API токен (панель → Account → API Credentials) — ДРУГОЙ ключ"
    info "  • ID ноды с вашими CS2-серверами"
    info "На остальное можно жать Enter."
    echo >&2
    $SUDO ./configure.sh || die "Настройка прервана. Каталог $INSTALL_DIR оставлен как есть."

    # --- имя сервиса, место на диске ---
    local svc base_dir avail_gb
    svc="$(grep -rls "WorkingDirectory=$INSTALL_DIR\$" /etc/systemd/system/*.service 2>/dev/null | head -n1 || true)"
    svc="$(basename "${svc:-cs2-updater.service}")"

    base_dir="$($SUDO grep -oP '^BASE_DIR="\K[^"]+' .env 2>/dev/null || echo /home/cs2_base)"
    $SUDO mkdir -p "$base_dir"
    avail_gb="$(df -Pk "$base_dir" | awk 'NR==2 {print int($4/1048576)}')"
    if [ "${avail_gb:-0}" -lt 50 ]; then
        warn "На разделе с $base_dir свободно ${avail_gb} ГБ, а CS2 занимает ~40 ГБ."
    else
        ok "Место под игру: ${avail_gb} ГБ свободно в $base_dir"
    fi

    # --- проверка панели ---
    echo >&2; info "Проверяем связь с панелью..."
    if $SUDO ./test-pelican.sh; then
        ok "Панель отвечает, ключи рабочие."
    else
        echo >&2
        warn "Проверка панели нашла ошибки (см. вывод выше)."
        warn "Файлы игры updater обновит и так, но гасить/поднимать серверы не сможет."
        warn "Поправить: отредактируйте $INSTALL_DIR/.env и запустите $INSTALL_DIR/test-pelican.sh"
    fi

    # --- запуск ---
    echo >&2
    warn "Первый запуск скачает ~40 ГБ файлов игры: от 20 минут до нескольких часов."
    local answer=""
    read -rp "$(printf '%sЗапустить сервис сейчас? [Y/n]: ' "$P")" answer || answer="n"
    case "${answer:-y}" in
        [Nn]*) info "Не запускаю. Когда будете готовы: sudo systemctl start $svc" ;;
        *)
            $SUDO systemctl start "$svc"; sleep 3
            if $SUDO systemctl is-active --quiet "$svc"; then
                ok "Сервис $svc запущен, идёт скачивание игры."
            else
                warn "Сервис не поднялся. Смотрите: sudo journalctl -u $svc -n 50"
            fi ;;
    esac

    cat >&2 <<TXT

$(printf '%s' "$P")${GREEN}Установка завершена.${NC}

  Версия:     $ver
  Каталог:    $INSTALL_DIR
  Сервис:     $svc
  Файлы игры: $base_dir/server

Следить за скачиванием:
  sudo journalctl -u $svc -f

${YELLOW}Осталось в панели:${NC}
  1. Wings: $base_dir в allowed_mounts (/etc/pelican/config.yml), затем restart wings
  2. Admin → Mounts → source $base_dir/server, target /mnt
  3. Импортировать egg/pelican.yaml и добавить mount на каждый сервер

Обновление:
  curl -fsSL https://raw.githubusercontent.com/$REPO/master/update.sh | sudo bash

TXT
}

cs2_install "$@"
