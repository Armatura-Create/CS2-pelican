#!/usr/bin/env bash
# Самопроверка логики аддонов (gameinfo.gi + разбор релизов GitHub).
# Запуск из корня репозитория:
#   docker run --rm -v "$PWD/docker:/src" alpine:3 \
#       sh -c 'apk add -q bash jq && bash /src/scripts/test-addons.sh'
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

pick() { jq -r --arg re "$2" '[.assets[]?.browser_download_url | select(test($re))] | first // empty' "$1"; }

check "Swiftly: выбран linux-with-runtimes" \
    "https://x/swiftlys2-linux-v1.4.9-with-runtimes.zip" \
    "$(pick "$WORK/ok.json" 'swiftlys2-linux-v.*-with-runtimes\.zip')"

check "CSS: выбран with-runtime-linux, не windows" \
    "https://x/counterstrikesharp-with-runtime-linux-1.0.373.zip" \
    "$(pick "$WORK/css.json" 'counterstrikesharp-with-runtime-linux-.*\.zip')"

check "нет подходящего asset -> пустая строка" \
    "" "$(pick "$WORK/ok.json" 'modsharp.*linux\.zip')"

check "ответ про лимит -> версия не определяется" \
    "" "$(jq -r '.tag_name // empty' "$WORK/limit.json")"

check "ответ про лимит -> список assets пуст" \
    "" "$(pick "$WORK/limit.json" '.*\.zip')"

echo
if [ "$fail" -eq 0 ]; then
    echo "ВСЕ ПРОВЕРКИ ПРОЙДЕНЫ"
else
    echo "ЕСТЬ ОШИБКИ"
fi
exit "$fail"
