#!/bin/bash
source /utils/logging.sh

setup_message_filter() {
    if [ "${ENABLE_FILTER:-0}" != "1" ]; then
        log_message "Фильтр отключен. Сообщения не будут заблокированы." "running"
        return 0
    fi

    # Create default config if not exists
    if [ ! -f "/home/container/game/mute_messages.cfg" ]; then
        cat > "/home/container/game/mute_messages.cfg" <<'EOL'
# Mute Messages Configuration File
# Lines starting with @ => exact match
# Otherwise it's a full regex.
# Example exact: @Certificate expires
# Example regex: .*Certificate expires.*

.*Certificate expires.*
EOL
        log_message "Создан дефолтный файл mute_messages.cfg" "running"
    fi

    # Pre-process patterns for better performance
    # EXACT_PATTERNS:  cтроки, которые надо проверять "==" (полное совпадение)
    # REGEX_PATTERNS:  строки, воспринимаемые как полноценные регулярки
    declare -gA EXACT_PATTERNS=()
    declare -gA REGEX_PATTERNS=()

    # (Опционально) маскируем STEAM_ACC, если хотим скрывать его
    if [ -n "${STEAM_ACC:-}" ]; then
        # Вместо блокировки — замена STEAM_ACC → "********"
        REGEX_PATTERNS["${STEAM_ACC}"]="********"
    fi

    local pattern_count=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Skip comments and empty lines
        [[ $line =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// }" ]] && continue

        # Если строка начинается с @ — это exact-матч
        if [[ $line == @* ]]; then
            # Убираем @
            local exact="${line#@}"
            # Сохраняем как ключ exact => "1"
            EXACT_PATTERNS["$exact"]="1"
        else
            # Это полноценный regex
            REGEX_PATTERNS["$line"]="1"
        fi
        ((pattern_count++))
    done < "/home/container/game/mute_messages.cfg"

    log_message "Загружено $pattern_count шаблонов фильтров (${#EXACT_PATTERNS[@]} точные, ${#REGEX_PATTERNS[@]} регулярные выражения). Измените mute_messages.cfg, чтобы добавить больше." "running"
}

handle_server_output() {
    local line="$1"
    # Early return for empty lines
    [[ -z "$line" ]] && {
        printf '%s\n' "$line"
        return
    }

    # Skip filtering if disabled
    if [ "${ENABLE_FILTER:-0}" != "1" ]; then
        printf '%s\n' "$line"
        return
    fi

    local blocked=false
    local modified_line="$line"

    ###################################################
    # 1) Exact match проверяем в первую очередь
    ###################################################
    for exact_pattern in "${!EXACT_PATTERNS[@]}"; do
        if [[ "$line" == "$exact_pattern" ]]; then
            # Полностью блокируем
            blocked=true
            break
        fi
    done

    ###################################################
    # 2) Если не заблокировано exact-совпадением:
    #    проходим по REGEX_PATTERNS
    ###################################################
    if [[ "$blocked" == false ]]; then
        for regex in "${!REGEX_PATTERNS[@]}"; do
            # Значение в массиве может быть либо "1" (значит блокировать),
            # либо какая-то строка для замены. Сейчас для простоты оставим
            # "1" = блок, любая другая = замена.
            local action="${REGEX_PATTERNS[$regex]}"

            # Проверяем совпадение через =~
            if [[ "$line" =~ $regex ]]; then
                if [[ "$action" == "1" ]]; then
                    # Блокируем
                    blocked=true
                    break
                else
                    # Значит хотим заменить найденный фрагмент на $action
                    # Для этого используем sed. Нужно аккуратно экранировать
                    # спецсимволы в replacement (action).
                    local replacement
                    replacement="$(printf '%s' "$action" | sed 's/[&/\]/\\&/g')"
                    # Заменяем все совпадения $regex на $replacement
                    # '-E' чтобы понимать синтаксис расширенных регэксп
                    modified_line="$(printf '%s' "$modified_line" | sed -E "s/$regex/$replacement/g")"
                fi
            fi
        done
    fi

    ###################################################
    # 3) Выводим результат
    ###################################################
    if [[ "$blocked" == true ]]; then
        # Если включён превью-режим, пишем в лог заблокированную строку
        if [ "${FILTER_PREVIEW_MODE:-0}" = "1" ]; then
            log_message "Заблокированное сообщение: $line" "debug"
        fi
        # И ничего не выводим в консоль
    else
        # Выводим либо заменённую строку, либо исходную
        printf '%s\n' "$modified_line"
    fi
}