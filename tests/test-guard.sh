#!/bin/bash
#
# Проверка service/guard.sh на настоящем nftables: правила грузятся, порты
# берутся из (фальшивой) панели, флуд блокируется, остальное — нет.
#
# Только в одноразовом контейнере: тест вешает адреса на lo и меняет nft.
#   docker run --rm --cap-add NET_ADMIN -v "$PWD:/src:ro" debian:12 bash /src/tests/test-guard.sh
#
set -Eeuo pipefail

[ -f /.dockerenv ] || { echo "Запускайте только в контейнере (см. заголовок)." >&2; exit 1; }

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null && apt-get install -y -qq nftables jq curl python3 iproute2 >/dev/null
nft --version

FAIL=0
pass() { echo "  ✓ $1"; }
fail() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

work="$(mktemp -d)"
cp -r /src/service/. "$work/"
cd "$work"

# --- фальшивая панель: python отдаёт файл по пути, query-строку отбрасывает ---
mkdir -p panel/api/application
cat > panel/api/application/servers <<'JSON'
{"data": [
  {"attributes": {"node": 1, "container": {"image": "docker.io/scrender/base-files-cs2:latest"},
    "relationships": {"allocations": {"data": [{"attributes": {"port": 27015}}, {"attributes": {"port": 27016}}]}}}},
  {"attributes": {"node": 1, "container": {"image": "docker.io/scrender/base-files-cs2:dev"},
    "relationships": {"allocations": {"data": [{"attributes": {"port": 27020}}]}}}},
  {"attributes": {"node": 2, "container": {"image": "docker.io/scrender/base-files-cs2:latest"},
    "relationships": {"allocations": {"data": [{"attributes": {"port": 27030}}]}}}},
  {"attributes": {"node": 1, "container": {"image": "ghcr.io/other/minecraft:java"},
    "relationships": {"allocations": {"data": [{"attributes": {"port": 25565}}]}}}}
], "meta": {"pagination": {"total_pages": 1}}}
JSON
( cd panel && exec python3 -m http.server 8000 --bind 127.0.0.1 >/dev/null 2>&1 ) &
sleep 1

# .env от прошлой версии: ни одного GUARD_* — так guard.sh видят обновлённые хосты
cat > .env <<'ENV'
PELICAN_URL="http://127.0.0.1:8000"
PELICAN_APP_TOKEN="papp_test"
PELICAN_NODE_ID="1"
PELICAN_IMAGE="docker.io/scrender/base-files-cs2:latest"
LOG_FILE_ENABLED="0"
ENV
echo "== apply с .env без GUARD_*"
./guard.sh apply && pass "работает на .env прошлой версии" || fail "упал на .env без GUARD_*"
nft list chain inet cs2guard game | grep -q 'over 1500/second' && pass "лимит по умолчанию 1500" || fail "нет лимита по умолчанию"

cat > .env <<'ENV'
PELICAN_URL="http://127.0.0.1:8000"
PELICAN_APP_TOKEN="papp_test"
PELICAN_NODE_ID="1"
PELICAN_IMAGE="docker.io/scrender/base-files-cs2:latest"
GUARD_PPS_LIMIT="500"
GUARD_BAN_MINUTES="5"
GUARD_WHITELIST="198.51.100.12, bad-entry"
LOG_FILE_ENABLED="0"
ENV

echo "== apply"
./guard.sh apply

ports="$(nft -j list set inet cs2guard ports | jq -r '.nftables[].set.elem[]?' | sort -n | paste -sd' ' -)"
[ "$ports" = "27015 27016 27020" ] && pass "порты: свои серверы ноды, :dev тоже ($ports)" \
    || fail "порты: ждали '27015 27016 27020', получили '$ports'"

# Публичные адреса тестовой сети на lo: свой же трафик проходит prerouting
for i in 7 8 9 10 11 12 13; do ip addr add "198.51.100.$i/32" dev lo; done

# send <откуда> <порт> <пакетов> <байт> [пауза_с] [префикс]
send() {
    python3 - "$@" <<'PY'
import socket, sys, time
src, port, n, size = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
pause = float(sys.argv[5]) if len(sys.argv) > 5 else 0
prefix = bytes.fromhex(sys.argv[6]) if len(sys.argv) > 6 else b""
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind((src, 0))
data = (prefix + b"x" * size)[:max(size, len(prefix))]
for _ in range(n):
    s.sendto(data, (src, port))
    if pause:
        time.sleep(pause)
PY
}

blocked() { nft list set inet cs2guard block4 | grep -qw "$1"; }

echo "== трафик"
send 198.51.100.7  27015 5000 100            # флуд на игровой порт
send 198.51.100.8  27015 50   100 0.02       # игрок: 50 пакетов/с
send 198.51.100.9  27016 5    4              # «крошечные» пакеты
send 198.51.100.10 27099 5000 100            # флуд не на игровой порт
send 198.51.100.11 27020 200  30  0 ffffffff # A2S пачкой
send 198.51.100.12 27015 5000 100            # белый список
send 127.0.0.1     27015 5000 100            # частная сеть

