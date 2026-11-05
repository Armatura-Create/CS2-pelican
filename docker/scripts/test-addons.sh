#!/usr/bin/env bash
# Самопроверка логики аддонов (gameinfo.gi + разбор релизов GitHub).
# Запуск из корня репозитория:
#   docker run --rm -v "$PWD/docker:/src" alpine:3 \
#       sh -c 'apk add -q bash jq coreutils rsync findutils && bash /src/scripts/test-addons.sh'
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
sync_gameinfo csgo/addons/metamod >/dev/null 2>&1
check "выбран metamod" "metamod" "$(entries)"

before="$(cat "$GAMEINFO_FILE")"
sync_gameinfo csgo/addons/metamod >/dev/null 2>&1
check "идемпотентность: повторный вызов ничего не меняет" "$before" "$(cat "$GAMEINFO_FILE")"

sync_gameinfo csgo/addons/swiftlys2 >/dev/null 2>&1
check "переключение metamod -> swiftly убирает старую запись" "swiftlys2" "$(entries)"

sync_gameinfo csgo/addons/metamod >/dev/null 2>&1
check "обратное переключение swiftly -> metamod" "metamod" "$(entries)"

sync_gameinfo >/dev/null 2>&1
check "ADDON_PLATFORM=none не оставляет записей" "" "$(entries)"

sync_gameinfo csgo/addons/metamod csgo/addons/swiftlys2 >/dev/null 2>&1
check "порядок сохраняется: metamod первым" "metamod swiftlys2" "$(entries)"

check "остальные строки файла не тронуты" \
    "1" "$(grep -c 'Game	core' "$GAMEINFO_FILE")"
check "якорь Game_LowViolence на месте" \
    "1" "$(grep -c 'Game_LowViolence' "$GAMEINFO_FILE")"

reset_gameinfo
sync_gameinfo csgo/addons/metamod sharp >/dev/null 2>&1
check "ModSharp: строка Game sharp после metamod" "metamod" "$(entries)"
check "ModSharp: Game sharp на месте и одна" "1" "$(grep -cE 'Game[[:blank:]]+sharp$' "$GAMEINFO_FILE")"
check "ModSharp: порядок — metamod, sharp, потом csgo" "csgo/addons/metamod sharp csgo" \
    "$(grep -oE 'Game[[:blank:]]+[^[:space:]]+' "$GAMEINFO_FILE" | grep -v LowViolence | awk '{print $2}' | head -n3 | tr '\n' ' ' | sed 's/ $//')"
sync_gameinfo csgo/addons/metamod >/dev/null 2>&1
check "ModSharp выключен — строка Game sharp убрана" "0" "$(grep -cE 'Game[[:blank:]]+sharp' "$GAMEINFO_FILE")"

# Файл без якоря должен приводить к ошибке, а не к молча неработающему аддону
printf '"GameInfo"\n{\n}\n' > "$GAMEINFO_FILE"
rc=0; sync_gameinfo csgo/addons/metamod >/dev/null 2>&1 || rc=$?
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

sync_gameinfo csgo/addons/swiftlys2 >/dev/null 2>&1
printf '// моя правка\n' >> "$GAMEINFO_FILE"
refresh_gameinfo >/dev/null 2>&1
check "Valve файл не меняла -> правка пользователя цела" "1" "$(grep -c 'моя правка' "$GAMEINFO_FILE")"
check "Valve файл не меняла -> строки аддонов целы" "swiftlys2" "$(entries)"

sed -i 's/Game	core/Game	core\n			Game	new_valve_path/' "$GAMEINFO_MNT"
refresh_gameinfo >/dev/null 2>&1
check "Valve обновила файл -> в контейнере новая версия" "1" "$(grep -c 'new_valve_path' "$GAMEINFO_FILE")"
check "Valve обновила файл -> прежний в .bak с правкой" "1" "$(grep -c 'моя правка' "$GAMEINFO_FILE.bak")"
check "Valve обновила файл -> базовая версия обновлена" "" "$(cmp -s "$GAMEINFO_FILE.host" "$GAMEINFO_MNT" || echo differ)"
sync_gameinfo csgo/addons/swiftlys2 >/dev/null 2>&1
check "после обновления аддоны расставляются заново" "swiftlys2" "$(entries)"

