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

    # Если нужно маскировать STEAM_ACC, превращаем в «********»
    if [ -n "${STEAM_ACC:-}" ]; then
        REGEX_PATTERNS["${STEAM_ACC}"]="********"
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
            local action="${REGEX_PATTERNS[$regex]}"
            if [[ "$line" =~ $regex ]]; then
                if [[ "$action" == "1" ]]; then
                    # Полный блок
                    blocked=true
                    break
                else
                    # Заменяем на action
                    local replacement
                    replacement="$(printf '%s' "$action" | sed 's/[&/\]/\\&/g')"
                    modified_line="$(printf '%s' "$modified_line" | sed -E "s/$regex/$replacement/g")"
                fi
            fi
        done
    fi

    # 3) Вывод
    if [ "$blocked" = true ]; then
        if [ "${FILTER_PREVIEW_MODE:-0}" = "1" ]; then
            # В режиме превью показываем в логах, что строка заблокирована
            log_message "Заблокированная строка (PREVIEW): $line" "debug"
        fi
        # В консоль не выводим
    else
        printf '%s\n' "$modified_line"
    fi
}
