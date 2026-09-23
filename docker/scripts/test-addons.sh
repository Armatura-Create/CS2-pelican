#!/usr/bin/env bash
# Самопроверка логики аддонов (gameinfo.gi + разбор релизов GitHub).
# Запуск из корня репозитория:
#   docker run --rm -v "$PWD/docker:/src" alpine:3 \
#       sh -c 'apk add -q bash jq coreutils && bash /src/scripts/test-addons.sh'
# coreutils обязателен: сравнение версий опирается на GNU sort -V, как в образе.
set -Eeuo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# update.sh подключает /utils/logging.sh — подставляем заглушку
mkdir -p /utils
cat > /utils/logging.sh <<'EOF'
log_message() { printf '      [%s] %s\n' "${2:-info}" "$1" >&2; }
handle_error() { return $?; }
EOF

# shellcheck disable=SC1090
source "$SRC/scripts/update.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
GAMEINFO_FILE="$WORK/gameinfo.gi"

fail=0
check() {
    if [ "$2" = "$3" ]; then
        echo "ok   - $1"
    else
        echo "FAIL - $1"
        echo "       ожидалось: [$2]"
        echo "       получено:  [$3]"
        fail=1
    fi
}

reset_gameinfo() {
    cat > "$GAMEINFO_FILE" <<'EOF'
"GameInfo"
{
	game	"Counter-Strike 2"
	FileSystem
	{
		SearchPaths
		{
			Game_LowViolence	csgo_lv
			Game	csgo
			Game	core
		}
	}
}
EOF
}

entries() {
    grep -oE 'csgo/addons/[^[:space:]]+' "$GAMEINFO_FILE" 2>/dev/null \
        | sed 's#csgo/addons/##' | tr '\n' ' ' | sed 's/ *$//'
}

echo "== sync_gameinfo =="

reset_gameinfo
sync_gameinfo metamod >/dev/null 2>&1
check "выбран metamod" "metamod" "$(entries)"

before="$(cat "$GAMEINFO_FILE")"
sync_gameinfo metamod >/dev/null 2>&1
check "идемпотентность: повторный вызов ничего не меняет" "$before" "$(cat "$GAMEINFO_FILE")"

sync_gameinfo swiftlys2 >/dev/null 2>&1
check "переключение metamod -> swiftly убирает старую запись" "swiftlys2" "$(entries)"

sync_gameinfo metamod >/dev/null 2>&1
check "обратное переключение swiftly -> metamod" "metamod" "$(entries)"

sync_gameinfo >/dev/null 2>&1
check "ADDON_PLATFORM=none не оставляет записей" "" "$(entries)"

sync_gameinfo metamod swiftlys2 >/dev/null 2>&1
check "порядок сохраняется: metamod первым" "metamod swiftlys2" "$(entries)"

check "остальные строки файла не тронуты" \
    "1" "$(grep -c 'Game	core' "$GAMEINFO_FILE")"
check "якорь Game_LowViolence на месте" \
    "1" "$(grep -c 'Game_LowViolence' "$GAMEINFO_FILE")"

# Файл без якоря должен приводить к ошибке, а не к молча неработающему аддону
printf '"GameInfo"\n{\n}\n' > "$GAMEINFO_FILE"
rc=0; sync_gameinfo metamod >/dev/null 2>&1 || rc=$?
check "нет Game_LowViolence -> ненулевой код возврата" "1" "$rc"
check "файл без якоря не испорчен" "1" "$(grep -c 'GameInfo' "$GAMEINFO_FILE")"

echo
echo "== refresh_gameinfo: копия в контейнере против файла Valve на хосте =="

GAMEINFO_MNT="$WORK/mnt-gameinfo.gi"
host_v1() { reset_gameinfo; cp "$GAMEINFO_FILE" "$GAMEINFO_MNT"; rm -f "$GAMEINFO_FILE" "$GAMEINFO_FILE".{host,bak}; }

host_v1
refresh_gameinfo >/dev/null 2>&1
check "нет копии -> взята с хоста" "" "$(cmp -s "$GAMEINFO_FILE" "$GAMEINFO_MNT" || echo differ)"
check "нет копии -> запомнена базовая версия" "" "$(cmp -s "$GAMEINFO_FILE.host" "$GAMEINFO_MNT" || echo differ)"

