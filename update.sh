#!/usr/bin/env bash
#
# Обновление CS2 Updater одной командой:
#
#   curl -fsSL https://raw.githubusercontent.com/Armatura-Create/CS2-pelican/master/update.sh | sudo bash
#
# Находит установку по systemd-юниту, отказывается работать посреди обновления
# CS2, качает релиз, сверяет версию и контрольную сумму, подменяет файлы и
# поднимает сервис. .env и logs/ не трогает.
#
#   INSTALL_DIR   каталог установки  (по умолчанию ищется по systemd-юниту)
#   VERSION       целевая версия     (по умолчанию latest; можно откатиться: VERSION=v1.0.0)
#   FORCE=1       обновлять даже посреди цикла обновления CS2 (опасно)
#   BASE_URL      зеркало вместо GitHub Releases
#
# Всё тело в функции, вызов последней строкой: оборванная закачка не выполнит огрызок.

set -Eeuo pipefail

cs2_update() {
    local REPO="${REPO:-Armatura-Create/CS2-pelican}"
    local VERSION="${VERSION:-latest}"
    local ASSET="cs2-updater.tar.gz"

    local RED=$'\033[0;31m' GREEN=$'\033[0;32m' YELLOW=$'\033[0;33m' NC=$'\033[0m'
    local P="${YELLOW}[CS2 Updater]${NC} "
    info() { printf '%s%s\n'     "$P" "$1" >&2; }
    ok()   { printf '%s%s%s%s\n' "$P" "$GREEN"  "$1" "$NC" >&2; }
    warn() { printf '%s%s%s%s\n' "$P" "$YELLOW" "$1" "$NC" >&2; }
    die()  { printf '%s%s%s%s\n' "$P" "$RED"    "$1" "$NC" >&2; exit 1; }

    echo >&2; info "Обновление CS2 Updater"; info "──────────────────────"

    local SUDO=""
    if [ "$(id -u)" -ne 0 ]; then
        command -v sudo >/dev/null 2>&1 || die "Нужен root."
        SUDO="sudo"; sudo -v || die "sudo недоступен."
    fi

    # --- где установлено ---
    local unit="" dir="${INSTALL_DIR:-}"
    if [ -n "$dir" ]; then
        unit="$(grep -rls "WorkingDirectory=$dir\$" /etc/systemd/system/*.service 2>/dev/null | head -n1 || true)"
    else
        unit="$(grep -rls 'ExecStart=.*/start\.sh' /etc/systemd/system/*.service 2>/dev/null | head -n1 || true)"
        [ -n "$unit" ] && dir="$(grep -oP '^WorkingDirectory=\K.*' "$unit" | head -n1)"
    fi
    [ -n "$dir" ] && [ -d "$dir" ] || die "Не нашёл установку CS2 Updater.
       Укажите явно: curl ... | sudo INSTALL_DIR=/opt/cs2-updater bash"
    [ -f "$dir/start.sh" ] || die "В $dir нет start.sh — это не каталог CS2 Updater."

    local svc; svc="$(basename "${unit:-cs2-updater.service}")"
    local cur;  cur="$($SUDO cat "$dir/VERSION" 2>/dev/null || echo "неизвестна")"
    info "Каталог: $dir"
    info "Сервис:  $svc"
    info "Версия:  $cur"

    # --- не идёт ли прямо сейчас обновление CS2 ---
    # Убить updater посреди цикла = оставить игровые серверы выключенными:
    # он их уже погасил, а поднять обратно уже не успеет.
    local busy=""
    if pgrep -f 'steamcmd' >/dev/null 2>&1; then
        busy="работает SteamCMD"
    else
        local jl stopped started
        jl="$($SUDO journalctl -u "$svc" -n 200 --no-pager 2>/dev/null || true)"
        stopped="$(printf '%s' "$jl" | grep -n 'Останавливаем сервер'                 | tail -n1 | cut -d: -f1 || true)"
        started="$(printf '%s' "$jl" | grep -n 'Запускаем сервер\|CS2 Updater запущен' | tail -n1 | cut -d: -f1 || true)"
        if [ -n "$stopped" ] && { [ -z "$started" ] || [ "$stopped" -gt "$started" ]; }; then
            busy="серверы погашены под обновление"
        fi
    fi
    if [ -n "$busy" ]; then
        if [ "${FORCE:-0}" = "1" ]; then
            warn "Идёт обновление CS2 ($busy), но задан FORCE=1 — продолжаю."
            warn "Игровые серверы могут остаться выключенными, поднимите их вручную."
        else
            die "Прямо сейчас идёт обновление CS2 ($busy).
       Прервать = оставить игровые серверы выключенными.
       Подождите 3-15 минут. Следить: sudo journalctl -u $svc -f"
        fi
    fi

    # --- качаем ---
    $SUDO apt-get install -y -qq curl ca-certificates tar rsync >/dev/null 2>&1 || true
    command -v rsync >/dev/null 2>&1 || die "Нужен rsync: sudo apt-get install -y rsync"

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
        || die "Не удалось скачать $url_base/$ASSET — сервис не тронут."

    if curl -fsSL --retry 3 -o "$tmp/$ASSET.sha256" "$url_base/$ASSET.sha256" 2>/dev/null; then
        ( cd "$tmp" && sha256sum -c --status "$ASSET.sha256" ) \
            || die "Контрольная сумма не сошлась — обновление отменено, сервис не тронут."
        ok "Контрольная сумма совпала."
    fi

    mkdir -p "$tmp/new"
    tar -xzf "$tmp/$ASSET" -C "$tmp/new" --strip-components=1 || die "Архив не распаковался."
    local new; new="$(cat "$tmp/new/VERSION" 2>/dev/null || echo "?")"

    if [ "$cur" = "$new" ] && [ "${FORCE:-0}" != "1" ]; then
        ok "Уже стоит последняя версия ($cur) — делать нечего."
        return 0
    fi
    info "Обновляем: $cur → $new"

    # --- стоп ---
    # Обязательно ДО подмены файлов: bash читает выполняющийся скрипт с диска
    # по смещению, подмена start.sh на живом сервисе выполнит обрывок строки.
    local was_active=0
    if $SUDO systemctl is-active --quiet "$svc"; then
        was_active=1; info "Останавливаем сервис..."; $SUDO systemctl stop "$svc"
    else
        warn "Сервис не был запущен."
    fi

    # --- бэкап и подмена ---
    local backup="$dir.backup-$(date +%Y%m%d-%H%M%S)"
    $SUDO cp -a "$dir" "$backup"
    info "Бэкап: $backup"

    # systemd латчит юнит в failed после StartLimitBurst (5) рестартов за
    # StartLimitIntervalSec (10 с). Сломанная версия выжигает лимит за доли
    # секунды, и следующий `systemctl start` — уже для откаченной, РАБОЧЕЙ
    # версии — получает "Start request repeated too quickly". Поэтому перед
    # каждым стартом счётчик сбрасываем.
    start_service() {
        $SUDO systemctl reset-failed "$svc" 2>/dev/null || true
        $SUDO systemctl start "$svc" 2>/dev/null || true
    }

    # `is-active` сразу после старта ничего не доказывает: Type=simple активен
    # мгновенно, а Restart=always поднимает упавший процесс обратно — круг
    # падений тоже читается как active. Ждём и сверяем счётчик рестартов:
    # после reset-failed он растёт только если процесс успел упасть.
    service_healthy() {
        sleep 12
        $SUDO systemctl is-active --quiet "$svc" || return 1
        local n
        n="$($SUDO systemctl show -p NRestarts --value "$svc" 2>/dev/null || echo 0)"
        [ "${n:-0}" -eq 0 ]
    }

    # Всегда возвращает 0 и сама печатает итог. Ненулевой код отсюда убил бы
    # update.sh под `set -e` прямо посреди отката — ровно это и происходило,
    # когда завершающий `systemctl start` спотыкался о выжженный лимит:
    # ни лога, ни объяснения, сервис лежит.
    rollback() {
        cd /   # иначе rm -rf снесёт каталог, в котором мы стоим
        if ! { $SUDO rm -rf "$dir" && $SUDO mv "$backup" "$dir"; }; then
            warn "НЕ УДАЛОСЬ вернуть бэкап! Он лежит здесь: $backup"
            return 0
        fi
        [ "$was_active" -eq 1 ] || { info "Файлы возвращены на $cur, сервис оставлен выключенным."; return 0; }
        start_service
        if $SUDO systemctl is-active --quiet "$svc"; then
            ok "Откат выполнен, сервис работает на версии $cur."
        else
            warn "Сервис не поднялся даже после отката. Поднимите вручную:"
            warn "  sudo systemctl reset-failed $svc && sudo systemctl start $svc"
        fi
        return 0
    }

    # --delete убирает файлы, удалённые в новой версии; .env и logs/ сохраняем.
    # --checksum обязателен: по умолчанию rsync решает, менялся ли файл, по паре
    # «размер + mtime». VERSION у всех релизов одной длины, и при совпадении
    # меток времени файл молча не переносился бы, а rsync вернул бы успех.
    $SUDO rsync -a --checksum --delete --exclude='.env' --exclude='logs/' "$tmp/new/" "$dir/" || {
        warn "Подмена файлов не удалась, возвращаю бэкап..."
        rollback
        die "Обновление прервано, см. сообщения выше."
    }
    $SUDO chmod +x "$dir"/*.sh

    # Проверяем результат на диске, а не код возврата rsync: рапортовать об
    # успешном обновлении, не убедившись в нём, — худший из возможных исходов.
    local applied
    applied="$($SUDO cat "$dir/VERSION" 2>/dev/null || echo '')"
    if [ "$applied" != "$new" ]; then
        warn "После подмены на диске версия '${applied:-нет файла VERSION}', ожидалась '$new'."
        warn "Возвращаю бэкап..."
        rollback
        die "Обновление прервано, см. сообщения выше."
    fi
    ok "Файлы обновлены до $new"

    # --- .env ---
    cd "$dir"
    if [ -f .env ]; then
        local mode; mode="$(stat -c %a .env)"
        if [ "$mode" != "600" ]; then
            $SUDO chmod 600 .env
            ok "Права на .env исправлены: $mode → 600 (в нём пароль Steam и токены)."
        fi
    else
        warn ".env не найден — сервис не запустится. Настройте: sudo $dir/configure.sh"
    fi

    # --- проверка ---
    info "Проверяем связь с панелью..."
    if $SUDO ./test-pelican.sh >/dev/null 2>&1; then
        ok "Панель отвечает, ключи рабочие."
    else
        warn "Проверка панели нашла ошибки. Подробности: sudo $dir/test-pelican.sh"
        warn "Сервис поднимаю: файлы игры обновит, серверы гасить не сможет."
    fi

    # --- запуск ---
    if [ "$was_active" -eq 1 ]; then
        info "Запускаем сервис..."
        start_service
        if service_healthy; then
            ok "Сервис $svc работает."
        else
            warn "Сервис не поднялся на новой версии, откатываю на $cur..."
            # Журнал снимаем ДО отката: после него последние строки будут уже
            # от перезапуска старой версии и спрячут настоящую причину сбоя.
            $SUDO journalctl -u "$svc" -n 30 --no-pager >&2
            $SUDO systemctl stop "$svc" 2>/dev/null || true
            rollback
            die "Обновление прервано, см. сообщения выше."
        fi
    else
        info "Сервис не был запущен, оставляю выключенным: sudo systemctl start $svc"
    fi

    cat >&2 <<TXT

$(printf '%s' "$P")${GREEN}Обновлено: $cur → $new${NC}

  Лог:    sudo journalctl -u $svc -f
  Бэкап:  $backup
  Откат:  curl -fsSL https://raw.githubusercontent.com/$REPO/master/update.sh | sudo VERSION=$cur bash

TXT
}

cs2_update "$@"
