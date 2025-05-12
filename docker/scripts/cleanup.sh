#!/bin/bash
set -Eeuo pipefail

source /utils/logging.sh
trap 'handle_error "$LINENO" "$BASH_COMMAND"' ERR

# ------------------------------------------------------------------------------
#  Файл cleanup.sh — отвечает за очистку старых файлов (демо, логи и т.д.)
# ------------------------------------------------------------------------------

# Проверка файловой системы (достаточно ли места)
check_filesystem() {
    local dir="$1"
    local required_space=1048576  # ~1ГБ в килобайтах

    local fs_info
    if ! fs_info="$(df -k "$dir" 2>/dev/null | tail -n 1)"; then
        log_message "Не удалось получить информацию о файловой системе для: $dir" "error"
        return 1
    fi

    local available
    available="$(echo "$fs_info" | awk '{print $4}')"
    if [[ ! "$available" =~ ^[0-9]+$ ]]; then
        log_message "Некорректные данные о доступном месте на диске." "error"
        return 1
    fi

    if [ "$available" -lt "$required_space" ]; then
        log_message "Внимание: на диске осталось меньше 1ГБ свободного места." "warning"
    fi

    return 0
}

# Форматирование размера (байты → человекочитаемый формат)
format_size() {
    local size="$1"

    # Проверяем, есть ли команда bc (по желанию)
    if ! command -v bc &>/dev/null; then
        log_message "Внимание: bc не установлена. Размер будет выведен как целое число." "warning"
        echo "${size} B"
        return 0
    fi

    if [[ ! "$size" =~ ^[0-9]+$ ]]; then
        echo "0 B"
        return 1
    fi

    if [ "$size" -ge 1073741824 ]; then
        printf "%.2f GB" "$(bc <<< "scale=2; $size/1073741824")"
    elif [ "$size" -ge 1048576 ]; then
        printf "%.2f MB" "$(bc <<< "scale=2; $size/1048576")"
    elif [ "$size" -ge 1024 ]; then
        printf "%.2f KB" "$(bc <<< "scale=2; $size/1024")"
    else
        printf "%d B" "$size"
    fi
}

# Основная функция очистки
cleanup() {
    log_message "Запуск процедуры очистки..." "running"

    if [ -z "${GAME_DIRECTORY:-}" ]; then
        log_message "Не установлена переменная окружения GAME_DIRECTORY" "error"
        return 1
    fi

    if [ ! -d "$GAME_DIRECTORY" ]; then
        log_message "Указанная директория GAME_DIRECTORY не существует: $GAME_DIRECTORY" "error"
        return 1
    fi

    # Проверяем дисковое пространство
    if ! check_filesystem "$GAME_DIRECTORY"; then
        log_message "Проверка файловой системы не пройдена." "error"
        return 1
    fi

    # Интервалы (в часах) — для -mmin переводим часы в минуты
    local BACKUP_ROUND_PURGE_INTERVAL=24
    local DEMO_PURGE_INTERVAL=168
    local CSS_JUNK_PURGE_INTERVAL=72
    local ACCELERATOR_DUMP_PURGE_INTERVAL=168

    # Если OUTPUT_DIR не задан, по умолчанию берём GAME_DIRECTORY
    local ACCELERATOR_DUMPS_DIR="${OUTPUT_DIR:-$GAME_DIRECTORY}/AcceleratorCS2/dumps"

    # Статистические счётчики
    declare -A stats=(
        ["backup_rounds"]=0
        ["demos"]=0
        ["css_logs"]=0
        ["accelerator_logs"]=0
        ["accelerator_dumps"]=0
    )

    local start_time="$(date +%s)"
    local total_size=0
    local deleted_count=0

    # Универсальная функция удаления одного файла
    log_deletion() {
        local file="$1"
        local raw_category="$2"

        # Удаляем пробелы и переносы вокруг названия категории
        local category
        category="$(echo "$raw_category" | xargs)"

        if [ ! -f "$file" ]; then
            log_message "Файл не найден: $file" "warning"
            return 1
        fi

        # Узнаём размер
        local size
        if ! size="$(stat -c %s "$file" 2>/dev/null)"; then
            size=0
        fi

        if rm -f "$file"; then
            total_size=$(( total_size + size ))

            # Безопасное инкрементирование
            stats[$category]=$(( ${stats[$category]:-0} + 1 ))
            deleted_count=$(( deleted_count + 1 ))

            log_message "Удалён файл ($category): ${file##*/} (освобождено $(format_size "$size"))" "debug"
        else
            log_message "Не удалось удалить файл: $file" "error"
        fi
    }

    # Ищем и удаляем backup_round*.txt, *.dem, и логи CounterStrikeSharp
    while IFS= read -r -d '' file; do
        if [[ "$file" == *"backup_round"* ]]; then
            log_deletion "$file" "backup_rounds"
        elif [[ "$file" == *.dem ]]; then
            log_deletion "$file" "demos"
        elif [[ "$file" == */addons/counterstrikesharp/logs/* ]]; then
            log_deletion "$file" "css_logs"
        fi
    done < <(find "$GAME_DIRECTORY" \( \
        -name "backup_round*.txt" -mmin "+$((BACKUP_ROUND_PURGE_INTERVAL*60))" -o \
        -name "*.dem" -mmin "+$((DEMO_PURGE_INTERVAL*60))" -o \
        \( -path "*/addons/counterstrikesharp/logs/*.txt" -mmin "+$((CSS_JUNK_PURGE_INTERVAL*60))" \) \
        \) -print0 2>/dev/null)

    # Отдельная очистка Accelerator
    if [ -d "$ACCELERATOR_DUMPS_DIR" ]; then
        while IFS= read -r -d '' file; do
            if [[ "$file" == *.dmp.txt ]]; then
                log_deletion "$file" "accelerator_logs"
            else
                log_deletion "$file" "accelerator_dumps"
            fi
        done < <(find "$ACCELERATOR_DUMPS_DIR" \( \
            -name "*.dmp.txt" -o -name "*.dmp" \) \
            -mmin "+$((ACCELERATOR_DUMP_PURGE_INTERVAL*60))" -print0 2>/dev/null)
    fi

    local end_time="$(date +%s)"
    local duration=$(( end_time - start_time ))

    # Итоговый отчёт
    if (( deleted_count > 0 )); then
        log_message "Очистка завершена! Освобождено $(format_size "$total_size") за счёт удаления $deleted_count файлов за $duration секунд(ы)." "success"
        # Дополнительно выводим статистику по категориям
        for category in "${!stats[@]}"; do
            if (( stats[$category] > 0 )); then
                log_message " - $category: ${stats[$category]} файл(ов) удалено" "debug"
            fi
        done
    else
        log_message "Очистка завершена. Нечего удалять." "success"
    fi

    return 0
}
