# console.awk — поток консоли одного CS2-сервера: `docker logs -f --timestamps`.
#
#   awk -v dir=<каталог журнала> -v secret=<GSLT> -v wl="<ip ip …>" -f console.awk
#
# Делает три вещи:
#   1. пишет журнал по дням (dir/ГГГГ-ММ-ДД.log, даты UTC): управляющие символы
#      вырезаны, GSLT и пароли из rcon_password/sv_password/… замаскированы;
#   2. на маркер entrypoint `[cs2-crash] code=N` печатает событие `CRASH N`;
#   3. правила защиты по консоли (семь правил и пороги — из guard.json
#      K4ryuu/CS2-Egg-Go, GPLv3) печатают `HIT <правило> <ip|-> <минут> <uid>`.
#
# ВСЁ здесь — недоверенные данные: строку пишет игра, а внутри неё — ник игрока,
# которым он может назвать себя как угодно. Поэтому правило сопоставляется только
# с НАЧАЛОМ текста, который написал сам движок (после короткого тега канала вроде
# `[Data] `), а адрес берётся из той же части строки. Игрок с ником
# «Ignored bad 9.9.9.9:1 Invalid a byte» в Egg-Go когда-то банил чужой адрес на
# сутки. Что напечатает плагин владельца сервера — тоже не доверяем: события
# отсюда блокируют адрес только на портах ЭТОГО сервера (это решает watch.sh).
#
# Только POSIX awk: на Debian/Ubuntu по умолчанию mawk (без gawk-расширений).

BEGIN {
    # правило  порог  окно, с  бан, мин
    nr = split("reconnect_stuck 3 15 360|move_not_joined 5 15 360|stray_no_connection 4 10 30|" \
               "connect_flood 6 10 30|rcon_bruteforce 1 10 1440|malformed_packet 2 10 1440|" \
               "stuck_no_full 3 10 60", rr, "|")
    for (i = 1; i <= nr; i++) {
        split(rr[i], f, " ")
        TH[f[1]] = f[2] + 0; WIN[f[1]] = f[3] + 0; BAN[f[1]] = f[4] + 0
    }
    COOLDOWN = 30          # секунд между двумя реакциями на один адрес
    GRACE = 12             # секунд с подключения, прежде чем keepalive без входа подозрителен
    nw = split(wl, w, /[ ,]+/)
    for (i = 1; i <= nw; i++) if (w[i] != "") WL[w[i]] = 1
    cur = ""; last = -1; offset = 0; swept = 0
}

# секунды от «ЧЧ:ММ:СС» с учётом перехода через полночь
function tick(hms,   t) {
    t = substr(hms, 1, 2) * 3600 + substr(hms, 4, 2) * 60 + substr(hms, 7, 2)
    if (last >= 0 && t + offset < last - 43200) offset += 86400
    last = t + offset
    return last
}

function rindex(s, t,   p, q) {
    p = 0
    while ((q = index(substr(s, p + 1), t)) > 0) p += q
    return p
}

