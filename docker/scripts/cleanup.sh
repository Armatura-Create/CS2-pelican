#!/bin/bash
source /utils/logging.sh

# Функция проверки файловой системы
check_filesystem() {
    local dir="$1"
    # Минимум 1 ГБ свободного места (в килобайтах)
    local required_space=1048576  

    # Пытаемся получить информацию о файловой системе
    local fs_info
    if ! fs_info=$(df -k "$dir" 2>/dev/null | tail -n 1); then
        log_message "Не удалось получить информацию о файловой системе для $dir" "error"
        return 1
    fi

    # Безопасно парсим доступное пространство
    local available
    available=$(echo "$fs_info" | awk '{print $4}')
    if [[ ! "$available" =~ ^[0-9]+$ ]]; then
        log_message "Получены некорректные данные о доступном месте на диске" "error"
        return 1
    fi

    if [ "$available" -lt "$required_space" ]; then
        log_message "Внимание: на диске меньше 1ГБ свободного места" "warning"
    fi

    return 0
}

# Функция форматирования размера (байты в KB, MB, GB)
format_size() {
    local size="$1"
    if [[ ! "$size" =~ ^[0-9]+$ ]]; then
        echo "0 B"
        return 1
    fi

    if [ "$size" -ge 1073741824 ]; then
        # Более 1ГБ
        printf "%.2f GB" "$(echo "scale=2; $size/1073741824" | bc)"
    elif [ "$size" -ge 1048576 ]; then
        # Более 1МБ
        printf "%.2f MB" "$(echo "scale=2; $size/1048576" | bc)"
    elif [ "$size" -ge 1024 ]; then
        # Более 1КБ
        printf "%.2f KB" "$(echo "scale=2; $size/1024" | bc)"
    else
        # Меньше 1КБ
        printf "%d B" "$size"
    fi
}

# Основная функция очистки (cleanup)
cleanup() {
    log_message "Запуск процедуры очистки..." "running"

    # Проверяем, что переменная GAME_DIRECTORY установлена
    if [ -z "$GAME_DIRECTORY" ]; then
        log_message "Переменная GAME_DIRECTORY не установлена" "error"
        return 1
    fi

    # Проверяем, что каталог действительно существует
    if [ ! -d "$GAME_DIRECTORY" ]; then
        log_message "GAME_DIRECTORY не существует: $GAME_DIRECTORY" "error"
        return 1
    fi

    # Перед началом убеждаемся, что на диске достаточно места
    if ! check_filesystem "$GAME_DIRECTORY"; then
        log_message "Не удалось выполнить проверку файловой системы" "error"
        return 1
    fi

    # Интервалы (в часах) для разных категорий файлов
    local BACKUP_ROUND_PURGE_INTERVAL=24
    local DEMO_PURGE_INTERVAL=168
    local CSS_JUNK_PURGE_INTERVAL=72
    local ACCELERATOR_DUMP_PURGE_INTERVAL=168
    local ACCELERATOR_DUMPS_DIR="${OUTPUT_DIR:-$GAME_DIRECTORY}/AcceleratorCS2/dumps"

    # Статистика, сколько файлов удалено
    declare -A stats=(
        ["backup_rounds"]=0
        ["demos"]=0
        ["css_logs"]=0
        ["accelerator_logs"]=0
        ["accelerator_dumps"]=0
    )

    local start_time
    start_time=$(date +%s)
    local total_size=0
    local deleted_count=0

    # Вспомогательная функция для удаления файла с логированием
    log_deletion() {
        local file="$1"
        local category="$2"

        # Сначала проверяем, что файл действительно существует
        if [ ! -f "$file" ]; then
            log_message "Файл не найден: $file" "warning"
            return 1
        fi

        # Узнаём размер файла
        local size
        size=$(stat -f %z "$file" 2>/dev/null || stat -c %s "$file" 2>/dev/null)

        if [ $? -ne 0 ] || [[ ! "$size" =~ ^[0-9]+$ ]]; then
            log_message "Не удалось определить размер файла: $file" "warning"
            size=0
        fi

        # Пытаемся удалить файл
        if rm -f "$file"; then
            # Успешно удалили, обновляем статистику
            total_size=$((total_size + size))
            ((stats[$category]++))
            ((deleted_count++))
            log_message "Удалён файл категории '$category': ${file##*/} ($(format_size "$size"))" "debug"
        else
            log_message "Не удалось удалить файл: $file" "error"
        fi
    }

    # Поиск и удаление backup_round, демо-файлов и junk-логов
    while IFS= read -r -d '' file; do
        if [[ "$file" == *"backup_round"* ]]; then
            # Файлы с backup_round
            log_deletion "$file" "backup_rounds"
        elif [[ "$file" == *.dem ]]; then
            # Демо-файлы
            log_deletion "$file" "demos"
        elif [[ "$file" == */addons/counterstrikesharp/logs/* ]]; then
            # Логи CounterStrikeSharp
            log_deletion "$file" "css_logs"
        fi
    done < <(find "$GAME_DIRECTORY" \( \
        -name "backup_round*.txt" -mmin "+$((BACKUP_ROUND_PURGE_INTERVAL*60))" -o \
        -name "*.dem" -mmin "+$((DEMO_PURGE_INTERVAL*60))" -o \
        \( -path "*/addons/counterstrikesharp/logs/*.txt" -mmin "+$((CSS_JUNK_PURGE_INTERVAL*60))" \) \
        \) -print0 2>/dev/null)

    # Отдельно обрабатываем логи Accelerator
    if [ -d "$ACCELERATOR_DUMPS_DIR" ]; then
        while IFS= read -r -d '' file; do
            if [[ "$file" == *.dmp.txt ]]; then
                # Текстовые дампы Accelerator
                log_deletion "$file" "accelerator_logs"
            else
                # Бинарные дампы .dmp
                log_deletion "$file" "accelerator_dumps"
            fi
        done < <(find "$ACCELERATOR_DUMPS_DIR" \( \
            -name "*.dmp.txt" -o \
            -name "*.dmp" \
            \) -mmin "+$((ACCELERATOR_DUMP_PURGE_INTERVAL*60))" -print0 2>/dev/null)
    fi

    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))

    # Итоговый отчёт
    if ((deleted_count > 0)); then
        log_message "Очистка завершена! Освобождено $(format_size "$total_size") за счёт $deleted_count файлов за $duration секунд(ы)." "success"
        # Дополнительно выводим статистику по категориям
        for category in "${!stats[@]}"; do
            if ((stats[$category] > 0)); then
                log_message "- $category: ${stats[$category]} файл(ов)" "debug"
            fi
        done
    else
        log_message "Очистка завершена. Файлы для удаления не найдены." "success"
    fi

    return 0
}
