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
#   INSECURE=1    обновлять без файла .sha256 (только для локальных тестов)
#
# Этот же скрипт лежит в каталоге установки: его ночью запускает таймер
# автообновления (см. autoupdate.sh) — уже из опубликованного релиза.
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
    # Признак установки — не просто start.sh: у чужого сервиса он тоже бывает,
    # и update.sh остановил бы его и переписал каталог через rsync --delete.
    is_install_dir() { [ -f "$1/start.sh" ] && [ -f "$1/utils/managerPelican.sh" ]; }

    local unit="" dir="${INSTALL_DIR:-}" u d
    if [ -n "$dir" ]; then
        unit="$(grep -rls "WorkingDirectory=$dir\$" /etc/systemd/system/*.service 2>/dev/null | head -n1 || true)"
    else
        while IFS= read -r u; do
            d="$(grep -oP '^WorkingDirectory=\K.*' "$u" | head -n1 || true)"
            if [ -n "$d" ] && is_install_dir "$d"; then unit="$u"; dir="$d"; break; fi
        done < <(grep -ls 'ExecStart=.*/start\.sh' /etc/systemd/system/*.service 2>/dev/null || true)
    fi
    [ -n "$dir" ] && [ -d "$dir" ] || die "Не нашёл установку CS2 Updater.
       Укажите явно: curl ... | sudo INSTALL_DIR=/opt/cs2-updater bash"
    is_install_dir "$dir" || die "В $dir нет start.sh и utils/managerPelican.sh — это не каталог CS2 Updater."

    local svc; svc="$(basename "${unit:-cs2-updater.service}")"
    local cur;  cur="$($SUDO cat "$dir/VERSION" 2>/dev/null || echo "неизвестна")"
    info "Каталог: $dir"
    info "Сервис:  $svc"
    info "Версия:  $cur"

    # --- не идёт ли прямо сейчас обновление CS2 ---
    # Убить updater посреди цикла = оставить игровые серверы выключенными:
    # он их уже погасил, а поднять обратно уже не успеет.
    # CYCLE_LOCK держит start.sh весь цикл: от оповещения игроков до запуска
    # серверов. Путь обязан совпадать с CYCLE_LOCK в service/start.sh.
    local cycle_lock="/run/cs2-updater-cycle.lock"
    local busy=""
    # -x: по имени процесса, а не по тексту командной строки. С -f проверку
    # «занимал» любой процесс со словом steamcmd в аргументах — `tail -f
    # .../steamcmd/...` у админа или даже ssh-команда с grep — и ночное
    # автообновление отказывалось работать.
    if pgrep -x steamcmd >/dev/null 2>&1; then
        busy="работает SteamCMD"
    elif [ -e "$cycle_lock" ] && ! flock -n "$cycle_lock" true 2>/dev/null; then
        busy="идёт цикл обновления CS2"
    else
        # Для установок старше лока (до v1.2.6): видит только фазу, когда
        # серверы уже погашены, — отсчёт для игроков она пропускает.
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
    # apt — только если чего-то не хватает: при ночном запуске по таймеру
    # apt-get каждый раз брал бы блокировку dpkg и мешал unattended-upgrades.
    if ! command -v rsync >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
        $SUDO apt-get install -y -qq curl ca-certificates tar rsync >/dev/null 2>&1 || true
    fi
    command -v rsync >/dev/null 2>&1 || die "Нужен rsync: sudo apt-get install -y rsync"

    # «latest» превращаем в конкретный тег ОДИН раз. Архив и .sha256 по двум
    # отдельным адресам .../releases/latest/download/ сразу после выхода релиза
    # приходили от РАЗНЫХ версий (GitHub ещё отдавал прежний «latest» на один из
    # них), и сумма не сходилась.
    resolve_latest() {
        local u
        u="$(curl -fsSIL -o /dev/null -w '%{url_effective}' --retry 3 --connect-timeout 15 \
            "https://github.com/$REPO/releases/latest" 2>/dev/null || true)"
        u="${u##*/}"
        [[ "$u" =~ ^v[0-9][0-9A-Za-z.-]*$ ]] && printf '%s' "$u"
    }

    # Управляющие символы вырезаем (чужой ответ не должен рисовать по терминалу),
    # кириллицу оставляем: заглушки провайдеров обычно на русском.
    # Почему сумма не сошлась: две разные версии, оборванная закачка или вместо
    # файла пришла чужая страница (прокси, заглушка провайдера вместо GitHub)
    explain_checksum() {
        local want got
        want="$(head -c 300 "$tmp/$ASSET.sha256" | LC_ALL=C tr -d '\000-\011\013-\037\177' | head -n1)"
        got="$(sha256sum "$tmp/$ASSET" | cut -d' ' -f1)"
        warn "  ожидалась: ${want%% *}"
        warn "  получена:  $got ($(stat -c %s "$tmp/$ASSET") байт)"
        if [[ ! "${want%% *}" =~ ^[0-9a-f]{64}$ ]]; then
            warn "  Вместо файла суммы пришло: «${want:0:100}»"
            warn "  Похоже на заглушку прокси или блокировку GitHub по пути к этому серверу."
        elif ! gzip -t "$tmp/$ASSET" 2>/dev/null; then
            warn "  Архив — не gzip: закачку подменили или оборвали по пути. Начало файла:"
            warn "  «$(head -c 100 "$tmp/$ASSET" | LC_ALL=C tr -d '\000-\037\177')»"
        else
            warn "  Версия внутри архива: $(tar -xOzf "$tmp/$ASSET" --wildcards '*/VERSION' 2>/dev/null || echo '?')"
        fi
    }

    # BASE_URL позволяет подставить зеркало или локальный каталог (используется в тестах)
    local url_base="${BASE_URL:-}"
    if [ -z "$url_base" ]; then
        if [ "$VERSION" = "latest" ]; then
            VERSION="$(resolve_latest)" || die "Не удалось узнать последнюю версию на GitHub — сервис не тронут.
       Укажите версию явно: curl ... | sudo VERSION=v1.2.12 bash"
        fi
        url_base="https://github.com/$REPO/releases/download/$VERSION"
    fi

    local tmp; tmp="$(mktemp -d)"
    # EXIT, а не RETURN: die делает exit, и RETURN-трап тогда не срабатывал —
    # каждая неудачная ночная попытка оставляла бы мусор в /tmp.
    # shellcheck disable=SC2064
    trap "rm -rf '$tmp'" EXIT

    info "Качаем релиз ($VERSION)..."
    curl -fsSL --retry 3 --connect-timeout 15 -o "$tmp/$ASSET" "$url_base/$ASSET" \
        || die "Не удалось скачать $url_base/$ASSET — сервис не тронут."

    if curl -fsSL --retry 3 -o "$tmp/$ASSET.sha256" "$url_base/$ASSET.sha256" 2>/dev/null; then
        if ! ( cd "$tmp" && sha256sum -c --status "$ASSET.sha256" ); then
            warn "Контрольная сумма не сошлась ($url_base):"
            explain_checksum
            die "Обновление отменено, сервис не тронут."
        fi
        ok "Контрольная сумма совпала."
    elif [ "${INSECURE:-0}" = "1" ]; then
        warn "Файла с контрольной суммой нет, а задан INSECURE=1 — обновляю без проверки."
    else
        # Раньше тут было молчаливое «ставим так»: ночью, от root
        die "Нет файла с контрольной суммой — обновление отменено, сервис не тронут.
       Для локальных тестов через BASE_URL: INSECURE=1"
    fi

    mkdir -p "$tmp/new"
    # --no-same-owner: владелец из архива не переносится (релизы до v1.2.11 — uid 1001)
    tar -xzf "$tmp/$ASSET" -C "$tmp/new" --strip-components=1 --no-same-owner || die "Архив не распаковался."
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
    # 40 с: сразу после старта идёт первая проверка версии, у её curl таймаут
    # 30 с. Код, который ломается после этой проверки, должен успеть упасть.
    service_healthy() {
        sleep 40
        $SUDO systemctl is-active --quiet "$svc" || return 1
        local n
        n="$($SUDO systemctl show -p NRestarts --value "$svc" 2>/dev/null || echo 0)"
        [ "${n:-0}" -eq 0 ]
    }

    # Всегда возвращает 0 и сама печатает итог. Ненулевой код отсюда убил бы
    # update.sh под `set -e` прямо посреди отката — ровно это и происходило,
    # когда завершающий `systemctl start` спотыкался о выжженный лимит:
    # ни лога, ни объяснения, сервис лежит.
    # С автообновлением бэкапы копились бы бесконечно. Три последних —
    # достаточно, чтобы откатиться, если плохую версию заметили не сразу.
    prune_backups() {
        local old
        old="$(ls -1d "$dir".backup-* 2>/dev/null | sort | head -n -3 || true)"
        [ -z "$old" ] || { printf '%s\n' "$old" | xargs -r $SUDO rm -rf; info "Старые бэкапы удалены, оставлены 3 последних."; }
    }

    rollback() {
        cd /   # иначе rm -rf снесёт каталог, в котором мы стоим
        if ! { $SUDO rm -rf "$dir" && $SUDO mv "$backup" "$dir"; }; then
            warn "НЕ УДАЛОСЬ вернуть бэкап! Он лежит здесь: $backup"
            return 0
        fi
        # бэкап версии до v1.2.11 мог принести файлы с владельцем uid 1001
        $SUDO chown -R root:root "$dir" 2>/dev/null || true
        $SUDO chmod -R go-w "$dir" 2>/dev/null || true
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
    # Скрипты выполняет root (сервис и ночной таймер) — писать в них может только
    # root. rsync -a переносит владельца распаковки, а до v1.2.11 архив нёс uid 1001.
    $SUDO chown -R root:root "$dir"
    $SUDO chmod -R go-w "$dir"
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

    # Оповещение в Discord через установленный notify.sh. Отдельным bash от root:
    # .env с вебхуком доступен только root, а update.sh могли запустить через sudo.
    # Любой сбой оповещения обновлению не мешает.
    notify_installed() {
        [ -f "$dir/utils/notify.sh" ] || return 0
        # shellcheck disable=SC2016
        $SUDO bash -c 'cd "$1" && source ./utils/logging.sh && source ./.env && source ./utils/notify.sh && shift && notify "$@"' \
            _ "$dir" "$@" >/dev/null 2>&1 || true
    }

    # --- запуск ---
    if [ "$was_active" -eq 1 ]; then
        info "Запускаем сервис..."
        start_service
        if service_healthy; then
            ok "Сервис $svc работает."
            notify_installed ok "CS2 Updater обновлён: $cur → $new" "Сервис $svc работает."
            prune_backups
        else
            warn "Сервис не поднялся на новой версии, откатываю на $cur..."
            # Журнал снимаем ДО отката: после него последние строки будут уже
            # от перезапуска старой версии и спрячут настоящую причину сбоя.
            $SUDO journalctl -u "$svc" -n 30 --no-pager >&2
            # До отката: в старой версии notify.sh может не быть
            notify_installed error "CS2 Updater: $new не поднялся, откат на $cur" \
                "Сервис $svc падал на новой версии. Журнал: journalctl -u $svc -n 50"
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
