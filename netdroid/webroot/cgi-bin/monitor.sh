#!/system/bin/sh
# NetDroid - Network Speed, Data Quota, Connected Clients & System Telemetry Engine

export PATH="/data/adb/ksu/bin:/data/adb/ap/bin:/data/adb/magisk:/system/bin:/system/xbin:/vendor/bin:$PATH"

DATA_DIR="/data/adb/netdroid"
CONFIG_FILE="$DATA_DIR/config.env"
QUOTA_FILE="$DATA_DIR/quota.json"
QUOTA_LOCK="$DATA_DIR/.quota.lock"
SPEED_STATE="$DATA_DIR/.speed_state"
DHCP_CACHE="$DATA_DIR/.dhcp_cache"
RULES_FILE="$DATA_DIR/firewall.rules"
RESTRICTED_LIST="$DATA_DIR/restricted_apps.list"

detect_bb() {
    for b in /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox /data/adb/magisk/busybox; do
        if [ -x "$b" ]; then
            echo "$b"
            return 0
        fi
    done
    command -v busybox 2>/dev/null
}

BB="$(detect_bb)"
AWK="${BB:+$BB awk}"; [ -z "$AWK" ] && AWK="awk"
SED="${BB:+$BB sed}"; [ -z "$SED" ] && SED="sed"
GREP="${BB:+$BB grep}"; [ -z "$GREP" ] && GREP="grep"
TR="${BB:+$BB tr}"; [ -z "$TR" ] && TR="tr"
FLOCK="${BB:+$BB flock}"

# Defaults
PORT=8765
MODE="normal"
TTL=65
MANGLE_TTL=1
QUOTA_DAILY_MB=2048
QUOTA_MONTHLY_MB=30720
QUOTA_WARN_PCT=80
QUOTA_CRIT_PCT=90

if [ -f "$CONFIG_FILE" ]; then
    . "$CONFIG_FILE" 2>/dev/null
fi

mkdir -p "$DATA_DIR" 2>/dev/null

# Read /proc/net/dev once and print: cell_rx cell_tx hs_rx hs_tx cell_ifaces hs_ifaces
read_net_counters() {
    $AWK '
    NR <= 2 { next }
    {
        gsub(/:/, " ", $0)
        iface = $1
        rx = $2 + 0
        tx = $10 + 0

        # Cellular PDN interfaces (exclude rmnet_ipa* and r_rmnet* to avoid double-counting)
        if (iface ~ /^(rmnet_data[0-9]+|rmnet[0-9]+|ccmni[0-9]+|wwan[0-9]+|pdp[0-9]+)$/) {
            c_rx += rx
            c_tx += tx
            if (rx > 0 || tx > 0) {
                if (c_if != "") c_if = c_if ","
                c_if = c_if iface
            }
        } else if (iface ~ /^rmnet_ipa[0-9]+$/) {
            ipa_rx += rx
            ipa_tx += tx
        }

        # Hotspot / Tethering downstream interfaces
        if (iface ~ /^(ap[0-9]+|swlan[0-9]+|softap[0-9]+|wlan[1-9][0-9]*|rndis[0-9]+|usb[0-9]+|ncm[0-9]+)$/) {
            h_rx += rx
            h_tx += tx
            if (rx > 0 || tx > 0) {
                if (h_if != "") h_if = h_if ","
                h_if = h_if iface
            }
        }
    }
    END {
        if (c_rx == 0 && c_tx == 0 && (ipa_rx > 0 || ipa_tx > 0)) {
            c_rx = ipa_rx; c_tx = ipa_tx; c_if = "rmnet_ipa0"
        }
        if (c_if == "") c_if = "none"
        if (h_if == "") h_if = "none"
        printf "%.0f %.0f %.0f %.0f %s %s\n", c_rx, c_tx, h_rx, h_tx, c_if, h_if
    }
    ' /proc/net/dev 2>/dev/null
}