sync_gameinfo swiftlys2 >/dev/null 2>&1
printf '// моя правка\n' >> "$GAMEINFO_FILE"
refresh_gameinfo >/dev/null 2>&1
check "Valve файл не меняла -> правка пользователя цела" "1" "$(grep -c 'моя правка' "$GAMEINFO_FILE")"
check "Valve файл не меняла -> строки аддонов целы" "swiftlys2" "$(entries)"

sed -i 's/Game	core/Game	core\n			Game	new_valve_path/' "$GAMEINFO_MNT"
refresh_gameinfo >/dev/null 2>&1
check "Valve обновила файл -> в контейнере новая версия" "1" "$(grep -c 'new_valve_path' "$GAMEINFO_FILE")"
check "Valve обновила файл -> прежний в .bak с правкой" "1" "$(grep -c 'моя правка' "$GAMEINFO_FILE.bak")"
check "Valve обновила файл -> базовая версия обновлена" "" "$(cmp -s "$GAMEINFO_FILE.host" "$GAMEINFO_MNT" || echo differ)"
sync_gameinfo swiftlys2 >/dev/null 2>&1
check "после обновления аддоны расставляются заново" "swiftlys2" "$(entries)"

# сервер старше этой логики: базы нет
host_v1; cp "$GAMEINFO_MNT" "$GAMEINFO_FILE"; sync_gameinfo swiftlys2 >/dev/null 2>&1
refresh_gameinfo >/dev/null 2>&1
check "без базы, копия актуальна -> не тронута" "swiftlys2" "$(entries)"
check "без базы, копия актуальна -> база запомнена" "" "$(cmp -s "$GAMEINFO_FILE.host" "$GAMEINFO_MNT" || echo differ)"

host_v1; cp "$GAMEINFO_MNT" "$GAMEINFO_FILE"
sed -i 's/Game	core/Game	core\n			Game	new_valve_path/' "$GAMEINFO_MNT"
refresh_gameinfo >/dev/null 2>&1
check "без базы, копия устарела (как на проде) -> обновлена" "1" "$(grep -c 'new_valve_path' "$GAMEINFO_FILE")"
check "без базы, копия устарела -> прежняя в .bak" "1" "$([ -f "$GAMEINFO_FILE.bak" ] && echo 1)"

echo
echo "== сравнение версий =="

gt() { if version_gt "$1" "$2"; then echo да; else echo нет; fi; }
check "beta.10 новее beta.9 (строкой было бы наоборот)" "да"  "$(gt v1.4.11-beta.10 v1.4.11-beta.9)"
check "бета 1.4.11 новее стабильной 1.4.10"             "да"  "$(gt v1.4.11-beta.1 v1.4.10)"
check "стабильная 1.4.10 не новее беты 1.4.11"           "нет" "$(gt v1.4.10 v1.4.11-beta.10)"
check "стабильная 1.4.11 новее своей беты"               "да"  "$(gt v1.4.11 v1.4.11-beta.10)"
check "одинаковые версии -> не новее"                    "нет" "$(gt v1.4.10 v1.4.10)"

echo
echo "== выбор релиза Swiftly =="

# как отдаёт GitHub: не по порядку версий, с черновиком и релизом без архива
cat > "$WORK/list.json" <<'EOF'
[
 {"tag_name":"v1.4.11-beta.9","prerelease":true,"draft":false,"assets":[{"browser_download_url":"https://x/swiftlys2-linux-v1.4.11-beta.9-with-runtimes.zip"}]},
 {"tag_name":"v1.4.11-beta.2","prerelease":true,"draft":false,"assets":[{"browser_download_url":"https://x/swiftlys2-linux-v1.4.11-beta.2-with-runtimes.zip"}]},
 {"tag_name":"v1.4.11-beta.10","prerelease":true,"draft":false,"assets":[{"browser_download_url":"https://x/swiftlys2-linux-v1.4.11-beta.10-with-runtimes.zip"}]},
 {"tag_name":"v1.4.12-beta.1","prerelease":true,"draft":false,"assets":[{"browser_download_url":"https://x/swiftlys2-windows-v1.4.12-beta.1-with-runtimes.zip"}]},
 {"tag_name":"v9.9.9","prerelease":false,"draft":true,"assets":[{"browser_download_url":"https://x/swiftlys2-linux-v9.9.9-with-runtimes.zip"}]},
 {"tag_name":"v1.4.10","prerelease":false,"draft":false,"assets":[{"browser_download_url":"https://x/swiftlys2-linux-v1.4.10-with-runtimes.zip"}]},
 {"tag_name":"v1.4.9","prerelease":false,"draft":false,"assets":[{"browser_download_url":"https://x/swiftlys2-linux-v1.4.9-with-runtimes.zip"}]}
]
EOF
SW='swiftlys2-linux-v.*-with-runtimes\.zip'
check "бета выключена -> последняя стабильная"            "v1.4.10"         "$(pick_release "$WORK/list.json" "$SW" 0 "")"
check "бета включена -> самая новая бета, не по порядку" "v1.4.11-beta.10" "$(pick_release "$WORK/list.json" "$SW" 1 "")"
check "архив нужного вида в URL выбранной беты" \
    "https://x/swiftlys2-linux-v1.4.11-beta.10-with-runtimes.zip" \
    "$(release_asset_url "$WORK/list.json" "$SW" v1.4.11-beta.10)"

