#!/bin/bash
#
# Проверка логики service/ без настоящих Steam, панели и systemd: SteamCMD,
# список серверов панели по страницам, поиск установки и обязательная sha256.
#
# Только в одноразовом контейнере: тест пишет в /opt, /run и /etc/systemd.
#   docker run --rm -v "$PWD:/src:ro" debian:12 bash /src/tests/test-service.sh
#
set -Eeuo pipefail

[ -f /.dockerenv ] || { echo "Запускайте только в контейнере (см. заголовок)." >&2; exit 1; }

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null && apt-get install -y -qq jq curl python3 rsync >/dev/null

FAIL=0
pass() { echo "  ✓ $1"; }
fail() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

export LOG_FILE_ENABLED=0
work="$(mktemp -d)"
cp -r /src/service/. "$work/"

echo "== SteamCMD"
(
    cd "$work"
    source ./utils/managerSteamCMD.sh
    trap - ERR
    export BASE_DIR=/srv/cs2
    # Установка старше v1.2.12: SteamCMD внутри смонтированного каталога
    mkdir -p /srv/cs2/server/steamcmd/linux32 /srv/cs2/server/steamcmd/linux64
    cat > /srv/cs2/server/steamcmd/steamcmd.sh <<'SH'
#!/bin/bash
printf '%s\n' "$*" > /tmp/steamcmd.args
for ((i = 1; i <= $#; i++)); do
    [ "${!i}" = "+runscript" ] && { j=$((i + 1)); cp "${!j}" /tmp/steamcmd.script; stat -c %a "${!j}" > /tmp/steamcmd.mode; }
done
[ -n "${SLEEP:-}" ] && sleep "$SLEEP"
exit "${EXIT:-0}"
SH
    chmod +x /srv/cs2/server/steamcmd/steamcmd.sh

    migrate_steamcmd_dir
    [ -x /srv/cs2/steamcmd/steamcmd.sh ] && [ ! -e /srv/cs2/server/steamcmd ] \
        && pass "SteamCMD перенесён из общего каталога" || fail "SteamCMD не перенесён"

    STEAM_USER=anonymous install_or_update >/dev/null 2>&1
    grep -q '+login anonymous +app_update 730' /tmp/steamcmd.args && pass "anonymous — как раньше, аргументами" \
        || fail "anonymous: $(cat /tmp/steamcmd.args)"

    STEAM_USER=bob STEAM_PASS='s3cr$t pass' STEAM_AUTH=X1Y2 EXTRA_FLAGS='-beta test' install_or_update >/dev/null 2>&1
    grep -q 's3cr' /tmp/steamcmd.args && fail "пароль в аргументах: $(cat /tmp/steamcmd.args)" \
        || pass "пароля нет в аргументах ($(cat /tmp/steamcmd.args))"
    grep -qx 'login bob s3cr$t pass X1Y2' /tmp/steamcmd.script && grep -qx 'app_update 730 -beta test' /tmp/steamcmd.script \
        && pass "логин и флаги — в runscript" || fail "runscript: $(cat /tmp/steamcmd.script)"
    [ "$(cat /tmp/steamcmd.mode)" = "600" ] && pass "runscript с правами 600" || fail "права runscript: $(cat /tmp/steamcmd.mode)"
    ls /run/cs2-steamcmd.* >/dev/null 2>&1 && fail "runscript не удалён" || pass "runscript удалён после запуска"

    rc=0; SLEEP=5 install_or_update 1 >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 124 ] && pass "зависший SteamCMD остановлен по таймауту" || fail "таймаут: код $rc"
    rc=0; EXIT=8 install_or_update >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 8 ] && pass "код ошибки SteamCMD не теряется" || fail "код ошибки: $rc"
) || fail "блок SteamCMD упал"

echo "== панель: серверы ноды по всем страницам"
python3 - <<'PY' &
import http.server, json, urllib.parse
def srv(i, node, image, port):
    return {"attributes": {"identifier": "s%d" % i, "node": node, "container": {"image": image},
            "relationships": {"allocations": {"data": [{"attributes": {"port": port}}]}}}}
pages = {
    1: [srv(1, 1, "docker.io/scrender/base-files-cs2:latest", 27015),
        srv(2, 2, "docker.io/scrender/base-files-cs2:latest", 27016)],
    2: [srv(3, 1, "docker.io/scrender/base-files-cs2:dev", 27017),
        srv(4, 1, "ghcr.io/other/minecraft:java", 25565)],
}
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        p = int(q.get("page", ["1"])[0])
        body = json.dumps({"data": pages.get(p, []), "meta": {"pagination": {"total_pages": 2}}}).encode()
        self.send_response(200); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", 8000), H).serve_forever()