# Atomically update persistent quota.json
_do_update_quota() {
    counters="$(read_net_counters)"
    set -- $counters
    c_rx="${1:-0}"; c_tx="${2:-0}"; h_rx="${3:-0}"; h_tx="${4:-0}"
    today="$(date +%Y-%m-%d 2>/dev/null || echo '1970-01-01')"
    month="$(date +%Y-%m 2>/dev/null || echo '1970-01')"
    now="$(date +%s 2>/dev/null || echo 0)"

    if [ ! -s "$QUOTA_FILE" ]; then
        printf '{"session_rx":0,"session_tx":0,"daily_rx":0,"daily_tx":0,"monthly_rx":0,"monthly_tx":0,"hotspot_session_rx":0,"hotspot_session_tx":0,"day_key":"%s","month_key":"%s","session_started":%s,"last_cell_rx":%s,"last_cell_tx":%s,"last_hs_rx":%s,"last_hs_tx":%s,"last_ts":%s}\n' \
            "$today" "$month" "$now" "$c_rx" "$c_tx" "$h_rx" "$h_tx" "$now" > "$QUOTA_FILE"
        return 0
    fi

    tmp="$DATA_DIR/.quota.json.tmp.$$"
    $AWK -v c_rx="$c_rx" -v c_tx="$c_tx" -v h_rx="$h_rx" -v h_tx="$h_tx" \
         -v today="$today" -v month="$month" -v now="$now" '
    function getnum(s, k,    m, r) {
        r = "\"" k "\":[0-9.eE+-]+"
        if (match(s, r)) {
            m = substr(s, RSTART, RLENGTH)
            sub(/^[^:]+:/, "", m)
            return m + 0
        }
        return 0
    }
    function getstr(s, k,    m, r) {
        r = "\"" k "\":\"[^\"]*\""
        if (match(s, r)) {
            m = substr(s, RSTART, RLENGTH)
            sub(/^[^:]+:"/, "", m)
            sub(/"$/, "", m)
            return m
        }
        return ""
    }
    {
        line = line $0
    }
    END {
        s_rx = getnum(line, "session_rx")
        s_tx = getnum(line, "session_tx")
        d_rx = getnum(line, "daily_rx")
        d_tx = getnum(line, "daily_tx")
        m_rx = getnum(line, "monthly_rx")
        m_tx = getnum(line, "monthly_tx")
        hs_rx = getnum(line, "hotspot_session_rx")
        hs_tx = getnum(line, "hotspot_session_tx")
        dk = getstr(line, "day_key")
        mk = getstr(line, "month_key")
        s_start = getnum(line, "session_started")
        lc_rx = getnum(line, "last_cell_rx")
        lc_tx = getnum(line, "last_cell_tx")
        lh_rx = getnum(line, "last_hs_rx")
        lh_tx = getnum(line, "last_hs_tx")

        # First-time baseline sync (if last_cell was 0 while interface already had gigabytes)
        if (lc_rx == 0 && lc_tx == 0 && s_rx == 0 && d_rx == 0 && m_rx == 0) {
            dc_rx = 0; dc_tx = 0
        } else {
            dc_rx = (c_rx >= lc_rx) ? (c_rx - lc_rx) : c_rx
            dc_tx = (c_tx >= lc_tx) ? (c_tx - lc_tx) : c_tx
        }

        if (lh_rx == 0 && lh_tx == 0 && hs_rx == 0) {
            dh_rx = 0; dh_tx = 0
        } else {
            dh_rx = (h_rx >= lh_rx) ? (h_rx - lh_rx) : h_rx
            dh_tx = (h_tx >= lh_tx) ? (h_tx - lh_tx) : h_tx
        }

        # Roll over day/month boundaries
        if (dk != "" && dk != today) {
            d_rx = 0; d_tx = 0
        }
        if (mk != "" && mk != month) {
            m_rx = 0; m_tx = 0
        }
        if (s_start == 0) s_start = now

        s_rx += dc_rx; s_tx += dc_tx
        d_rx += dc_rx; d_tx += dc_tx
        m_rx += dc_rx; m_tx += dc_tx
        hs_rx += dh_rx; hs_tx += dh_tx

        printf "{\"session_rx\":%.0f,\"session_tx\":%.0f,\"daily_rx\":%.0f,\"daily_tx\":%.0f,\"monthly_rx\":%.0f,\"monthly_tx\":%.0f,\"hotspot_session_rx\":%.0f,\"hotspot_session_tx\":%.0f,\"day_key\":\"%s\",\"month_key\":\"%s\",\"session_started\":%.0f,\"last_cell_rx\":%.0f,\"last_cell_tx\":%.0f,\"last_hs_rx\":%.0f,\"last_hs_tx\":%.0f,\"last_ts\":%.0f}\n", \
            s_rx, s_tx, d_rx, d_tx, m_rx, m_tx, hs_rx, hs_tx, today, month, s_start, c_rx, c_tx, h_rx, h_tx, now
    }
    ' "$QUOTA_FILE" > "$tmp" && mv "$tmp" "$QUOTA_FILE"
    chmod 0644 "$QUOTA_FILE" 2>/dev/null || true
}

update_quota() {
    if [ -n "$FLOCK" ]; then
        $FLOCK -w 3 "$QUOTA_LOCK" sh -c "
            export PATH=\"$PATH\"
            \"$0\" _update_quota_locked
        " 2>/dev/null || _do_update_quota
    else
        _do_update_quota
    fi
}

reset_quota() {
    scope="${1:-session}"
    update_quota
    now="$(date +%s 2>/dev/null || echo 0)"
    tmp="$DATA_DIR/.quota.json.tmp.$$"
    $AWK -v scope="$scope" -v now="$now" '
    function getnum(s, k,    m, r) {
        r = "\"" k "\":[0-9.eE+-]+"
        if (match(s, r)) { m = substr(s, RSTART, RLENGTH); sub(/^[^:]+:/, "", m); return m + 0 }
        return 0
    }
    function getstr(s, k,    m, r) {
        r = "\"" k "\":\"[^\"]*\""
        if (match(s, r)) { m = substr(s, RSTART, RLENGTH); sub(/^[^:]+:"/, "", m); sub(/"$/, "", m); return m }
        return ""
    }
    { line = line $0 }
    END {
        s_rx = getnum(line, "session_rx"); s_tx = getnum(line, "session_tx")
        d_rx = getnum(line, "daily_rx");   d_tx = getnum(line, "daily_tx")
        m_rx = getnum(line, "monthly_rx"); m_tx = getnum(line, "monthly_tx")
        hs_rx = getnum(line, "hotspot_session_rx"); hs_tx = getnum(line, "hotspot_session_tx")
        dk = getstr(line, "day_key"); mk = getstr(line, "month_key")
        s_start = getnum(line, "session_started")
        lc_rx = getnum(line, "last_cell_rx"); lc_tx = getnum(line, "last_cell_tx")
        lh_rx = getnum(line, "last_hs_rx");   lh_tx = getnum(line, "last_hs_tx")

        if (scope == "session" || scope == "all") { s_rx = 0; s_tx = 0; hs_rx = 0; hs_tx = 0; s_start = now }
        if (scope == "daily"   || scope == "all") { d_rx = 0; d_tx = 0 }
        if (scope == "monthly" || scope == "all") { m_rx = 0; m_tx = 0 }

        printf "{\"session_rx\":%.0f,\"session_tx\":%.0f,\"daily_rx\":%.0f,\"daily_tx\":%.0f,\"monthly_rx\":%.0f,\"monthly_tx\":%.0f,\"hotspot_session_rx\":%.0f,\"hotspot_session_tx\":%.0f,\"day_key\":\"%s\",\"month_key\":\"%s\",\"session_started\":%.0f,\"last_cell_rx\":%.0f,\"last_cell_tx\":%.0f,\"last_hs_rx\":%.0f,\"last_hs_tx\":%.0f,\"last_ts\":%.0f}\n", \
            s_rx, s_tx, d_rx, d_tx, m_rx, m_tx, hs_rx, hs_tx, dk, mk, s_start, lc_rx, lc_tx, lh_rx, lh_tx, now
    }
    ' "$QUOTA_FILE" > "$tmp" && mv "$tmp" "$QUOTA_FILE"
    printf '{"ok":true,"reset":"%s"}\n' "$scope"
}

# Refresh cached DHCP hostnames from legacy dnsmasq.leases AND Android 11-16 NetworkStack
refresh_dhcp_cache() {
    force="$1"
    now="$(date +%s 2>/dev/null || echo 0)"
    if [ "$force" != "1" ] && [ -f "$DHCP_CACHE" ]; then
        mtime="$($BB stat -c %Y "$DHCP_CACHE" 2>/dev/null || echo 0)"
        age=$((now - mtime))
        if [ "$age" -ge 0 ] && [ "$age" -lt 12 ]; then
            return 0
        fi
    fi

    tmp="$DATA_DIR/.dhcp_cache.tmp.$$"
    : > "$tmp"

    # 1. Legacy dnsmasq leases (Android 10 & custom ROMs)
    for lf in /data/misc/apexdata/com.android.tethering/dnsmasq.leases /data/misc/dhcp/dnsmasq.leases; do
        if [ -r "$lf" ]; then
            $AWK '{
                # Format: expiry mac ip hostname clientid
                if (NF >= 4) {
                    printf "%s|%s|%s|%s\n", tolower($2), $3, $4, $1
                }
            }' "$lf" >> "$tmp" 2>/dev/null
        fi
    done

    # 2. Modern Android NetworkStack Java DhcpServer logs (Android 11-16+)
    dumpsys network_stack 2>/dev/null | $AWK '
    /Transmitting DhcpAckPacket|created\/renewed lease/ {
        mac = ""; ip = ""; host = ""; lexp = ""
        if (match($0, /hwAddr:[[:space:]]*([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}/)) {
            mac = substr($0, RSTART, RLENGTH)
            sub(/^hwAddr:[[:space:]]*/, "", mac)
            mac = tolower(mac)
        }
        if (match($0, /netAddr:[[:space:]]*[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/)) {
            ip = substr($0, RSTART, RLENGTH)
            sub(/^netAddr:[[:space:]]*/, "", ip)
        }
        if (match($0, /hostname:[[:space:]]*[^,[:space:]]+/)) {
            host = substr($0, RSTART, RLENGTH)
            sub(/^hostname:[[:space:]]*/, "", host)
        }
        if (match($0, /expTime:[[:space:]]*[0-9]+/)) {
            lexp = substr($0, RSTART, RLENGTH)
            sub(/^expTime:[[:space:]]*/, "", lexp)
        }
        if (mac != "") {
            last_ip[mac] = ip
            if (host != "" && host != "null" && host != "*") last_host[mac] = host
            last_exp[mac] = lexp
        }
    }
    END {
        for (m in last_ip) {
            printf "%s|%s|%s|%s\n", m, last_ip[m], (last_host[m] != "" ? last_host[m] : "*"), last_exp[m]
        }
    }
    ' >> "$tmp" 2>/dev/null

    mv "$tmp" "$DHCP_CACHE" 2>/dev/null || true
}

# List connected LAN/hotspot clients as JSON
get_clients_json() {
    refresh_dhcp_cache "$1"
    [ -f "$DHCP_CACHE" ] || : > "$DHCP_CACHE"
    [ -f "$RULES_FILE" ] || : > "$RULES_FILE"
    neigh_tmp="$DATA_DIR/.neigh.$$"
    ip neigh show 2>/dev/null > "$neigh_tmp"

    $AWK -v f_dhcp="$DHCP_CACHE" -v f_rules="$RULES_FILE" -v f_neigh="$neigh_tmp" '
    function esc(s) {
        gsub(/\\/, "\\\\", s)
        gsub(/"/, "\\\"", s)
        gsub(/\r|\n/, "", s)
        return s
    }
    function conn_type(iface) {
        if (iface ~ /^(rndis|usb|ncm)/) return "USB Tethering"
        return "Wi-Fi Hotspot"
    }
    # File 1: DHCP cache (mac|ip|host|exp)
    FILENAME == f_dhcp {
        split($0, a, "|")
        m = tolower(a[1])
        if (m != "") {
            if (a[2] != "") dhcp_ip[m] = a[2]
            if (a[3] != "" && a[3] != "*" && a[3] != "null") dhcp_host[m] = a[3]
            if (a[4] != "") dhcp_exp[m] = a[4]
        }
        next
    }
    # File 2: firewall.rules (CLIENT|mac|ip|host|blocked)
    FILENAME == f_rules {
        split($0, a, "|")
        if (a[1] == "CLIENT" && a[5] == "1") {
            bm = tolower(a[2])
            blocked_mac[bm] = 1
            blocked_ip[bm] = a[3]
            blocked_host[bm] = a[4]
        }
        next
    }
    # File 3: ip neigh show
    FILENAME == f_neigh {
        ip = $1
        dev = ""; mac = ""; state = $NF
        for (i = 2; i <= NF; i++) {
            if ($i == "dev" && i + 1 <= NF) dev = $(i+1)
            if ($i == "lladdr" && i + 1 <= NF) mac = tolower($(i+1))
        }
        # Only hotspot / LAN / USB tether interfaces
        if (dev !~ /^(wlan|ap|swlan|softap|rndis|usb|ncm)/) next
        if (mac == "" || mac == "00:00:00:00:00:00") next
        if (state == "FAILED" || state == "INCOMPLETE") next

        seen[mac] = 1
        c_dev[mac] = dev
        if (ip ~ /:/) {
            if (c_ipv6[mac] == "" || ip !~ /^fe80:/) c_ipv6[mac] = ip
        } else {
            c_ipv4[mac] = ip
        }
        # Prefer REACHABLE over DELAY/PROBE over STALE
        if (c_state[mac] == "" || state == "REACHABLE" || (c_state[mac] == "STALE" && state != "STALE")) {
            c_state[mac] = state
        }
    }
    END {
        # Include any blocked clients not currently in neigh table so user can unblock them
        for (bm in blocked_mac) {
            if (!(bm in seen)) {
                seen[bm] = 1
                c_ipv4[bm] = blocked_ip[bm]
                c_dev[bm] = "lan"
                c_state[bm] = "OFFLINE"
            }
        }

        printf "{\"ok\":true,\"clients\":["
        first = 1
        for (m in seen) {
            if (!first) printf ","
            first = 0
            ip4 = (c_ipv4[m] != "" ? c_ipv4[m] : dhcp_ip[m])
            ip6 = c_ipv6[m]
            host = dhcp_host[m]
            if (host == "" && blocked_host[m] != "") host = blocked_host[m]
            if (host == "") {
                n = split(m, oct, ":")
                suffix = (n >= 6) ? (oct[4] ":" oct[5] ":" oct[6]) : m
                host = "Device-" toupper(suffix)
            }
            blk = (m in blocked_mac) ? "true" : "false"
            iface = c_dev[m]
            ctype = conn_type(iface)
            st = (c_state[m] != "" ? c_state[m] : "STALE")
            lexp = (dhcp_exp[m] != "" ? dhcp_exp[m] : "")

            printf "{\"mac\":\"%s\",\"ipv4\":\"%s\",\"ipv6\":\"%s\",\"hostname\":\"%s\",\"interface\":\"%s\",\"connection_type\":\"%s\",\"status\":\"%s\",\"lease_expiry\":\"%s\",\"blocked\":%s}", \
                esc(m), esc(ip4), esc(ip6), esc(host), esc(iface), esc(ctype), esc(st), esc(lexp), blk
        }
        printf "]}\n"
    }
    ' "$DHCP_CACHE" "$RULES_FILE" "$neigh_tmp" 2>/dev/null

    rm -f "$neigh_tmp" 2>/dev/null
}

# Full real-time telemetry JSON for Dashboard polling
get_dashboard_json() {
    # 1. Read live counters and compute Rx/Tx speeds using /proc/uptime
    counters="$(read_net_counters)"
    set -- $counters
    c_rx="${1:-0}"; c_tx="${2:-0}"; h_rx="${3:-0}"; h_tx="${4:-0}"
    c_ifaces="${5:-none}"; h_ifaces="${6:-none}"

    up_sec="$($AWK '{print $1}' /proc/uptime 2>/dev/null || echo 0)"

    prev_up=0; prev_crx=0; prev_ctx=0; prev_hrx=0; prev_htx=0
    if [ -r "$SPEED_STATE" ]; then
        read -r prev_up prev_crx prev_ctx prev_hrx prev_htx < "$SPEED_STATE" 2>/dev/null || true
    fi
    printf '%s %s %s %s %s\n' "$up_sec" "$c_rx" "$c_tx" "$h_rx" "$h_tx" > "$SPEED_STATE.tmp.$$" && \
        mv "$SPEED_STATE.tmp.$$" "$SPEED_STATE"

    speeds="$($AWK -v u="$up_sec" -v pu="$prev_up" \
        -v crx="$c_rx" -v pcrx="$prev_crx" -v ctx="$c_tx" -v pctx="$prev_ctx" \
        -v hrx="$h_rx" -v phrx="$prev_hrx" -v htx="$h_tx" -v phtx="$prev_htx" '
    BEGIN {
        dt = u - pu
        if (pu == 0 || dt <= 0.05 || dt > 30) {
            printf "0 0 0 0\n"
            exit
        }
        drx = (crx >= pcrx) ? (crx - pcrx) / dt : 0
        dtx = (ctx >= pctx) ? (ctx - pctx) / dt : 0
        hr  = (hrx >= phrx) ? (hrx - phrx) / dt : 0
        ht  = (htx >= phtx) ? (htx - phtx) / dt : 0
        printf "%.0f %.0f %.0f %.0f\n", drx, dtx, hr, ht
    }')"
    set -- $speeds
    cell_rx_bps="${1:-0}"; cell_tx_bps="${2:-0}"; hs_rx_bps="${3:-0}"; hs_tx_bps="${4:-0}"

    # 2. Update quota snapshot
    update_quota

    quota_json='{}'
    [ -s "$QUOTA_FILE" ] && quota_json="$(cat "$QUOTA_FILE")"

    # 3. Gateway / LAN IPs for remote access display
    lan_ips="$(ip -4 -br addr 2>/dev/null | $AWK '
        $1 ~ /^(wlan|ap|swlan|softap|rndis|usb|ncm)/ && $2 != "DOWN" {
            for (i = 3; i <= NF; i++) {
                if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/) {
                    ip = $i; sub(/\/.*/, "", ip)
                    if (out != "") out = out ","
                    out = out "\"" $1 ":" ip "\""
                }
            }
        }
        END { printf "[%s]", out }
    ')"
    [ -z "$lan_ips" ] && lan_ips="[]"

    # 4. Battery telemetry + smart charging status
    bat_pct="$(cat /sys/class/power_supply/battery/capacity 2>/dev/null || echo 0)"
    bat_temp_raw="$(cat /sys/class/power_supply/battery/temp 2>/dev/null || echo 0)"
    bat_temp="$($AWK -v t="$bat_temp_raw" 'BEGIN { printf "%.1f", t / 10 }')"
    bat_status="$(cat /sys/class/power_supply/battery/status 2>/dev/null | $TR -d '\r\n')"
    [ -z "$bat_status" ] && bat_status="Unknown"

    bat_lim_en="false"; bat_stop=80; bat_paused="false"; bat_reason=""; bat_policy_active="false"
    bat_cfg="$DATA_DIR/config/battery.json"
    if [ -s "$bat_cfg" ]; then
        eval "$($AWK '
        function gb(s,k, m,r){ r="\""k"\"[[:space:]]*:[[:space:]]*(true|false)"; if(match(s,r)){m=substr(s,RSTART,RLENGTH); return (m~/true/)?"true":"false"} return "false" }
        function gn(s,k,d, m,r){ r="\""k"\"[[:space:]]*:[[:space:]]*[0-9]+"; if(match(s,r)){m=substr(s,RSTART,RLENGTH); sub(/^[^:]+:[[:space:]]*/,"",m); return m+0} return d }
        { l = l $0 }
        END {
            printf "bat_lim_en=%s; bat_stop=%d; bat_teth_only=%s\n", gb(l,"enabled"), gn(l,"stop_threshold",80), gb(l,"tethering_only")
        }' "$bat_cfg" 2>/dev/null)"
        if [ "$bat_lim_en" = "true" ]; then
            if [ "$bat_teth_only" != "true" ] || [ "$MODE" = "tethering" ]; then
                bat_policy_active="true"
            fi
        fi
    fi
    bat_st_file="$(cat "$DATA_DIR/.battery_state" 2>/dev/null | $TR -d '\r\n')"
    if [ "$bat_st_file" = "paused_thermal" ]; then
        bat_paused="true"; bat_reason="thermal"; bat_status="Thermal Guard"
    elif [ "$bat_st_file" = "paused_limit" ]; then
        bat_paused="true"; bat_reason="limit"
        if [ -r /sys/class/power_supply/battery/charging_enabled ] || [ -r /sys/class/power_supply/battery/battery_charging_enabled ]; then
            bat_status="Idle / Bypass"
        else
            bat_status="Paused"
        fi
    fi

    # DNS / Adblock summary
    dns_ad="false"; dns_force="false"; dns_cnt=0; dns_preset="adguard"
    dns_cfg="$DATA_DIR/config/dns.json"
    if [ -s "$dns_cfg" ]; then
        eval "$($AWK '
        function gb(s,k, m,r){ r="\""k"\"[[:space:]]*:[[:space:]]*(true|false)"; if(match(s,r)){m=substr(s,RSTART,RLENGTH); return (m~/true/)?"true":"false"} return "false" }
        function gn(s,k,d, m,r){ r="\""k"\"[[:space:]]*:[[:space:]]*[0-9]+"; if(match(s,r)){m=substr(s,RSTART,RLENGTH); sub(/^[^:]+:[[:space:]]*/,"",m); return m+0} return d }
        function gs(s,k,d, m,r){ r="\""k"\"[[:space:]]*:[[:space:]]*\"[^\"]*\""; if(match(s,r)){m=substr(s,RSTART,RLENGTH); sub(/^[^:]+:[[:space:]]*"/,"",m); sub(/"$/,"",m); return m} return d }
        { l = l $0 }
        END {
            printf "dns_ad=%s; dns_force=%s; dns_cnt=%d; dns_preset=%s\n", gb(l,"adblock_enabled"), gb(l,"force_router_dns"), gn(l,"blocked_domains_count",0), gs(l,"preset","adguard")
        }' "$dns_cfg" 2>/dev/null)"
    fi

    # 5. Kernel / Mode / TTL / Firewall summary
    cur_ttl="$(cat /proc/sys/net/ipv4/ip_default_ttl 2>/dev/null || echo 64)"
    cur_hl="$(cat /proc/sys/net/ipv6/conf/all/hop_limit 2>/dev/null || echo 64)"
    cur_fwd="$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo 0)"
    mangle_active="false"
    iptables -w 2 -t mangle -C POSTROUTING -j NETDROID_TTL 2>/dev/null && mangle_active="true"
    boundary_ok="false"
    iptables -w 2 -C INPUT -j NETDROID_IN 2>/dev/null && boundary_ok="true"

    rest_cnt=0
    [ -s "$RESTRICTED_LIST" ] && rest_cnt="$(wc -l < "$RESTRICTED_LIST" 2>/dev/null | $TR -d ' ')"
    [ -z "$rest_cnt" ] && rest_cnt=0
    app_blk_cnt="$($AWK '/^APP\|/{c++} END{print c+0}' "$RULES_FILE" 2>/dev/null)"
    cli_blk_cnt="$($AWK '/^CLIENT\|/{c++} END{print c+0}' "$RULES_FILE" 2>/dev/null)"
    [ -z "$app_blk_cnt" ] && app_blk_cnt=0
    [ -z "$cli_blk_cnt" ] && cli_blk_cnt=0

    # 6. Process count, RAM, Uptime, Connected clients count
    bg_procs="$(ps -A 2>/dev/null | $AWK '$1 ~ /^u0_a/ { c++ } END { print c+0 }')"
    mem_info="$($AWK '
        /^MemTotal:/ { t = $2 }
        /^MemAvailable:/ { a = $2 }
        END {
            used = (t > a) ? (t - a) : 0
            printf "%.0f %.0f", used / 1024, t / 1024
        }
    ' /proc/meminfo 2>/dev/null)"
    set -- $mem_info
    mem_used_mb="${1:-0}"; mem_total_mb="${2:-0}"

    clients_count="$(ip neigh show 2>/dev/null | $AWK '
        {
            dev = ""; mac = ""; st = $NF
            for (i = 2; i <= NF; i++) {
                if ($i == "dev") dev = $(i+1)
                if ($i == "lladdr") mac = tolower($(i+1))
            }
            if (dev ~ /^(wlan|ap|swlan|softap|rndis|usb|ncm)/ && mac != "" && mac != "00:00:00:00:00:00" && st != "FAILED" && st != "INCOMPLETE") {
                seen[mac] = 1
            }
        }
        END { c = 0; for (m in seen) c++; print c }
    ')"

    dev_model="$(getprop ro.product.model 2>/dev/null | $TR -d '\r\n')"
    dev_code="$(getprop ro.product.device 2>/dev/null | $TR -d '\r\n')"
    android_ver="$(getprop ro.build.version.release 2>/dev/null | $TR -d '\r\n')"

    printf '{"ok":true,"timestamp":%s,"mode":"%s","port":%s,"device":{"model":"%s","codename":"%s","android":"%s","uptime_sec":%s,"mem_used_mb":%s,"mem_total_mb":%s,"bg_app_procs":%s},"battery":{"percent":%s,"temp_c":%s,"status":"%s","limit_enabled":%s,"policy_active":%s,"stop_threshold":%s,"charging_paused":%s,"pause_reason":"%s"},"dns":{"adblock_enabled":%s,"force_router_dns":%s,"blocked_domains_count":%s,"preset":"%s"},"network":{"cell_rx_bps":%s,"cell_tx_bps":%s,"cell_rx_total":%s,"cell_tx_total":%s,"cell_ifaces":"%s","hs_rx_bps":%s,"hs_tx_bps":%s,"hs_rx_total":%s,"hs_tx_total":%s,"hs_ifaces":"%s","lan_ips":%s,"clients_count":%s},"ttl":{"configured":%s,"current_ipv4":%s,"current_ipv6":%s,"ip_forward":%s,"mangle_enabled":%s,"mangle_active":%s},"firewall":{"security_boundary":%s,"blocked_apps":%s,"blocked_clients":%s,"restricted_apps":%s},"quota":{"data":%s,"daily_limit_mb":%s,"monthly_limit_mb":%s,"warn_pct":%s,"crit_pct":%s}}\n' \
        "$(date +%s 2>/dev/null || echo 0)" "$MODE" "$PORT" \
        "$dev_model" "$dev_code" "$android_ver" "${up_sec%%.*}" "$mem_used_mb" "$mem_total_mb" "$bg_procs" \
        "$bat_pct" "$bat_temp" "$bat_status" "$bat_lim_en" "$bat_policy_active" "$bat_stop" "$bat_paused" "$bat_reason" \
        "$dns_ad" "$dns_force" "$dns_cnt" "$dns_preset" \
        "$cell_rx_bps" "$cell_tx_bps" "$c_rx" "$c_tx" "$c_ifaces" \
        "$hs_rx_bps" "$hs_tx_bps" "$h_rx" "$h_tx" "$h_ifaces" "$lan_ips" "$clients_count" \
        "$TTL" "$cur_ttl" "$cur_hl" "$cur_fwd" "$([ "$MANGLE_TTL" = "1" ] && echo true || echo false)" "$mangle_active" \
        "$boundary_ok" "$app_blk_cnt" "$cli_blk_cnt" "$rest_cnt" \
        "$quota_json" "$QUOTA_DAILY_MB" "$QUOTA_MONTHLY_MB" "$QUOTA_WARN_PCT" "$QUOTA_CRIT_PCT"
}

CMD="$1"
if [ -z "$CMD" ] && [ -n "$REQUEST_METHOD" ]; then
    printf 'Content-Type: application/json\r\nCache-Control: no-store\r\n\r\n'
    get_dashboard_json
    exit 0
fi

case "$CMD" in
    dashboard|"")        get_dashboard_json ;;
    clients)             get_clients_json "$2" ;;
    update_quota)        update_quota ;;
    _update_quota_locked) _do_update_quota ;;
    reset_quota)         reset_quota "$2" ;;
    *)                   printf '{"ok":false,"error":"Unknown monitor command"}\n'; exit 1 ;;
esac