echo '{"tag_name":"v1.4.11-beta.9","prerelease":true,"draft":false,"assets":[{"browser_download_url":"https://x/swiftlys2-linux-v1.4.11-beta.9-with-runtimes.zip"}]}' > "$WORK/pin.json"
check "фиксация на бете берётся и при выключенной бете" "v1.4.11-beta.9" "$(pick_release "$WORK/pin.json" "$SW" 0 v1.4.11-beta.9)"

check "фиксация: тег проходит"                  "v1.4.10" "$(SWIFTLY_VERSION=v1.4.10 addon_pin swiftly 2>/dev/null)"
check "фиксация: мусор в URL не пропускается"   ""        "$(SWIFTLY_VERSION='../../evil?x=1' addon_pin swiftly 2>/dev/null)"

echo
echo "== разбор релиза GitHub =="

cat > "$WORK/ok.json" <<'EOF'
{"tag_name":"v1.4.9","assets":[
 {"name":"swiftlys2-windows-v1.4.9-with-runtimes.zip","browser_download_url":"https://x/swiftlys2-windows-v1.4.9-with-runtimes.zip"},
 {"name":"swiftlys2-linux-v1.4.9.zip","browser_download_url":"https://x/swiftlys2-linux-v1.4.9.zip"},
 {"name":"swiftlys2-linux-v1.4.9-with-runtimes.zip","browser_download_url":"https://x/swiftlys2-linux-v1.4.9-with-runtimes.zip"}]}
EOF

cat > "$WORK/css.json" <<'EOF'
{"tag_name":"v1.0.373","assets":[
 {"name":"counterstrikesharp-linux-1.0.373.zip","browser_download_url":"https://x/counterstrikesharp-linux-1.0.373.zip"},
 {"name":"counterstrikesharp-with-runtime-windows-1.0.373.zip","browser_download_url":"https://x/counterstrikesharp-with-runtime-windows-1.0.373.zip"},
 {"name":"counterstrikesharp-with-runtime-linux-1.0.373.zip","browser_download_url":"https://x/counterstrikesharp-with-runtime-linux-1.0.373.zip"}]}
EOF

# ответ GitHub при исчерпанном лимите — валидный JSON без tag_name
echo '{"message":"API rate limit exceeded","documentation_url":"https://docs.github.com"}' > "$WORK/limit.json"

pick() { release_asset_url "$1" "$2" "$(jq -r '.tag_name // empty' "$1")"; }

check "Swiftly: выбран linux-with-runtimes" \
    "https://x/swiftlys2-linux-v1.4.9-with-runtimes.zip" \
    "$(pick "$WORK/ok.json" 'swiftlys2-linux-v.*-with-runtimes\.zip')"

check "CSS: выбран with-runtime-linux, не windows" \
    "https://x/counterstrikesharp-with-runtime-linux-1.0.373.zip" \
    "$(pick "$WORK/css.json" 'counterstrikesharp-with-runtime-linux-.*\.zip')"

check "нет подходящего asset -> пустая строка" \
    "" "$(pick "$WORK/ok.json" 'modsharp.*linux\.zip')"

check "ответ про лимит -> версия не определяется" \
    "" "$(pick_release "$WORK/limit.json" '.*\.zip' 0 "")"

check "ответ про лимит -> список assets пуст" \
    "" "$(pick "$WORK/limit.json" '.*\.zip')"

echo
if [ "$fail" -eq 0 ]; then
    echo "ВСЕ ПРОВЕРКИ ПРОЙДЕНЫ"
else
    echo "ЕСТЬ ОШИБКИ"
fi
exit "$fail"
