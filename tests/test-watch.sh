#!/bin/bash
#
# Проверка service/watch.sh: фальшивые docker и панель, настоящий nftables.
# Журнал консоли, отчёт о падении, правила по консоли (бан только на портах
# своего сервера, kickid, рост бана при повторе), режим log, OOM, подделка
# через ник.
#
# Только в одноразовом контейнере: тест меняет nft и ставит заглушку docker.
#   docker run --rm --cap-add NET_ADMIN -v "$PWD:/src:ro" debian:12 bash /src/tests/test-watch.sh
#
set -Eeuo pipefail

[ -f /.dockerenv ] || { echo "Запускайте только в контейнере (см. заголовок)." >&2; exit 1; }

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null && apt-get install -y -qq nftables jq curl python3 procps >/dev/null

FAIL=0
pass() { echo "  ✓ $1"; }
fail() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

UUID=11111111-2222-3333-4444-555555555555
ID=abcd1234
work="$(mktemp -d)"
cp -r /src/service/. "$work/"
cd "$work"

# --- фальшивая панель: список серверов и приём команд консоли ---
python3 - <<'PY' &
import http.server, json
srv = {"attributes": {"uuid": "11111111-2222-3333-4444-555555555555", "identifier": "abcd1234",
       "name": "Test #1", "node": 1, "container": {"image": "docker.io/scrender/base-files-cs2:latest",
       "environment": {"STEAM_ACC": "TESTTOKEN0123456789ABCDEF01234567"}},
       "relationships": {"allocations": {"data": [{"attributes": {"port": 27015}}]}}}}
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = json.dumps({"data": [srv], "meta": {"pagination": {"total_pages": 1}}}).encode()
        self.send_response(200); self.end_headers(); self.wfile.write(body)
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        with open("/tmp/commands.log", "a") as f: f.write(self.path + " " + self.rfile.read(n).decode() + "\n")
        self.send_response(204); self.end_headers()
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", 8000), H).serve_forever()
PY
panel=$!
sleep 1

# --- заглушка docker: список контейнеров, их консоль, состояние ---
mkdir -p /tmp/fake
cat > /usr/local/bin/docker <<'SH'
#!/bin/bash
case "$1" in
    ps) cat /tmp/fake/running 2>/dev/null ;;
    inspect)
        case "$*" in
            *OOMKilled*) cat /tmp/fake/oom 2>/dev/null || echo false ;;
            *StartedAt*) echo "2000-01-01T00:00:00.000000000Z" ;;
        esac ;;
    logs) cat "/tmp/fake/${*: -1}.log" ;;
esac
SH
chmod +x /usr/local/bin/docker
echo "$UUID" > /tmp/fake/running

# Поток «docker logs --timestamps» за сегодня (отчёт о падении берёт сегодняшний журнал)
day="$(date -u +%F)"; t=0
L() { printf '%sT10:%02d:%02d.000000000Z %s\n' "$day" $((t / 60)) $((t % 60)) "$1"; }
{
    L $'\033[0;32m[ServUp] > цветная строка\033[0m'
    L "rcon_password supersecret"
    L "Token TESTTOKEN0123456789ABCDEF01234567 used"
    L "Accepting Steam Net connection #1 UDP steamid:76561198345583467@80.250.101.109:53071"
    L "CServerSideClientBase::Connect( name='Real', userid=10, fake=0, connectiontypeflags=4, chan->addr=80.250.101.109:53071 )"
    L "Client 10 'Real' signon state SIGNONSTATE_SPAWN -> SIGNONSTATE_FULL"
    for i in 1 2 3 4 5; do L "[Data] Ignored bad 80.250.101.109:53071.  Stray data packet from host with no connection.  Ignoring."; done
    for i in 1 2 3 4 5 6; do L "Receiving C2S_CONNECT [protocol 14178 0 auth 3] from 203.0.113.50:40000"; done
    for i in 1 2 3; do L "[#99 UDP steamid:76561198345583467@80.250.101.109:53090 'Ignored bad 9.9.9.9:1 Invalid a byte'] $i reply timeouts"; done
    for i in 1 2 3; do L "player said: Ignored bad 9.9.9.8:1 Invalid lead byte"; done
    for i in 1 2; do L "[packet] Ignored bad 198.51.100.7:27005  Invalid lead byte"; done
    L "Banning 198.51.100.9 for rcon hacking attempts"
    L "Banning 10.0.0.5 for rcon hacking attempts"
    L "CServerSideClientBase::Connect( name='cs2commends.com', userid=16, fake=0, connectiontypeflags=4, chan->addr=213.189.218.189:51445 )"
    for i in 1 2 3; do L "SV:  Forcing client reconnect (SIGNONSTATE_CONNECTED) for client 'cs2commends.com'"; done
    t=60   # тот же адрес снова, после паузы между реакциями (30 с)
    for i in 1 2 3 4 5 6; do L "Receiving C2S_CONNECT [protocol 14178 0 auth 3] from 203.0.113.50:40000"; done
    L "Segmentation fault (core dumped)"
    L "[cs2-crash] code=139"
} > "/tmp/fake/$UUID.log"