PY
sleep 1
(
    cd "$work"
    source ./utils/managerPelican.sh
    trap - ERR
    export PELICAN_URL=http://127.0.0.1:8000 PELICAN_APP_TOKEN=papp_x PELICAN_NODE_ID=1 \
        PELICAN_IMAGE=docker.io/scrender/base-files-cs2:latest
    ids="$(get_servers_by_image_app "$PELICAN_IMAGE" | paste -sd' ' -)"
    [ "$ids" = "s1 s3" ] && pass "updater видит :dev и вторую страницу ($ids)" || fail "серверы: '$ids'"
    ports="$(pelican_node_ports | paste -sd' ' -)"
    [ "$ports" = "27015 27017" ] && pass "порты для guard ($ports)" || fail "порты: '$ports'"
    PELICAN_URL=http://127.0.0.1:8999
    get_servers_by_image_app "$PELICAN_IMAGE" >/dev/null 2>/tmp/err && fail "недоступная панель — успех?" \
        || { grep -q 'HTTP 000' /tmp/err && pass "недоступная панель: ошибка с кодом в логе" || fail "лог: $(cat /tmp/err)"; }
) || fail "блок панели упал"

echo "== verify_servers_started: список для повторного старта"
(
    cd "$work"
    source ./utils/managerSteamCMD.sh
    source ./utils/version.sh
    trap - ERR
    server_state() { [ "$1" = ok1 ] && printf running || printf offline; }
    sleep() { :; }
    verify_servers_started $'ok1\nbad1\nbad2' 1 >/dev/null 2>&1 && fail "провал не замечен" || true
    [ "$VERIFY_PENDING" = $'bad1\nbad2\n' ] && pass "не поднявшиеся — в VERIFY_PENDING" \
        || fail "VERIFY_PENDING='$VERIFY_PENDING'"
) || fail "блок verify упал"

echo "== update.sh: своя установка, а не чужой start.sh; без sha256 не ставит"
mkdir -p /etc/systemd/system /opt/aaa-other /opt/cs2-updater /tmp/rel /tmp/dist/cs2-updater
echo 'echo other' > /opt/aaa-other/start.sh
printf '[Service]\nExecStart=/opt/aaa-other/start.sh\nWorkingDirectory=/opt/aaa-other\n' > /etc/systemd/system/aaa-other.service
printf '[Service]\nExecStart=/opt/cs2-updater/start.sh\nWorkingDirectory=/opt/cs2-updater\n' > /etc/systemd/system/cs2-updater.service
cp -r /src/service/. /opt/cs2-updater/; echo v1.0.0 > /opt/cs2-updater/VERSION; echo 'X=1' > /opt/cs2-updater/.env
cp -r /src/service/. /tmp/dist/cs2-updater/; cp /src/update.sh /tmp/dist/cs2-updater/; echo v9.9.9 > /tmp/dist/cs2-updater/VERSION
tar --owner=0 --group=0 -czf /tmp/rel/cs2-updater.tar.gz -C /tmp/dist cs2-updater

out="$(BASE_URL=file:///tmp/rel bash /src/update.sh 2>&1 || true)"
grep -q 'Каталог: /opt/cs2-updater' <<<"$out" && pass "выбран каталог CS2 Updater, чужой start.sh пропущен" \
    || fail "каталог: $(grep Каталог <<<"$out")"
grep -q 'Нет файла с контрольной суммой' <<<"$out" && [ "$(cat /opt/cs2-updater/VERSION)" = v1.0.0 ] \
    && pass "без .sha256 обновление отменено" || fail "без sha256: $(tail -n 3 <<<"$out")"
[ "$(cat /opt/aaa-other/start.sh)" = "echo other" ] && pass "чужой каталог не тронут" || fail "чужой каталог изменён"

INSECURE=1 BASE_URL=file:///tmp/rel bash /src/update.sh >/dev/null 2>&1 || true
[ "$(cat /opt/cs2-updater/VERSION)" = v9.9.9 ] && pass "INSECURE=1 — обновляет" || fail "INSECURE=1 не обновил"

(cd /tmp/rel && sha256sum cs2-updater.tar.gz > cs2-updater.tar.gz.sha256)
echo v1.0.0 > /opt/cs2-updater/VERSION
BASE_URL=file:///tmp/rel bash /src/update.sh >/dev/null 2>&1 || true
[ "$(cat /opt/cs2-updater/VERSION)" = v9.9.9 ] && pass "с верной sha256 — обновляет" || fail "с sha256 не обновил"
sed -i 's/^./0/' /tmp/rel/cs2-updater.tar.gz.sha256   # портим сумму
echo v1.0.0 > /opt/cs2-updater/VERSION
BASE_URL=file:///tmp/rel bash /src/update.sh >/dev/null 2>&1 || true
[ "$(cat /opt/cs2-updater/VERSION)" = v1.0.0 ] && pass "неверная sha256 — отказ" || fail "неверная sha256 пропущена"

echo
[ "$FAIL" -eq 0 ] && echo "service: всё в порядке" || { echo "service: провалов — $FAIL"; exit 1; }