# сервер старше этой логики: базы нет
host_v1; cp "$GAMEINFO_MNT" "$GAMEINFO_FILE"; sync_gameinfo csgo/addons/swiftlys2 >/dev/null 2>&1
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
echo "== ALLOW_TOKENLESS =="
reset_gameinfo
printf '\t"RequireLoginForDedicatedServers" "1"\n' >> "$GAMEINFO_FILE"
ALLOW_TOKENLESS=1 apply_tokenless 2>/dev/null
check "ALLOW_TOKENLESS=1 → \"0\"" '"RequireLoginForDedicatedServers" "0"' "$(grep -o '"RequireLoginForDedicatedServers" "[0-9]"' "$GAMEINFO_FILE")"
ALLOW_TOKENLESS=0 apply_tokenless 2>/dev/null
check "ALLOW_TOKENLESS=0 → \"1\"" '"RequireLoginForDedicatedServers" "1"' "$(grep -o '"RequireLoginForDedicatedServers" "[0-9]"' "$GAMEINFO_FILE")"
cp "$GAMEINFO_FILE" "$WORK/valve.gi"; ALLOW_TOKENLESS=1 apply_tokenless 2>/dev/null
check "своя правка tokenless — не «Valve обновила файл»" "нет" "$(gameinfo_differs "$GAMEINFO_FILE" "$WORK/valve.gi" && echo да || echo нет)"

echo
echo "== закрепление версий =="
check "Metamod: git1380"            "git1380"       "$(METAMOD_VERSION=git1380 addon_pin metamod 2>/dev/null)"
check "Metamod: 2.0.0-git1380"      "2.0.0-git1380" "$(METAMOD_VERSION=2.0.0-git1380 addon_pin metamod 2>/dev/null)"
check "Metamod: мусор отвергнут"    ""              "$(METAMOD_VERSION='git1380;id' addon_pin metamod 2>/dev/null)"
check "CSS: v1.0.360"               "v1.0.360"      "$(CSS_VERSION=v1.0.360 addon_pin css 2>/dev/null)"
check "ModSharp: git197 → git-197"  "git-197"       "$(MODSHARP_VERSION=git197 addon_pin modsharp 2>/dev/null)"
check "ModSharp: git-197"           "git-197"       "$(MODSHARP_VERSION=git-197 addon_pin modsharp 2>/dev/null)"
check "Metamod 2.0.0-git1380 → версия git1380" "git1380" "$(METAMOD_VERSION=2.0.0-git1380 addon_target metamod 2>/dev/null)"
check "теги ModSharp сравниваются по номеру" "да" "$(gt git-197 git-196)"

echo
echo "== склад аддонов ноды (/mnt/.cs2-addons) =="
ADDON_STORE="$WORK/store"; OUTPUT_DIR="$WORK/addons"; SHARP_DIR="$WORK/sharp"; TEMP_DIR="$WORK/tmp"; VERSION_FILE="$WORK/versions.txt"
mkdir -p "$ADDON_STORE/css/v1.0.400/tree/counterstrikesharp/bin/linuxsteamrt64" \
         "$ADDON_STORE/css/v1.0.400/tree/counterstrikesharp/dotnet/shared" "$TEMP_DIR"
