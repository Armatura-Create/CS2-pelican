# План обновления: Универсальная функция update_addon для CounterStrikeSharp и Swiftly

**Дата создания:** 2025-12-11  
**Автор:** AI Assistant  
**Референс:** [K4ryuu/CS2-Egg](https://github.com/K4ryuu/CS2-Egg)

---

## 📋 Оглавление

1. [Текущее состояние](#текущее-состояние)
2. [Анализ K4ryuu/CS2-Egg](#анализ-k4ryuucs2-egg)
3. [Проблемы текущей реализации](#проблемы-текущей-реализации)
4. [План модификации](#план-модификации)
5. [Детальная реализация](#детальная-реализация)
6. [Обновление gameinfo.gi](#обновление-gameinfogt)
7. [Тестирование](#тестирование)
8. [Чеклист](#чеклист)

---

## 🔍 Текущее состояние

### Текущая функция `update_addon()`

**Файл:** `docker/scripts/update.sh` (строки 248-286)

**Проблемы:**
```bash
update_addon() {
    local repo="$1"
    local output_path="$2"
    local temp_subdir="$3"
    local addon_name="$4"
    
    # ... код ...
    
    # ❌ ПРОБЛЕМА: Жестко зашито для CounterStrikeSharp
    asset_url="$(echo "$api_response" | grep -oP '"browser_download_url": "\K[^"]+' | grep 'counterstrikesharp-with-runtime-linux-.*\.zip' || true)"
    
    # ❌ ПРОБЛЕМА: Всегда копирует в $OUTPUT_PATH без учета специфики
    cp -r "$temp_dir/addons/." "$output_path"
}
```

**Использование:**
```bash
# В cleanup_and_update():
update_addon "roflmuffin/CounterStrikeSharp" "$OUTPUT_DIR" "css" "CSS"
```

---

## 📊 Анализ K4ryuu/CS2-Egg

### Поддерживаемые фреймворки в K4ryuu:

Согласно [README K4ryuu/CS2-Egg](https://github.com/K4ryuu/CS2-Egg):

1. **MetaMod:Source** - Core plugin framework (required for CSS)
2. **CounterStrikeSharp** - C# plugin framework with .NET 8 runtime
3. **SwiftlyS2** - Standalone C# framework v2
4. **ModSharp** - Standalone C# platform with .NET 9 runtime

### Ключевые особенности K4ryuu:

- ✅ **Multi-Framework Support** - независимые boolean toggles
- ✅ **Auto-updates on server restart** - автоматическое обновление
- ✅ **Automatic gameinfo.gi configuration** - автоматическая настройка
- ✅ **Independent framework management** - независимое управление

### Структура gameinfo.gi в K4ryuu:

```
Game_LowViolence csgo_lv
    Game csgo/addons/metamod        ← MetaMod (если включен)
    Game csgo/addons/swiftlys2      ← Swiftly (если включен)
    Game csgo
```

**Важно:** CounterStrikeSharp НЕ добавляется в gameinfo.gi, т.к. работает через MetaMod!

---

## ⚠️ Проблемы текущей реализации

### 1. Хардкод для CounterStrikeSharp

```bash
# Строка 266 в update.sh
asset_url="$(echo "$api_response" | grep -oP '"browser_download_url": "\K[^"]+' | grep 'counterstrikesharp-with-runtime-linux-.*\.zip' || true)"
```

**Проблема:** Невозможно использовать для других фреймворков!

### 2. Отсутствие типизации аддонов

Функция не знает:
- Какой тип аддона обновляется
- Нужно ли добавлять в gameinfo.gi
- Какой паттерн файла искать

### 3. Нет управления gameinfo.gi

Текущая функция `configure_metamod()` только для MetaMod.
Нужна универсальная система для всех фреймворков.

---

## 🎯 План модификации

### Шаг 1: Создать универсальную функцию `update_addon_universal()`

**Параметры:**
1. `repo` - GitHub репозиторий (например, "roflmuffin/CounterStrikeSharp")
2. `addon_type` - Тип аддона: "css", "swiftly", "modsharp"
3. `addon_name` - Имя для версионирования (например, "CSS", "Swiftly")

**Логика:**
- Определить паттерн поиска файла по типу аддона
- Определить нужно ли обновлять gameinfo.gi
- Определить структуру распаковки

### Шаг 2: Создать конфигурацию типов аддонов

Ассоциативный массив с параметрами для каждого типа:
- Паттерн поиска файла
- Нужно ли добавлять в gameinfo.gi
- Имя папки в addons/
- Зависимости (например, CSS требует MetaMod)

### Шаг 3: Создать универсальную систему управления gameinfo.gi

Функция `manage_gameinfo_entry()` которая:
- Добавляет запись если аддон установлен
- Удаляет запись если аддон удален
- Проверяет порядок записей (MetaMod должен быть первым)

---

## 🔧 Детальная реализация

### Этап 1: Конфигурация типов аддонов

**Добавить в начало `update.sh` (после глобальных переменных, строка ~17):**

```bash
# ===========================
# Конфигурация типов аддонов
# ===========================

# Объявляем ассоциативные массивы для конфигурации
declare -A ADDON_FILE_PATTERNS=(
    ["css"]="counterstrikesharp-with-runtime-linux-.*\.zip"
    ["swiftly"]="swiftlys2-linux-v.*-with-runtimes\.zip"
    ["modsharp"]="modsharp.*linux\.zip"
)

declare -A ADDON_GAMEINFO_DIRS=(
    ["css"]=""                    # CSS не добавляется в gameinfo.gi
    ["swiftly"]="swiftlys2"       # Swiftly добавляется как csgo/addons/swiftlys2
    ["modsharp"]="modsharp"       # ModSharp добавляется как csgo/addons/modsharp
)

declare -A ADDON_REQUIRES_METAMOD=(
    ["css"]="1"        # CSS требует MetaMod
    ["swiftly"]="0"    # Swiftly standalone
    ["modsharp"]="0"   # ModSharp standalone
)
```

**Объяснение:**
- `ADDON_FILE_PATTERNS` - регулярные выражения для поиска файлов релизов
- `ADDON_GAMEINFO_DIRS` - имя папки для добавления в gameinfo.gi (пустая строка = не добавлять)
- `ADDON_REQUIRES_METAMOD` - требует ли аддон MetaMod

---

### Этап 2: Универсальная функция обновления

**Заменить функцию `update_addon()` на `update_addon_universal()` (строка ~248):**

```bash
update_addon_universal() {
    local repo="$1"
    local addon_type="$2"      # css, swiftly, modsharp
    local addon_name="$3"      # CSS, Swiftly, ModSharp
    
    # Проверка валидности типа
    if [ -z "${ADDON_FILE_PATTERNS[$addon_type]}" ]; then
        log_message "Неизвестный тип аддона: $addon_type" "error"
        return 1
    fi
    
    local temp_dir="$TEMP_DIR/$addon_type"
    mkdir -p "$OUTPUT_DIR" "$temp_dir"
    rm -rf "$temp_dir"/*
    
    # 1. Получить информацию о релизе
    log_message "Проверка обновлений для $addon_name..." "running"
    
    local api_response
    api_response="$(curl -s "https://api.github.com/repos/$repo/releases/latest")" || true
    
    if [ -z "$api_response" ]; then
        log_message "Не удалось получить информацию о релизе для $repo" "error"
        return 1
    fi
    
    # 2. Извлечь версию
    local new_version
    new_version="$(echo "$api_response" | grep -oP '"tag_name": "\K[^"]+' || true)"
    
    if [ -z "$new_version" ]; then
        log_message "Не удалось определить версию для $addon_name" "error"
        return 1
    fi
    
    # 3. Проверить необходимость обновления
    local current_version
    current_version="$(get_current_version "$addon_name")"
    
    if ! check_version "$addon_name" "$current_version" "$new_version"; then
        return 0
    fi
    
    # 4. Найти подходящий asset
    local file_pattern="${ADDON_FILE_PATTERNS[$addon_type]}"
    local asset_url
    
    # Получаем список всех browser_download_url
    local all_urls
    all_urls="$(echo "$api_response" | grep -oP '"browser_download_url": "\K[^"]+')"
    
    # Ищем URL по паттерну
    asset_url="$(echo "$all_urls" | grep -E "$file_pattern" | head -n1 || true)"
    
    if [ -z "$asset_url" ]; then
        log_message "Не найден файл для $addon_name (паттерн: $file_pattern)" "error"
        log_message "Доступные файлы:" "debug"
        echo "$all_urls" | while read -r url; do
            log_message "  - $(basename "$url")" "debug"
        done
        return 1
    fi
    
    log_message "Найден файл: $(basename "$asset_url")" "debug"
    
    # 5. Скачать и распаковать
    if handle_download_and_extract "$asset_url" "$temp_dir/download.zip" "$temp_dir" "zip"; then
        # 6. Установить аддон
        # Проверяем наличие папки addons в архиве
        if [ -d "$temp_dir/addons" ]; then
            cp -r "$temp_dir/addons/." "$OUTPUT_DIR"
            log_message "Файлы $addon_name скопированы в $OUTPUT_DIR" "debug"
        else
            log_message "Структура архива не содержит папку addons/" "error"
            return 1
        fi
        
        # 7. Обновить версию
        update_version_file "$addon_name" "$new_version"
        
        # 8. Обновить gameinfo.gi (если нужно)
        local gameinfo_dir="${ADDON_GAMEINFO_DIRS[$addon_type]}"
        if [ -n "$gameinfo_dir" ]; then
            add_gameinfo_entry "$gameinfo_dir" "$addon_name"
        fi
        
        log_message "$addon_name обновлён до версии $new_version" "success"
        return 0
    else
        log_message "Ошибка при установке $addon_name" "error"
        return 1
    fi
}
```

---

### Этап 3: Универсальная система gameinfo.gi

**Создать функции после `configure_metamod()` (строка ~428):**

```bash
# ===========================
# Управление gameinfo.gi
# ===========================

add_gameinfo_entry() {
    local addon_dir="$1"      # Например: "swiftlys2", "modsharp"
    local addon_name="$2"     # Например: "Swiftly", "ModSharp"
    
    local GAMEINFO_FILE="/home/container/game/csgo/gameinfo.gi"
    local GAMEINFO_ENTRY="			Game	csgo/addons/$addon_dir"
    
    if [ ! -f "$GAMEINFO_FILE" ]; then
        log_message "Файл gameinfo.gi не найден: $GAMEINFO_FILE" "error"
        return 1
    fi
    
    # Проверяем, есть ли уже запись
    if grep -q "Game[[:blank:]]*csgo\/addons\/$addon_dir" "$GAMEINFO_FILE"; then
        log_message "Запись $addon_name уже присутствует в gameinfo.gi" "debug"
        return 0
    fi
    
    # Добавляем запись после Game_LowViolence
    log_message "Добавляем $addon_name в gameinfo.gi..." "running"
    
    awk -v new_entry="$GAMEINFO_ENTRY" '
        BEGIN { found=0; }
        {
            if (found == 1) {
                print new_entry
                found=0
            }
            print $0
        }
        /Game_LowViolence/ { found=1 }
    ' "$GAMEINFO_FILE" > "${GAMEINFO_FILE}.tmp"
    
    if [ $? -eq 0 ]; then
        mv "${GAMEINFO_FILE}.tmp" "$GAMEINFO_FILE"
        log_message "$addon_name добавлен в gameinfo.gi" "success"
        return 0
    else
        log_message "Ошибка при обновлении gameinfo.gi для $addon_name" "error"
        rm -f "${GAMEINFO_FILE}.tmp"
        return 1
    fi
}

remove_gameinfo_entry() {
    local addon_dir="$1"      # Например: "swiftlys2", "modsharp"
    local addon_name="$2"     # Например: "Swiftly", "ModSharp"
    
    local GAMEINFO_FILE="/home/container/game/csgo/gameinfo.gi"
    
    if [ ! -f "$GAMEINFO_FILE" ]; then
        return 0
    fi
    
    # Проверяем, есть ли запись
    if ! grep -q "csgo\/addons\/$addon_dir" "$GAMEINFO_FILE"; then
        return 0
    fi
    
    log_message "Удаляем $addon_name из gameinfo.gi..." "running"
    
    # Удаляем строку с записью
    sed -i "/csgo\/addons\/$addon_dir/d" "$GAMEINFO_FILE"
    
    log_message "$addon_name удалён из gameinfo.gi" "success"
    return 0
}

verify_gameinfo_order() {
    # Проверяет правильность порядка записей в gameinfo.gi
    # MetaMod должен быть первым, потом остальные
    
    local GAMEINFO_FILE="/home/container/game/csgo/gameinfo.gi"
    
    if [ ! -f "$GAMEINFO_FILE" ]; then
        return 0
    fi
    
    # Получаем порядок записей
    local entries
    entries="$(grep -oP 'Game[[:blank:]]+csgo/addons/\K[^[:space:]]+' "$GAMEINFO_FILE" || true)"
    
    if [ -z "$entries" ]; then
        return 0
    fi
    
    log_message "Записи в gameinfo.gi:" "debug"
    echo "$entries" | while read -r entry; do
        log_message "  - $entry" "debug"
    done
    
    # Проверяем что MetaMod первый (если он есть)
    local first_entry
    first_entry="$(echo "$entries" | head -n1)"
    
    if echo "$entries" | grep -q "metamod"; then
        if [ "$first_entry" != "metamod" ]; then
            log_message "ВНИМАНИЕ: MetaMod должен быть первым в gameinfo.gi!" "warning"
            return 1
        fi
    fi
    
    return 0
}
```

---

### Этап 4: Обновление cleanup_and_update()

**Изменить функцию (строка ~222):**

```bash
cleanup_and_update() {
    # Если включена очистка, запускаем
    if [ "${CLEANUP_ENABLED:-0}" = "1" ]; then
        cleanup
    fi

    mkdir -p "$TEMP_DIR"

    # Обновление Metamod (если включено или требуется для CSS)
    if [ "${METAMOD_AUTOUPDATE:-0}" = "1" ] || \
       ([ ! -d "$OUTPUT_DIR/metamod" ] && [ "${CSS_AUTOUPDATE:-0}" = "1" ]); then
        update_metamod
    fi

    # Обновление CounterStrikeSharp (CSS)
    if [ "${CSS_AUTOUPDATE:-0}" = "1" ]; then
        # НОВЫЙ ВЫЗОВ:
        update_addon_universal "roflmuffin/CounterStrikeSharp" "css" "CSS"
    fi

    # Обновление Swiftly (SwiftlyS2)
    if [ "${SWIFTLY_AUTOUPDATE:-0}" = "1" ]; then
        update_addon_universal "swiftly-solution/swiftlys2" "swiftly" "Swiftly"
    fi

    # Обновляем server.cfg (если нужно)
    if [ "${UPDATE_CFG_FILE:-0}" = "1" ]; then
        update_server_cfg
    fi
    
    # Проверяем порядок в gameinfo.gi
    verify_gameinfo_order

    rm -rf "$TEMP_DIR"
}
```

---

### Этап 5: Обновление entrypoint.sh

**Добавить после `configure_metamod` (строка ~64):**

```bash
# Настройка MetaMod
configure_metamod

# Удаляем записи для отключенных аддонов
if [ "${SWIFTLY_AUTOUPDATE:-0}" != "1" ] && [ ! -d "$OUTPUT_DIR/swiftlys2" ]; then
    remove_gameinfo_entry "swiftlys2" "Swiftly"
fi

# Проверяем порядок записей
verify_gameinfo_order
```

---

## 🎮 Обновление gameinfo.gi

### Структура файла gameinfo.gi

**Расположение:** `/home/container/game/csgo/gameinfo.gi`

**Формат:**
```
FileSystem
{
    SearchPaths
    {
        // Указываются в порядке приоритета (сверху вниз)
        
        Game_LowViolence            csgo_lv
        
        // ====== ПЛАГИНЫ ЗАГРУЖАЮТСЯ ЗДЕСЬ ======
        Game                        csgo/addons/metamod      ← ДОЛЖЕН БЫТЬ ПЕРВЫМ!
        Game                        csgo/addons/swiftlys2    ← Swiftly (если установлен)
        Game                        csgo/addons/modsharp     ← ModSharp (если установлен)
        // =========================================
        
        Game                        csgo
        Game                        csgo_imported
        // ... остальные записи ...
    }
}
```

### Правила добавления

1. **MetaMod ВСЕГДА первый** (если установлен)
2. **CounterStrikeSharp НЕ добавляется** (работает через MetaMod)
3. **Swiftly добавляется** как `csgo/addons/swiftlys2`
4. **ModSharp добавляется** как `csgo/addons/modsharp`

### Порядок важен!

❌ **НЕПРАВИЛЬНО:**
```
Game    csgo/addons/swiftlys2
Game    csgo/addons/metamod      ← MetaMod НЕ первый!
```

✅ **ПРАВИЛЬНО:**
```
Game    csgo/addons/metamod      ← MetaMod ПЕРВЫЙ!
Game    csgo/addons/swiftlys2
```

---

## 🧪 Тестирование

### Тест 1: Установка CounterStrikeSharp

**Переменные:**
```bash
CSS_AUTOUPDATE=1
METAMOD_AUTOUPDATE=1
SWIFTLY_AUTOUPDATE=0
```

**Ожидаемый результат:**
- ✅ MetaMod установлен
- ✅ CSS установлен
- ✅ gameinfo.gi содержит только MetaMod
- ✅ versions.txt обновлен

**Проверка gameinfo.gi:**
```bash
Game_LowViolence            csgo_lv
Game                        csgo/addons/metamod
Game                        csgo
```

---

### Тест 2: Установка Swiftly

**Переменные:**
```bash
CSS_AUTOUPDATE=0
METAMOD_AUTOUPDATE=1
SWIFTLY_AUTOUPDATE=1
```

**Ожидаемый результат:**
- ✅ MetaMod установлен
- ✅ Swiftly установлен
- ✅ gameinfo.gi содержит MetaMod и Swiftly
- ✅ versions.txt обновлен

**Проверка gameinfo.gi:**
```bash
Game_LowViolence            csgo_lv
Game                        csgo/addons/metamod
Game                        csgo/addons/swiftlys2
Game                        csgo
```

---

### Тест 3: Совместная установка CSS и Swiftly

**Переменные:**
```bash
CSS_AUTOUPDATE=1
METAMOD_AUTOUPDATE=1
SWIFTLY_AUTOUPDATE=1
```

**Ожидаемый результат:**
- ✅ MetaMod установлен
- ✅ CSS установлен
- ✅ Swiftly установлен
- ✅ gameinfo.gi содержит MetaMod и Swiftly (НЕ CSS!)
- ✅ versions.txt содержит все три версии

**Проверка gameinfo.gi:**
```bash
Game_LowViolence            csgo_lv
Game                        csgo/addons/metamod
Game                        csgo/addons/swiftlys2
Game                        csgo
```

---

## ✅ Чеклист реализации

### Файлы для изменения

#### docker/scripts/update.sh

- [ ] **Добавить конфигурацию типов аддонов** (строка ~17)
  - [ ] `ADDON_FILE_PATTERNS`
  - [ ] `ADDON_GAMEINFO_DIRS`
  - [ ] `ADDON_REQUIRES_METAMOD`

- [ ] **Заменить `update_addon()` на `update_addon_universal()`** (строка ~248)

- [ ] **Создать функции управления gameinfo.gi** (после `configure_metamod`)
  - [ ] `add_gameinfo_entry()`
  - [ ] `remove_gameinfo_entry()`
  - [ ] `verify_gameinfo_order()`

- [ ] **Обновить `cleanup_and_update()`** (строка ~222)

#### docker/entrypoint.sh

- [ ] **Добавить удаление записей для отключенных аддонов** (строка ~64)

#### egg/pelican.yaml

- [ ] **Добавить переменную SWIFTLY_AUTOUPDATE** (после CSS_AUTOUPDATE)

#### egg/pelican.json

- [ ] **Добавить переменную SWIFTLY_AUTOUPDATE** (после CSS_AUTOUPDATE)

---

## ⚠️ Важные замечания

### 1. Репозиторий Swiftly

✅ **УТОЧНЕНО:**
- **Репозиторий:** `swiftly-solution/swiftlys2`
- **URL:** https://github.com/swiftly-solution/swiftlys2/releases
- **Формат файла:** `swiftlys2-linux-v{VERSION}-with-runtimes.zip`
- **Пример:** `swiftlys2-linux-v1.0.6-beta.9-with-runtimes.zip`

---

**Автор:** AI Assistant (Claude Sonnet 4.5)  
**Статус:** 📝 План готов к реализации