cat > .env <<ENV
PELICAN_URL="http://127.0.0.1:8000"
PELICAN_APP_TOKEN="papp_x"
PELICAN_API_TOKEN="pacc_x"
PELICAN_NODE_ID="1"
PELICAN_IMAGE="docker.io/scrender/base-files-cs2:latest"
LOG_FILE_ENABLED="0"
GUARD_CONSOLE="enforce"
ENV
export WATCH_STATE_DIR=/tmp/state WATCH_RUN_DIR=/tmp/run WATCH_ONCE=1

./guard.sh apply >/dev/null 2>&1
nft list set inet cs2guard ports | grep -q 27015 || { echo "guard не поднялся"; exit 1; }

echo "== enforce"
out="$(./watch.sh run 2>&1 | sed 's/\x1b\[[0-9;]*m//g')"
log="/tmp/state/logs/$ID/$day.log"
[ -s "$log" ] && pass "журнал консоли: $(wc -l < "$log") строк" || fail "журнала нет: $log"
grep -q 'supersecret\|TESTTOKEN' "$log" && fail "в журнале секрет" || pass "секреты в журнале замаскированы"
grep -q $'\033' "$log" && fail "в журнале управляющие символы" || pass "цвета и управляющие символы вырезаны"
[ "$(stat -c %a /tmp/state/logs)" = 700 ] && pass "каталог журналов 700" || fail "права журналов: $(stat -c %a /tmp/state/logs)"

rep="$(ls /tmp/state/crashes/$ID/*.log 2>/dev/null | head -n1)"
[ -n "$rep" ] && grep -q 'Код выхода: 139' "$rep" && grep -q 'Segmentation fault' "$rep" \
    && pass "отчёт о падении с кодом и последними строками" || fail "отчёта о падении нет: $(ls -R /tmp/state/crashes 2>&1)"

bans="$(nft list set inet cs2guard blockport4)"
for ip in 203.0.113.50 198.51.100.7 198.51.100.9 213.189.218.189; do
    grep -q "$ip . 27015" <<<"$bans" && pass "бан $ip на порту сервера" || fail "нет бана $ip"
done
for ip in 9.9.9.9 9.9.9.8 80.250.101.109 10.0.0.5; do
    grep -q "$ip" <<<"$bans" && fail "забанен $ip (подделка / доверенный / частный)" || pass "$ip не тронут"
done
grep -q '203.0.113.50 . 27015 timeout 2h' <<<"$bans" && pass "повтор за сутки: бан вчетверо длиннее (2 ч)" \
    || fail "рост бана: $(grep 203.0.113.50 <<<"$bans")"
nft list set inet cs2guard block4 | grep -q 'elements' && fail "бан по консоли ушёл на всю ноду" || pass "по консоли — только порты своего сервера"
grep -q 'kickid 16' /tmp/commands.log 2>/dev/null && pass "kickid для бота отправлен в консоль" || fail "kickid не отправлен: $(cat /tmp/commands.log 2>&1)"

echo "== log: только пишет, что сделал бы"
./guard.sh unblock all >/dev/null
sed -i 's/GUARD_CONSOLE="enforce"/GUARD_CONSOLE="log"/' .env
grep -v 'cs2-crash' "/tmp/fake/$UUID.log" > /tmp/fake/x && mv /tmp/fake/x "/tmp/fake/$UUID.log"
echo true > /tmp/fake/oom
out="$(./watch.sh run 2>&1 | sed 's/\x1b\[[0-9;]*m//g')"
nft list set inet cs2guard blockport4 | grep -q 'elements' && fail "режим log поставил бан" || pass "режим log ничего не банит"
grep -q '\[guard log\].*connect_flood.*203.0.113.50' <<<"$out" && pass "режим log пишет, что сделал бы" || fail "нет записи режима log"
grep -rq 'OOM' /tmp/state/crashes/$ID/ && pass "OOM — тоже отчёт о падении" || fail "OOM не замечен"

kill "$panel" 2>/dev/null || true
echo
[ "$FAIL" -eq 0 ] && echo "watch: всё в порядке" || { echo "watch: провалов — $FAIL"; printf '%s\n' "$out" | tail -n 20; exit 1; }