echo so  > "$ADDON_STORE/css/v1.0.400/tree/counterstrikesharp/bin/linuxsteamrt64/counterstrikesharp.so"
echo clr > "$ADDON_STORE/css/v1.0.400/tree/counterstrikesharp/dotnet/shared/libcoreclr.so"
touch "$ADDON_STORE/css/v1.0.400/.ready"
printf 'updated 1\nlatest css v1.0.400\nbeta swiftly v1.4.11-beta.10\npin metamod git1380\n' > "$ADDON_STORE/index"
check "индекс: последняя CSS"           "v1.0.400"        "$(store_index latest css)"
check "индекс: бета Swiftly"            "v1.4.11-beta.10" "$(store_index beta swiftly)"
check "индекс: закрепление на ноду"     "git1380"         "$(addon_pin metamod 2>/dev/null)"
check "своё закрепление важнее ноды"    "git1400"         "$(METAMOD_VERSION=git1400 addon_pin metamod 2>/dev/null)"
check "версия CSS — со склада, без GitHub" "v1.0.400"     "$(addon_target css 2>/dev/null)"
touch -d '3 hours ago' "$ADDON_STORE/index"
check "устаревший индекс не используется" "" "$(store_index latest css)"
touch "$ADDON_STORE/index"
check "дерево: готовое есть"            "$ADDON_STORE/css/v1.0.400/tree" "$(store_tree css v1.0.400)"
check "дерево: без .ready — нет"        "" "$(store_tree css v1.0.399 || true)"
check "дерево: путь с ../ отвергнут"     "" "$(store_tree css ../../etc || true)"

ensure_addon css >/dev/null 2>&1
check "CSS поставлен со склада без сети" "so" "$(cat "$OUTPUT_DIR/counterstrikesharp/bin/linuxsteamrt64/counterstrikesharp.so" 2>/dev/null)"
check "версия записана" "CSS=v1.0.400" "$(grep '^CSS=' "$VERSION_FILE")"
check ".NET — копия (общий .NET выключен)" "нет" "$([ -L "$OUTPUT_DIR/counterstrikesharp/dotnet/shared/libcoreclr.so" ] && echo да || echo нет)"

rm -rf "$OUTPUT_DIR" "$VERSION_FILE"
ADDONS_SHARED_RUNTIME=1 ensure_addon css >/dev/null 2>&1
check "общий .NET: ссылка на склад" "$ADDON_STORE/css/v1.0.400/tree/counterstrikesharp/dotnet/shared/libcoreclr.so" \
    "$(readlink "$OUTPUT_DIR/counterstrikesharp/dotnet/shared/libcoreclr.so")"
check "общий .NET: бинарник CSS — копия" "нет" "$([ -L "$OUTPUT_DIR/counterstrikesharp/bin/linuxsteamrt64/counterstrikesharp.so" ] && echo да || echo нет)"

rm -f "$VERSION_FILE"
ensure_addon css >/dev/null 2>&1
check "общий .NET выключили — ссылки заменены копией" "clr" \
    "$([ -L "$OUTPUT_DIR/counterstrikesharp/dotnet/shared/libcoreclr.so" ] || cat "$OUTPUT_DIR/counterstrikesharp/dotnet/shared/libcoreclr.so")"

# ModSharp: настройки сервера переживают обновление
mkdir -p "$ADDON_STORE/modsharp/git-197/tree/sharp/bin" "$ADDON_STORE/modsharp/git-197/tree/sharp/configs" \
         "$ADDON_STORE/modsharp/git-197/tree/shared/Sharp.Extensions.X" "$SHARP_DIR/configs"
echo lib > "$ADDON_STORE/modsharp/git-197/tree/sharp/bin/libmodsharp.so"
echo '{"default":true}' > "$ADDON_STORE/modsharp/git-197/tree/sharp/configs/core.json"
echo ext > "$ADDON_STORE/modsharp/git-197/tree/shared/Sharp.Extensions.X/x.dll"
touch "$ADDON_STORE/modsharp/git-197/.ready"
echo '{"mine":true}' > "$SHARP_DIR/configs/core.json"
MODSHARP_VERSION=git-197 ensure_addon modsharp >/dev/null 2>&1
check "ModSharp поставлен" "lib" "$(cat "$SHARP_DIR/bin/libmodsharp.so" 2>/dev/null)"
check "ModSharp: расширения в shared/" "ext" "$(cat "$SHARP_DIR/shared/Sharp.Extensions.X/x.dll" 2>/dev/null)"
check "ModSharp: core.json сервера сохранён" '{"mine":true}' "$(cat "$SHARP_DIR/configs/core.json")"

echo
if [ "$fail" -eq 0 ]; then
    echo "ВСЕ ПРОВЕРКИ ПРОЙДЕНЫ"
else
    echo "ЕСТЬ ОШИБКИ"
fi
exit "$fail"
