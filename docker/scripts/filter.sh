#!/bin/bash
set -Eeuo pipefail

source /utils/logging.sh
trap 'handle_error "$LINENO" "$BASH_COMMAND"' ERR

# Глобальные ассоциативные массивы для шаблонов
declare -gA EXACT_PATTERNS=()
declare -gA REGEX_PATTERNS=()

setup_message_filter() {
    if [ "${ENABLE_FILTER:-0}" != "1" ]; then
        log_message "Фильтр консоли отключён." "running"
        return 0
    fi

    # Создаём дефолтный mute_messages.cfg, если он отсутствует
    if [ ! -f "/home/container/game/mute_messages.cfg" ]; then
        cat > "/home/container/game/mute_messages.cfg" <<'EOL'
# Mute Messages Configuration File
# Lines starting with @ => exact match
# Otherwise it's a full regex.
# Example exact: @Certificate expires
# Example regex: .*Certificate expires.*

.*Certificate expires.*
EOL
        log_message "Создан дефолтный /home/container/game/mute_messages.cfg" "running"
    fi


    local pattern_count=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Пропускаем комментарии / пустые
        [[ $line =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// }" ]] && continue

        if [[ $line == @* ]]; then
            # Exact match
            local exact="${line#@}"
            EXACT_PATTERNS["$exact"]="1"
        else
            # Regex
            REGEX_PATTERNS["$line"]="1"
        fi
        pattern_count=$((pattern_count + 1))
    done < "/home/container/game/mute_messages.cfg"

    log_message "Фильтр сообщений активирован. Загрузлено $pattern_count шаблон(ов)." "running"
}

# Команды с секретом в аргументе. Сервер возвращает эхом всё, что набрано в
# консоли, и `rcon_password X` из панели уходил бы в вывод — а с ним в логи
# Docker и в отчёты о падениях на хосте. Значение — строка в кавычках или одно
# слово; `= ` между ними (так печатается значение квара) тоже учитываем.
SECRET_CMD_RE='^(.*(rcon_password|sv_password|sv_setsteamaccount|sv_downloadurl_password)"?[[:space:]]*=?[[:space:]]*)("[^"]*"|[^[:space:]"]+)(.*)$'

# Маскирует секреты в строке: GSLT буквальной подстановкой (раньше токен шёл в
# sed -E, и спецсимвол в значении ломал выражение) и аргументы секретных
# команд. Результат — в MASKED_LINE: без подоболочки на каждую строку.
mask_secrets() {
    MASKED_LINE="$1"
    if [ -n "${STEAM_ACC:-}" ]; then
        MASKED_LINE="${MASKED_LINE//"$STEAM_ACC"/********}"
    fi
    # дешёвая проверка до регулярного выражения: у всех команд есть эти куски
    if [[ "$MASKED_LINE" == *_password* || "$MASKED_LINE" == *setsteamaccount* ]] \
        && [[ "$MASKED_LINE" =~ $SECRET_CMD_RE ]]; then
        MASKED_LINE="${BASH_REMATCH[1]}********${BASH_REMATCH[4]}"
    fi
}

handle_server_output() {
    local line="$1"
    [[ -z "$line" ]] && { printf '\n'; return; }

    # Секреты маскируются ВСЕГДА. Раньше — только при включённом фильтре.
    mask_secrets "$line"

    if [ "${ENABLE_FILTER:-0}" != "1" ]; then
        printf '%s\n' "$MASKED_LINE"
        return
    fi

    local blocked=false

    # 1) Exact match
    for exact_pattern in "${!EXACT_PATTERNS[@]}"; do
        if [[ "$line" == "$exact_pattern" ]]; then
            blocked=true
            break
        fi
    done

    # 2) Regex-совпадения (если не заблокировано exact-совпадением)
    if [ "$blocked" = false ]; then
        for regex in "${!REGEX_PATTERNS[@]}"; do
            if [[ "$line" =~ $regex ]]; then
                blocked=true
                break
            fi
        done
    fi

    # 3) Вывод
    if [ "$blocked" = true ]; then
        if [ "${FILTER_PREVIEW_MODE:-0}" = "1" ]; then
            # В режиме превью показываем строку, чтобы можно было проверить фильтр
            log_message "Заблокированная строка (PREVIEW): $MASKED_LINE" "warning"
        fi
        # В консоль не выводим
    else
        printf '%s\n' "$MASKED_LINE"
    fi
}