blocked 198.51.100.7  && pass "флуд с одного адреса заблокирован" || fail "флуд не заблокирован"
blocked 198.51.100.8  && fail "игрок с обычным трафиком заблокирован" || pass "обычный трафик не тронут"
blocked 198.51.100.9  && fail "за крошечные пакеты — бан (не должно)" || pass "крошечные пакеты без бана"
blocked 198.51.100.10 && fail "заблокирован трафик не на игровой порт" || pass "чужие порты не тронуты"
blocked 198.51.100.11 && fail "A2S-пачка дала бан (не должна)" || pass "A2S ограничен без бана"
blocked 198.51.100.12 && fail "адрес из белого списка заблокирован" || pass "белый список работает"
blocked 127.0.0.1     && fail "частный адрес заблокирован" || pass "частные сети не ограничиваются"

# counter <текст правила> — сколько пакетов отбросило правило
counter() { nft list chain inet cs2guard game | grep -F "$1" | grep -o 'counter packets [0-9]*' | cut -d' ' -f3 || true; }
tiny="$(counter 'udp length < 17')"; a2s="$(counter '@a2s4')"
[ "${tiny:-0}" -eq 5 ] && pass "крошечные пакеты отброшены ($tiny из 5)" || fail "крошечные: отброшено ${tiny:-0} из 5"
[ "${a2s:-0}" -ge 100 ] && pass "лишние A2S отброшены ($a2s из 200)" || fail "A2S сверх лимита: отброшено ${a2s:-0}"

echo "== TCP: перебор RCON (поток SYN) — бан"
python3 - <<'PY2'
import socket
for _ in range(40):
    s = socket.socket(); s.settimeout(0.05); s.bind(("198.51.100.13", 0))
    try: s.connect(("198.51.100.13", 27015))
    except Exception: pass
    s.close()
PY2
blocked 198.51.100.13 && pass "поток SYN на игровой порт заблокирован" || fail "SYN-флуд не заблокирован"

echo "== бан только на портах одного сервера (для правил по консоли)"
./guard.sh ban-port 198.51.100.8 5 27016
nft list set inet cs2guard blockport4 | grep -q '198.51.100.8 . 27016' && pass "ban-port: адрес . порт" || fail "ban-port не добавил"
before="$(counter 'udp dport @blockport4')"
send 198.51.100.8 27016 3 100
send 198.51.100.8 27015 3 100
after="$(counter 'udp dport @blockport4')"
[ "$((after - ${before:-0}))" -eq 3 ] && pass "отброшено только на своём порту (3 из 6)" || fail "blockport отбросил $((after - ${before:-0})) из 6"
./guard.sh ban-port 10.0.0.9 5 27016 >/dev/null 2>&1 && fail "ban-port принял частный адрес" || pass "ban-port отклоняет частный адрес"

echo "== block / why / rates"
./guard.sh block 192.168.1.5 >/dev/null 2>&1 && fail "block принял частный адрес" || pass "block отклоняет частный адрес"
./guard.sh block 198.51.100.10 30 && blocked 198.51.100.10 && pass "ручной block" || fail "ручной block"
# вывод — в переменную: `| grep -q` под pipefail роняет конвейер SIGPIPE'ом
w="$(./guard.sh why 198.51.100.8 2>&1 || true)"
grep -q 'на портах: 27016' <<<"$w" && pass "why показывает бан по порту" || fail "why: $w"
# ждём только своего отправителя: голый wait ждал бы и фальшивую панель — вечно
( sleep 1; send 198.51.100.11 27020 400 100 0.004 ) & sender=$!
r="$(./guard.sh rates 3)"; wait "$sender"
grep -q '198.51.100.11' <<<"$r" && pass "rates видит отправителя ($(grep 198.51.100.11 <<<"$r" | awk '{print $2}') пакетов/с)" || fail "rates: $r"
./guard.sh unblock 198.51.100.8 && ! nft list set inet cs2guard blockport4 | grep -q '198.51.100.8' \
    && pass "unblock снимает и баны по портам" || fail "бан по порту остался"

echo "== повторный apply без изменений не пересобирает таблицу (блокировки целы)"
./guard.sh apply
blocked 198.51.100.7 && pass "блокировка пережила apply" || fail "apply сбросил блокировки"

echo "== новый сервер в панели подхватывается"
sed -i 's/"port": 27020}/"port": 27020}}, {"attributes": {"port": 27021}/' panel/api/application/servers
./guard.sh apply
nft list set inet cs2guard ports | grep -qw 27021 && pass "порт нового сервера добавлен" || fail "новый порт не добавлен"

echo "== панель недоступна — порты остаются"
sed -i 's#8000#8999#' .env
./guard.sh apply
nft list set inet cs2guard ports | grep -qw 27015 && pass "защита не снята при недоступной панели" || fail "порты пропали"
sed -i 's#8999#8000#' .env

echo "== unblock"
./guard.sh unblock 198.51.100.7
blocked 198.51.100.7 && fail "unblock не сработал" || pass "unblock снимает блокировку"

echo "== status"
./guard.sh status

echo "== off"
./guard.sh off
nft list table inet cs2guard >/dev/null 2>&1 && fail "таблица осталась после off" || pass "off снимает правила"

echo
[ "$FAIL" -eq 0 ] && echo "guard: всё в порядке" || { echo "guard: провалов — $FAIL"; exit 1; }