function mask(s,   p, m) {
    if (secret != "")
        while ((p = index(s, secret)) > 0)
            s = substr(s, 1, p - 1) "********" substr(s, p + length(secret))
    if (s ~ /_password|setsteamaccount/ \
        && match(s, /(rcon_password|sv_password|sv_setsteamaccount|sv_downloadurl_password)"?[ \t]*=?[ \t]*("[^"]*"|[^ \t"]+)/)) {
        m = substr(s, RSTART, RLENGTH)
        sub(/("[^"]*"|[^ \t"]+)$/, "********", m)
        s = substr(s, 1, RSTART - 1) m substr(s, RSTART + RLENGTH)
    }
    return s
}

# Текст движка без тега канала: «[Data] Ignored bad …» → «Ignored bad …».
# Тег короткий и без ':' '@' '#', поэтому «[#99 UDP steamid:…]» не трогается.
function engine(s) {
    if (match(s, /^\[[A-Za-z0-9_. -]+\][ \t]*/) && RLENGTH <= 24) return substr(s, RLENGTH + 1)
    return s
}

function ip_in(s,   t) {
    if (!match(s, /[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/)) return ""
    return substr(s, RSTART, RLENGTH)
}

function private_ip(ip) {
    return ip ~ /^(10\.|127\.|0\.|192\.168\.|169\.254\.|172\.(1[6-9]|2[0-9]|3[01])\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.)/
}

function trusted(uid) {
    return (uid in CL_TRUSTED) || ((uid in CL_IP) && (CL_IP[uid] in IP_TRUSTED))
}

# скользящее окно; 1 — порог правила достигнут
function bump(rule, key,   k) {
    k = rule SUBSEP key
    if (!(k in CNT) || now - CSTART[k] > WIN[rule]) { CNT[k] = 1; CSTART[k] = now }
    else CNT[k]++
    return CNT[k] >= TH[rule]
}

function react(rule, uid, ip,   ck) {
    if (ip != "" && (private_ip(ip) || (ip in WL))) return
    if (uid > 0 && trusted(uid)) return
    if (ip == "" && uid <= 0) return
    ck = (ip != "") ? ip : "uid" uid
    if ((ck in COOL) && now - COOL[ck] < COOLDOWN) return
    COOL[ck] = now
    print "HIT " rule " " ((ip != "") ? ip : "-") " " BAN[rule] " " (uid + 0)
    fflush()
}

# состояние по адресам задаёт посторонний: без чистки флуд с тысяч адресов
# жил бы в памяти до конца контейнера
function sweep(   k) {
    for (k in CSTART) if (now - CSTART[k] > 300) { delete CSTART[k]; delete CNT[k] }
    for (k in COOL) if (now - COOL[k] > 300) delete COOL[k]
    for (k in SINCE) if (now - SINCE[k] > 900) { delete SINCE[k]; if (!(k in IP_TRUSTED)) delete IP2UID[k] }
}

function inspect(line,   body, p, q, q0, uid, name, ip) {
    body = engine(line)

    # --- кто есть кто: подключение, вход, выход ---
    if (body ~ /^CServerSideClientBase::Connect\( name='/) {
        p = rindex(body, "', userid=")
        q = rindex(body, "chan->addr=")
        if (p > 0 && q > p) {
            q0 = index(body, "name='") + 6
            name = substr(body, q0, p - q0)
            uid = substr(body, p + 10) + 0
            ip = ip_in(substr(body, q + 11))
            if (ip != "" && uid > 0) { CL_IP[uid] = ip; IP2UID[ip] = uid; NAME2UID[name] = uid; delete CL_TRUSTED[uid] }
        }
        return
    }
    if (body ~ /^Client [0-9]+ '/ && (p = rindex(body, "' signon state ")) > 0) {
        uid = substr(body, 8) + 0
        name = substr(body, index(body, "'") + 1, p - index(body, "'") - 1)
        NAME2UID[name] = uid
        q = rindex(body, "-> SIGNONSTATE_")
        if (q > 0 && substr(body, q + 15) ~ /^FULL/) {
            CL_TRUSTED[uid] = 1
            if (uid in CL_IP) IP_TRUSTED[CL_IP[uid]] = 1
        }
        return
    }
    if (body ~ /^SV:  Dropped client '/ && (p = rindex(body, "' from server")) > 0) {
        q0 = index(body, "'") + 1
        name = substr(body, q0, p - q0)
        if (name in NAME2UID) {
            uid = NAME2UID[name]
            if (uid in CL_IP) { ip = CL_IP[uid]; delete IP2UID[ip]; delete IP_TRUSTED[ip]; delete SINCE[ip] }
            delete CL_IP[uid]; delete CL_TRUSTED[uid]; delete NAME2UID[name]
        }
        return
    }
    if (body ~ /^Accepting Steam Net connection /) {
        if ((p = index(body, "@")) > 0) {
            ip = ip_in(substr(body, p + 1))
            if (ip != "" && !(ip in SINCE)) SINCE[ip] = now
        }
        return
    }

    # --- правила ---
    if (substr(body, 1, 12) == "Ignored bad ") {
        ip = ip_in(substr(body, 13))
        if (ip == "") return
        if (index(body, "Stray data packet from host with no connection") > 0) {
            # отвалившийся или переподключающийся игрок выглядит так же — пару секунд
            if (!(ip in IP_TRUSTED) && bump("stray_no_connection", ip)) react("stray_no_connection", 0, ip)
            return
        }
        if (body ~ /Invalid [A-Za-z0-9_]+ byte/) {
            if (bump("malformed_packet", ip)) react("malformed_packet", 0, ip)
            return
        }
        return
    }
    if (body ~ /^Receiving C2S_CONNECT /) {
        p = rindex(body, " from ")
        ip = (p > 0) ? ip_in(substr(body, p + 6)) : ""
        if (ip != "" && !(ip in IP_TRUSTED) && bump("connect_flood", ip)) react("connect_flood", (ip in IP2UID) ? IP2UID[ip] : 0, ip)
        return
    }
    if (body ~ /^Banning [0-9.]+ for rcon hacking attempts/) {
        ip = ip_in(substr(body, 9))
        if (ip != "" && bump("rcon_bruteforce", ip)) react("rcon_bruteforce", 0, ip)
        return
    }
    if (line ~ /^(SV:[ \t]+)?Forcing client reconnect / && (p = rindex(line, "for client '")) > 0) {
        name = substr(line, p + 12); sub(/'$/, "", name)
        uid = (name in NAME2UID) ? NAME2UID[name] : 0
        if (!trusted(uid) && bump("reconnect_stuck", "n" name)) react("reconnect_stuck", uid, (uid in CL_IP) ? CL_IP[uid] : "")
        return
    }
    if (line ~ /^\[.*\] sent command that failed delta decode/) {
        p = rindex(line, "] sent command that failed delta decode")
        name = substr(line, 2, p - 2)
        uid = (name in NAME2UID) ? NAME2UID[name] : 0
        if (!trusted(uid) && bump("move_not_joined", "n" name)) react("move_not_joined", uid, (uid in CL_IP) ? CL_IP[uid] : "")
        return
    }
    if (index(line, "Sending keepalive") > 0 && (p = index(line, "@")) > 0) {
        # первый «@адрес» в строке — от движка: ник стоит после адреса
        ip = ip_in(substr(line, p + 1))
        if (ip == "" || (ip in IP_TRUSTED)) return
        uid = (ip in IP2UID) ? IP2UID[ip] : 0
        if (uid > 0 && trusted(uid)) return
        if (!(ip in SINCE) || now - SINCE[ip] >= GRACE)
            if (bump("stuck_no_full", ip)) react("stuck_no_full", uid, ip)
        return
    }
}

{
    sp = index($0, " ")
    if (sp == 0) next
    day = substr($0, 1, 10)
    hms = substr($0, 12, 8)
    line = substr($0, sp + 1)
    gsub(/\r/, "", line)
    gsub(/\033\[[0-9;?]*[A-Za-z]/, "", line)
    gsub(/[\001-\010\013-\037\177]/, "", line)
    if (length(line) > 4096) line = substr(line, 1, 4096)
    line = mask(line)

    if (day ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/) {
        logf = dir "/" day ".log"
        if (logf != cur) { if (cur != "") close(cur); cur = logf }
        print hms " " line >> cur
        fflush(cur)
    }

    now = tick(hms)
    if (now - swept > 30) { swept = now; sweep() }

    if (line ~ /^\[cs2-crash\] code=[0-9]+$/) {
        print "CRASH " substr(line, length("[cs2-crash] code=") + 1)
        fflush()
        next
    }
    inspect(line)
}
