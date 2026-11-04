#!/bin/bash
#
# Проверка docker/entrypoint.sh на собранном образе. Вместо CS2 — поддельный
# сервер, который ведёт себя так же: читает консоль, на `quit` выходит с
# segfault (как CS2 при каждой штатной остановке), может упасть сам.
#
#   bash tests/test-entrypoint.sh            (нужен docker; образ соберётся сам)
#
set -Eeuo pipefail
cd "$(dirname "$0")/.."

IMAGE="${IMAGE:-cs2-basefiles:test}"
docker build -q --platform linux/amd64 -t "$IMAGE" docker/ >/dev/null

FAIL=0
pass() { echo "  ✓ $1"; }
fail() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/mnt/game/bin/linuxsteamrt64" "$work/mnt/game/csgo" "$work/home"
echo 'PatchVersion=1.41.8.4' > "$work/mnt/game/csgo/steam.inf"
printf '"GameInfo"\n{\n\tFileSystem\n\t{\n\t\tSearchPaths\n\t\t{\n\t\t\tGame_LowViolence\tcsgo_lv\n\t\t\tGame\tcsgo\n\t\t}\n\t}\n}\n' \
    > "$work/mnt/game/csgo/gameinfo.gi"
cat > "$work/home/fake-server.sh" <<'SH'
#!/bin/bash
echo "fake: started"
echo "rcon_password supersecret"
echo "Token ${STEAM_ACC:-none} here"
[ "${MODE:-}" = gslt ] && echo "Cert request for invalid failed"
case "${MODE:-}" in
    crash) sleep 1; echo "Segmentation fault (core dumped)"; exit 139 ;;
    eof)
        if read -r -t 3 cmd; then echo "fake: got $cmd"
        else rc=$?; [ "$rc" -gt 128 ] && echo "fake: stdin still open" || echo "fake: stdin EOF"; fi
        exit 0 ;;
    *)
        while read -r cmd; do
            echo "fake: got $cmd"
            [ "$cmd" = quit ] && { echo "Segmentation fault (core dumped)"; exit 139; }
        done
        echo "fake: stdin EOF"; exit 0 ;;
esac
SH
chmod -R a+rwX "$work/home"; chmod +x "$work/home/fake-server.sh"

# run <MODE> [-i] — вывод в $out, код выхода в $rc; stdin — из того, что подали
run() {
    local mode="$1"; shift
    rc=0
    out="$(docker run --rm "$@" --platform linux/amd64 --network none \
        -v "$work/mnt:/mnt:ro" -v "$work/home:/home/container" \
        -e STARTUP='./fake-server.sh' -e MODE="$mode" -e ADDON_PLATFORM=none \
        -e STEAM_ACC=TESTTOKEN0123456789ABCDEF01234567 "$IMAGE" 2>&1)" || rc=$?
    out="$(printf '%s' "$out" | sed 's/\x1b\[[0-9;]*m//g')"
}
has()  { grep -qF -- "$1" <<<"$out"; }

echo "== штатная остановка: команда из панели, потом quit"
run stop -i < <(sleep 8; echo status; sleep 1; echo quit; sleep 5)
has "fake: got status" && pass "команды панели доходят до сервера" || fail "команда не дошла"
has "[cs2-crash]" && fail "остановка принята за падение" || pass "остановка — не падение"
has "Segmentation fault" && fail "шумный выход показан" || pass "шумный выход при остановке скрыт"
has "Сервер остановлен" && [ "$rc" -eq 0 ] && pass "«Сервер остановлен», код 0" || fail "код $rc"

echo "== падение без запроса остановки"
run crash -i < <(sleep 15)
has "Segmentation fault" && pass "строка падения видна (раньше пряталась)" || fail "строка падения скрыта"
has "[cs2-crash] code=139" && [ "$rc" -eq 139 ] && pass "маркер для хоста и код 139" || fail "маркер/код: $rc"
has "Сервер упал" && pass "понятное сообщение о падении" || fail "нет сообщения о падении"

echo "== секреты"
has "supersecret" && fail "пароль из rcon_password виден" || pass "rcon_password замаскирован"
has "TESTTOKEN0123456789" && fail "GSLT виден" || pass "GSLT замаскирован (фильтр выключен)"

echo "== stdin закрыт — сервер не получает EOF"
run eof < /dev/null
has "fake: stdin still open" && pass "консоль остаётся открытой" || fail "сервер получил EOF: $(grep fake: <<<"$out")"

echo "== GSLT недействителен"
run gslt -i < <(sleep 8; echo quit; sleep 3)
has "GSLT (Game Server Login Token) недействителен" && pass "подсказка про GSLT" || fail "нет подсказки"

echo
[ "$FAIL" -eq 0 ] && echo "entrypoint: всё в порядке" || { echo "entrypoint: провалов — $FAIL"; echo "$out" | tail -n 30; exit 1; }
