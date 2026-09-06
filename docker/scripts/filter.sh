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

handle_server_output() {
    local line="$1"
    [[ -z "$line" ]] && { printf '%s\n' "$line"; return; }

    # Если фильтр отключён, просто выводим
    if [ "${ENABLE_FILTER:-0}" != "1" ]; then
        printf '%s\n' "$line"
        return
    fi

    local blocked=false
    local modified_line="$line"

    # Маскируем GSLT буквальной подстановкой. Раньше токен клался в
    # REGEX_PATTERNS и подставлялся через sed -E "s/$regex/.../" — спецсимвол
    # в значении ломал sed или менял смысл выражения.
    if [ -n "${STEAM_ACC:-}" ]; then
        modified_line="${modified_line//"$STEAM_ACC"/********}"
    fi

    # 1) Exact matchЫ
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
            log_message "Заблокированная строка (PREVIEW): $modified_line" "warning"
        fi
        # В консоль не выводим
    else
        printf '%s\n' "$modified_line"
    fi
}
