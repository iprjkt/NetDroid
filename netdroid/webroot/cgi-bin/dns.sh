#!/system/bin/sh
# NetDroid - Network-Wide DNS & Adblock Engine
# Dedicated port-5353 dnsmasq resolver + transparent iptables PREROUTING REDIRECT
# + optional DoT (853) & IPv6 DNS bypass blocking + blocklist downloader & whitelist/blacklist.

export PATH="/data/adb/ksu/bin:/data/adb/ap/bin:/data/adb/magisk:/system/bin:/system/xbin:/vendor/bin:$PATH"

DATA_DIR="/data/adb/netdroid"
CFG_DIR="$DATA_DIR/config"
DNS_JSON="$CFG_DIR/dns.json"
ADBLOCK_HOSTS="$CFG_DIR/adblock.hosts"
BASE_HOSTS="$CFG_DIR/.blocklist_base.hosts"
HOST_MERGED="$DATA_DIR/.host_adblock.hosts"
WHITELIST_FILE="$CFG_DIR/.whitelist.txt"
BLACKLIST_FILE="$CFG_DIR/.blacklist.txt"
DNSMASQ_CONF="$DATA_DIR/dnsmasq_nd.conf"
DNSMASQ_PID="$DATA_DIR/dnsmasq.pid"
UPDATE_LOCK="$DATA_DIR/.dns_update.lock"
UPDATE_STATE="$DATA_DIR/.dns_updating"
LOG_FILE="$DATA_DIR/netdroid.log"
DNS_PORT=5353

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
SORT="${BB:+$BB sort}"; [ -z "$SORT" ] && SORT="sort"

mkdir -p "$CFG_DIR" 2>/dev/null

# Ensure symlink /data/adb/modules/netdroid/config -> /data/adb/netdroid/config
for md in /data/adb/modules/netdroid /data/adb/modules_update/netdroid; do
    if [ -d "$md" ] && [ ! -e "$md/config" ]; then
        ln -s "$CFG_DIR" "$md/config" 2>/dev/null || true
    fi
done

log_msg() {
    ts="$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo '0')"
    printf '[%s] [dns] %s\n' "$ts" "$1" >> "$LOG_FILE" 2>/dev/null || true
}

ensure_default_config() {
    [ -f "$WHITELIST_FILE" ] || : > "$WHITELIST_FILE"
    [ -f "$BLACKLIST_FILE" ] || : > "$BLACKLIST_FILE"
    [ -f "$ADBLOCK_HOSTS" ] || : > "$ADBLOCK_HOSTS"
    if [ ! -s "$DNS_JSON" ]; then
        cat <<'EOF' > "$DNS_JSON"
{"adblock_enabled":false,"force_router_dns":false,"preset":"adguard","custom_ipv4":"","custom_ipv6":"","whitelist":[],"blacklist":[],"blocked_domains_count":0,"last_updated":0,"last_error":""}
EOF
        chmod 0644 "$DNS_JSON" 2>/dev/null || true
    fi
}

load_dns_config() {
    ensure_default_config
    eval "$($AWK '
    function gbool(s, k, def,   m, r) {
        r = "\"" k "\"[[:space:]]*:[[:space:]]*(true|false)"
        if (match(s, r)) {
            m = substr(s, RSTART, RLENGTH)
            return (m ~ /true/) ? 1 : 0
        }
        return def
    }
    function gnum(s, k, def,   m, r) {
        r = "\"" k "\"[[:space:]]*:[[:space:]]*[0-9]+"
        if (match(s, r)) {
            m = substr(s, RSTART, RLENGTH)
            sub(/^[^:]+:[[:space:]]*/, "", m)
            return m
        }
        return def
    }
    function gstr(s, k, def,   m, r) {
        r = "\"" k "\"[[:space:]]*:[[:space:]]*\"[^\"]*\""
        if (match(s, r)) {
            m = substr(s, RSTART, RLENGTH)
            sub(/^[^:]+:[[:space:]]*"/, "", m)
            sub(/"$/, "", m)
            return m
        }
        return def
    }
    { line = line $0 }
    END {
        printf "D_ADBLOCK=%d\n", gbool(line, "adblock_enabled", 0)
        printf "D_FORCE=%d\n", gbool(line, "force_router_dns", 0)
        printf "D_PRESET=\"%s\"\n", gstr(line, "preset", "adguard")
        printf "D_CUSTOM4=\"%s\"\n", gstr(line, "custom_ipv4", "")
        printf "D_CUSTOM6=\"%s\"\n", gstr(line, "custom_ipv6", "")
        printf "D_COUNT=%d\n", gnum(line, "blocked_domains_count", 0) + 0
        printf "D_UPDATED=%d\n", gnum(line, "last_updated", 0) + 0
        printf "D_ERR=\"%s\"\n", gstr(line, "last_error", "")
    }
    ' "$DNS_JSON" 2>/dev/null)"

    [ -z "$D_ADBLOCK" ] && D_ADBLOCK=0
    [ -z "$D_FORCE" ] && D_FORCE=0
    [ -z "$D_PRESET" ] && D_PRESET="adguard"
    [ -z "$D_COUNT" ] && D_COUNT=0
    [ -z "$D_UPDATED" ] && D_UPDATED=0
}

is_valid_ipv4() {
    printf '%s' "$1" | $GREP -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'
}

is_valid_ipv6() {
    printf '%s' "$1" | $GREP -qE '^[0-9a-fA-F:]+$' && printf '%s' "$1" | $GREP -q ':'
}

is_valid_domain() {
    printf '%s' "$1" | $GREP -qiE '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$'
}

json_array_from_file() {
    f="$1"
    if [ ! -s "$f" ]; then
        printf '[]'
        return
    fi
    $AWK '
    BEGIN { printf "["; first = 1 }
    NF > 0 {
        gsub(/\\/, "\\\\", $1); gsub(/"/, "\\\"", $1)
        if (!first) printf ","
        first = 0
        printf "\"%s\"", $1
    }
    END { printf "]" }
    ' "$f"
}

write_dns_json() {
    ad_b="false"; [ "$D_ADBLOCK" = "1" ] && ad_b="true"
    fr_b="false"; [ "$D_FORCE" = "1" ] && fr_b="true"
    wl_json="$(json_array_from_file "$WHITELIST_FILE")"
    bl_json="$(json_array_from_file "$BLACKLIST_FILE")"
    err_esc="$(printf '%s' "$D_ERR" | $SED 's/\\/\\\\/g; s/"/\\"/g' | $TR -d '\r\n')"

    tmp="$CFG_DIR/.dns.json.tmp.$$"
    printf '{"adblock_enabled":%s,"force_router_dns":%s,"preset":"%s","custom_ipv4":"%s","custom_ipv6":"%s","whitelist":%s,"blacklist":%s,"blocked_domains_count":%s,"last_updated":%s,"last_error":"%s"}\n' \
        "$ad_b" "$fr_b" "$D_PRESET" "$D_CUSTOM4" "$D_CUSTOM6" "$wl_json" "$bl_json" "$D_COUNT" "$D_UPDATED" "$err_esc" > "$tmp" && \
        mv "$tmp" "$DNS_JSON"
    chmod 0644 "$DNS_JSON" 2>/dev/null || true
}

# Resolve upstream servers for active preset
resolve_upstreams() {
    UP4_1=""; UP4_2=""; UP6_1=""; UP6_2=""
    case "$D_PRESET" in
        adguard)
            UP4_1="94.140.14.14"; UP4_2="94.140.15.15"
            UP6_1="2a10:50c0::ad1:ff"; UP6_2="2a10:50c0::ad2:ff"
            ;;
        cloudflare)
            UP4_1="1.1.1.1"; UP4_2="1.0.0.1"
            UP6_1="2606:4700:4700::1111"; UP6_2="2606:4700:4700::1001"
            ;;
        quad9)
            UP4_1="9.9.9.9"; UP4_2="149.112.112.112"
            UP6_1="2620:fe::fe"; UP6_2="2620:fe::9"
            ;;
        google)
            UP4_1="8.8.8.8"; UP4_2="8.8.4.4"
            UP6_1="2001:4860:4860::8888"; UP6_2="2001:4860:4860::8844"
            ;;
        custom)
            if is_valid_ipv4 "$D_CUSTOM4"; then
                UP4_1="$D_CUSTOM4"
            else
                UP4_1="1.1.1.1"
            fi
            if is_valid_ipv6 "$D_CUSTOM6"; then
                UP6_1="$D_CUSTOM6"
            fi
            ;;
        *)
            UP4_1="94.140.14.14"; UP4_2="94.140.15.15"
            ;;
    esac
}

# Rebuild adblock.hosts from base downloaded list + blacklist - whitelist (instant, offline)
rebuild_adblock_hosts() {
    [ -f "$BASE_HOSTS" ] || : > "$BASE_HOSTS"
    [ -f "$WHITELIST_FILE" ] || : > "$WHITELIST_FILE"
    [ -f "$BLACKLIST_FILE" ] || : > "$BLACKLIST_FILE"

    tmp_hosts="$CFG_DIR/.adblock.hosts.tmp.$$"
    $AWK -v f_wl="$WHITELIST_FILE" -v f_bl="$BLACKLIST_FILE" -v f_base="$BASE_HOSTS" '
    FILENAME == f_wl {
        d = tolower($1)
        if (d != "") wl[d] = 1
        next
    }
    FILENAME == f_bl {
        d = tolower($1)
        if (d != "" && !(d in wl) && !(d in seen)) {
            seen[d] = 1
            printf "0.0.0.0 %s\n", d
        }
        next
    }
    FILENAME == f_base {
        d = tolower($2)
        if (d != "" && !(d in wl) && !(d in seen)) {
            seen[d] = 1
            printf "0.0.0.0 %s\n", d
        }
        next
    }
    ' "$WHITELIST_FILE" "$BLACKLIST_FILE" "$BASE_HOSTS" > "$tmp_hosts"

    mv "$tmp_hosts" "$ADBLOCK_HOSTS"
    chmod 0644 "$ADBLOCK_HOSTS" 2>/dev/null || true

    cnt="$(wc -l < "$ADBLOCK_HOSTS" 2>/dev/null | $TR -cd '0-9')"
    [ -z "$cnt" ] && cnt=0
    D_COUNT="$cnt"
}

# Optional host-device /etc/hosts bind-mount (only if compatible & no external hosts module is mounted)
sync_host_etc_hosts() {
    # Check if an external module (e.g. Re-Malwack / AdAway) already bind-mounted /system/etc/hosts
    other_mount="$($AWK '$2 ~ /^(\/system)?\/etc\/hosts$/ && $1 !~ /netdroid/ { print $0 }' /proc/mounts 2>/dev/null)"
    nd_mounted="$($GREP -q "$HOST_MERGED" /proc/mounts 2>/dev/null && echo 1 || echo 0)"
    # Also check if /system/etc/hosts is mounted from our inode via mountinfo
    if [ -f "$DATA_DIR/.hosts_bind_active" ]; then
        nd_mounted=1
    fi

    if [ "$D_ADBLOCK" = "1" ] && [ -s "$ADBLOCK_HOSTS" ]; then
        # Skip if another hosts module is mounted and it wasn't mounted by NetDroid
        if [ -n "$other_mount" ] && [ "$nd_mounted" = "0" ]; then
            log_msg "External /etc/hosts mount detected; skipping host bind-mount to avoid conflict"
            return 0
        fi
        tmp_m="$DATA_DIR/.host_adblock.tmp.$$"
        printf '127.0.0.1 localhost\n::1 ip6-localhost\n' > "$tmp_m"
        cat "$ADBLOCK_HOSTS" >> "$tmp_m"
        mv "$tmp_m" "$HOST_MERGED"
        chmod 0644 "$HOST_MERGED" 2>/dev/null || true

        if [ "$nd_mounted" = "0" ]; then
            mount --bind "$HOST_MERGED" /system/etc/hosts 2>/dev/null && \
                touch "$DATA_DIR/.hosts_bind_active" 2>/dev/null || true
        fi
    else
        if [ -f "$DATA_DIR/.hosts_bind_active" ]; then
            umount /system/etc/hosts 2>/dev/null || umount -l /system/etc/hosts 2>/dev/null || true
            rm -f "$DATA_DIR/.hosts_bind_active" "$HOST_MERGED" 2>/dev/null || true
        fi
    fi
}

stop_dnsmasq() {
    if [ -f "$DNSMASQ_PID" ]; then
        pid="$(cat "$DNSMASQ_PID" 2>/dev/null)"
        [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
        rm -f "$DNSMASQ_PID"
    fi
    if [ -n "$BB" ]; then
        $BB pkill -f "dnsmasq.*dnsmasq_nd.conf" 2>/dev/null || true
    fi
}

start_dnsmasq() {
    stop_dnsmasq
    DNSMASQ_BIN="$(command -v dnsmasq 2>/dev/null)"
    [ -z "$DNSMASQ_BIN" ] && [ -x /system/bin/dnsmasq ] && DNSMASQ_BIN="/system/bin/dnsmasq"
    if [ -z "$DNSMASQ_BIN" ]; then
        log_msg "ERROR: dnsmasq binary not found"
        return 1
    fi

    resolve_upstreams

    cat <<EOF > "$DNSMASQ_CONF"
port=$DNS_PORT
user=root
no-resolv
no-poll
no-hosts
cache-size=2048
domain-needed
bogus-priv
pid-file=$DNSMASQ_PID
EOF

    [ -n "$UP4_1" ] && printf 'server=%s\n' "$UP4_1" >> "$DNSMASQ_CONF"
    [ -n "$UP4_2" ] && printf 'server=%s\n' "$UP4_2" >> "$DNSMASQ_CONF"
    [ -n "$UP6_1" ] && printf 'server=%s\n' "$UP6_1" >> "$DNSMASQ_CONF"
    [ -n "$UP6_2" ] && printf 'server=%s\n' "$UP6_2" >> "$DNSMASQ_CONF"

    if [ "$D_ADBLOCK" = "1" ] && [ -s "$ADBLOCK_HOSTS" ]; then
        printf 'addn-hosts=%s\n' "$ADBLOCK_HOSTS" >> "$DNSMASQ_CONF"
    fi

    # Launch detached so CGI/adb never waits on inherited FDs
    if [ -n "$BB" ] && "$BB" setsid true >/dev/null 2>&1; then
        "$BB" setsid "$DNSMASQ_BIN" --conf-file="$DNSMASQ_CONF" --keep-in-foreground </dev/null >/dev/null 2>&1 &
    else
        "$DNSMASQ_BIN" --conf-file="$DNSMASQ_CONF" --keep-in-foreground </dev/null >/dev/null 2>&1 &
    fi
    pid=$!
    printf '%s\n' "$pid" > "$DNSMASQ_PID"
    log_msg "Started NetDroid dnsmasq (PID=$pid, port=$DNS_PORT, preset=$D_PRESET, adblock=$D_ADBLOCK)"
}

flush_dns_iptables() {
    # Flush IPv4 NAT PREROUTING chain
    while iptables -w 2 -t nat -C PREROUTING -j NETDROID_DNS_PRE 2>/dev/null; do
        iptables -w 2 -t nat -D PREROUTING -j NETDROID_DNS_PRE 2>/dev/null || break
    done
    iptables -w 2 -t nat -F NETDROID_DNS_PRE 2>/dev/null || true
    iptables -w 2 -t nat -X NETDROID_DNS_PRE 2>/dev/null || true

    # Flush IPv6 NAT PREROUTING chain (if kernel supports ip6table_nat)
    while ip6tables -w 2 -t nat -C PREROUTING -j NETDROID_DNS_PRE 2>/dev/null; do
        ip6tables -w 2 -t nat -D PREROUTING -j NETDROID_DNS_PRE 2>/dev/null || break
    done
    ip6tables -w 2 -t nat -F NETDROID_DNS_PRE 2>/dev/null || true
    ip6tables -w 2 -t nat -X NETDROID_DNS_PRE 2>/dev/null || true

    # Flush FORWARD DoT/bypass chain
    for ipt in iptables ip6tables; do
        command -v "$ipt" >/dev/null 2>&1 || continue
        while "$ipt" -w 2 -C FORWARD -j NETDROID_DNS_FWD 2>/dev/null; do
            "$ipt" -w 2 -D FORWARD -j NETDROID_DNS_FWD 2>/dev/null || break
        done
        "$ipt" -w 2 -F NETDROID_DNS_FWD 2>/dev/null || true
        "$ipt" -w 2 -X NETDROID_DNS_FWD 2>/dev/null || true
    done
}

apply_dns_iptables() {
    flush_dns_iptables

    # Only hook iptables when Adblock or Force Router DNS is enabled
    if [ "$D_ADBLOCK" != "1" ] && [ "$D_FORCE" != "1" ]; then
        return 0
    fi

    # Create and hook IPv4 NAT PREROUTING chain
    iptables -w 2 -t nat -N NETDROID_DNS_PRE 2>/dev/null || true
    iptables -w 2 -t nat -I PREROUTING 1 -j NETDROID_DNS_PRE 2>/dev/null || true

    LAN_IFACES="wlan+ ap+ swlan+ softap+ rndis+ usb+ ncm+"

    if [ "$D_FORCE" = "1" ]; then
        # Force Router DNS: transparently intercept ALL UDP & TCP port 53 from tethered clients
        for iface in $LAN_IFACES; do
            iptables -w 2 -t nat -A NETDROID_DNS_PRE -i "$iface" -p udp --dport 53 -j REDIRECT --to-ports "$DNS_PORT" 2>/dev/null || true
            iptables -w 2 -t nat -A NETDROID_DNS_PRE -i "$iface" -p tcp --dport 53 -j REDIRECT --to-ports "$DNS_PORT" 2>/dev/null || true
        done

        # Block DoT (port 853) on tethered interfaces so clients cleanly fall back to router DNS
        for ipt in iptables ip6tables; do
            command -v "$ipt" >/dev/null 2>&1 || continue
            "$ipt" -w 2 -N NETDROID_DNS_FWD 2>/dev/null || true
            "$ipt" -w 2 -I FORWARD 1 -j NETDROID_DNS_FWD 2>/dev/null || true
            for iface in $LAN_IFACES; do
                "$ipt" -w 2 -A NETDROID_DNS_FWD -i "$iface" -p tcp --dport 853 -j DROP 2>/dev/null || true
                "$ipt" -w 2 -A NETDROID_DNS_FWD -i "$iface" -p udp --dport 853 -j DROP 2>/dev/null || true
            done
        done

        # IPv6 DNS: redirect if ip6table_nat exists, otherwise drop forwarded IPv6 port 53 so clients use filtered IPv4 DNS
        if ip6tables -w 2 -t nat -N NETDROID_DNS_PRE 2>/dev/null; then
            ip6tables -w 2 -t nat -I PREROUTING 1 -j NETDROID_DNS_PRE 2>/dev/null || true
            for iface in $LAN_IFACES; do
                ip6tables -w 2 -t nat -A NETDROID_DNS_PRE -i "$iface" -p udp --dport 53 -j REDIRECT --to-ports "$DNS_PORT" 2>/dev/null || true
                ip6tables -w 2 -t nat -A NETDROID_DNS_PRE -i "$iface" -p tcp --dport 53 -j REDIRECT --to-ports "$DNS_PORT" 2>/dev/null || true
            done
        else
            for iface in $LAN_IFACES; do
                ip6tables -w 2 -A NETDROID_DNS_FWD -i "$iface" -p udp --dport 53 -j DROP 2>/dev/null || true
                ip6tables -w 2 -A NETDROID_DNS_FWD -i "$iface" -p tcp --dport 53 -j DROP 2>/dev/null || true
            done
        fi
    else
        # Standard Router Adblock mode: redirect router-bound DNS queries on active hotspot gateway IPs
        gw_ips="$(ip -4 -br addr 2>/dev/null | $AWK '
            $1 ~ /^(wlan|ap|swlan|softap|rndis|usb|ncm)/ && $2 != "DOWN" {
                for (i=3; i<=NF; i++) {
                    if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/) {
                        ip = $i; sub(/\/.*/, "", ip)
                        print ip
                    }
                }
            }')"
        for gw in $gw_ips; do
            for iface in $LAN_IFACES; do
                iptables -w 2 -t nat -A NETDROID_DNS_PRE -i "$iface" -d "$gw" -p udp --dport 53 -j REDIRECT --to-ports "$DNS_PORT" 2>/dev/null || true
                iptables -w 2 -t nat -A NETDROID_DNS_PRE -i "$iface" -d "$gw" -p tcp --dport 53 -j REDIRECT --to-ports "$DNS_PORT" 2>/dev/null || true
            done
        done
    fi
}

apply_all() {
    load_dns_config
    rebuild_adblock_hosts
    write_dns_json

    if [ "$D_ADBLOCK" = "1" ] || [ "$D_FORCE" = "1" ]; then
        start_dnsmasq
        apply_dns_iptables
    else
        stop_dnsmasq
        flush_dns_iptables
    fi
    sync_host_etc_hosts
}

# Watchdog check called periodically by service.sh
watchdog_check() {
    load_dns_config
    if [ "$D_ADBLOCK" = "1" ] || [ "$D_FORCE" = "1" ]; then
        dpid="$(cat "$DNSMASQ_PID" 2>/dev/null)"
        if [ -z "$dpid" ] || ! kill -0 "$dpid" 2>/dev/null; then
            start_dnsmasq
        fi
        if ! iptables -w 2 -t nat -C PREROUTING -j NETDROID_DNS_PRE 2>/dev/null; then
            apply_dns_iptables
        fi
    fi
}

# Download and merge blocklists
do_update_lists() {
    load_dns_config
    printf '1\n' > "$UPDATE_STATE"

    tmp_dl="$CFG_DIR/.blocklist_dl.$$"
    tmp_parsed="$CFG_DIR/.blocklist_parsed.$$"
    : > "$tmp_dl"

    # Fetch lightweight, high-signal hosts lists (StevenBlack unified + AdAway fallback)
    dl_ok=0
    for url in \
        "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts" \
        "https://adaway.org/hosts.txt"; do
        if command -v curl >/dev/null 2>&1; then
            if curl -fsSL --connect-timeout 10 --max-time 45 -o "$tmp_dl" "$url" 2>/dev/null && [ -s "$tmp_dl" ]; then
                dl_ok=1
                break
            fi
        elif [ -n "$BB" ]; then
            if "$BB" wget -q --no-check-certificate -T 30 -O "$tmp_dl" "$url" 2>/dev/null && [ -s "$tmp_dl" ]; then
                dl_ok=1
                break
            fi
        fi
    done

    if [ "$dl_ok" = "1" ]; then
        $AWK '
        {
            sub(/\r$/, "", $0)
            sub(/#.*/, "", $0)
            if (NF >= 2 && ($1 == "0.0.0.0" || $1 == "127.0.0.1")) {
                d = tolower($2)
                if (d != "" && d != "localhost" && d != "localhost.localdomain" && d != "local" && d != "broadcasthost" && d != "0.0.0.0" && d ~ /^[a-z0-9.-]+\.[a-z]{2,}$/) {
                    if (!(d in seen)) {
                        seen[d] = 1
                        printf "0.0.0.0 %s\n", d
                    }
                }
            }
        }
        ' "$tmp_dl" > "$tmp_parsed"

        if [ -s "$tmp_parsed" ]; then
            mv "$tmp_parsed" "$BASE_HOSTS"
            chmod 0644 "$BASE_HOSTS" 2>/dev/null || true
            D_UPDATED="$(date +%s 2>/dev/null || echo 0)"
            D_ERR=""
            rebuild_adblock_hosts
            write_dns_json
            if [ "$D_ADBLOCK" = "1" ] || [ "$D_FORCE" = "1" ]; then
                start_dnsmasq
                sync_host_etc_hosts
            fi
            log_msg "Updated blocklist: $D_COUNT domains blocked"
        else
            D_ERR="Parsed blocklist was empty"
            write_dns_json
        fi
    else
        D_ERR="Failed to download blocklist (check internet)"
        write_dns_json
        log_msg "Blocklist download failed"
    fi

    rm -f "$tmp_dl" "$tmp_parsed" "$UPDATE_STATE" 2>/dev/null
}

# Save config & list mutations
save_config() {
    # Args: adblock(0|1|'') force(0|1|'') preset custom4 custom6 add_wl del_wl add_bl del_bl
    load_dns_config

    in_ad="$1"; in_fr="$2"; in_pre="$3"; in_c4="$4"; in_c6="$5"
    in_add_wl="$6"; in_del_wl="$7"; in_add_bl="$8"; in_del_bl="$9"

    if [ -n "$in_ad" ]; then
        case "$in_ad" in 1|true|yes|on) D_ADBLOCK=1 ;; *) D_ADBLOCK=0 ;; esac
    fi
    if [ -n "$in_fr" ]; then
        case "$in_fr" in 1|true|yes|on) D_FORCE=1 ;; *) D_FORCE=0 ;; esac
    fi
    if [ -n "$in_pre" ]; then
        case "$in_pre" in
            adguard|cloudflare|quad9|google|custom) D_PRESET="$in_pre" ;;
        esac
    fi
    if [ "$in_c4" != "__UNCHANGED__" ]; then
        clean4="$(printf '%s' "$in_c4" | $TR -cd '0-9.')"
        if [ -z "$clean4" ] || is_valid_ipv4 "$clean4"; then
            D_CUSTOM4="$clean4"
        else
            printf '{"ok":false,"error":"Invalid custom IPv4 address"}\n'
            return 1
        fi
    fi
    if [ "$in_c6" != "__UNCHANGED__" ]; then
        clean6="$(printf '%s' "$in_c6" | $TR -cd '0-9a-fA-F:')"
        if [ -z "$clean6" ] || is_valid_ipv6 "$clean6"; then
            D_CUSTOM6="$clean6"
        else
            printf '{"ok":false,"error":"Invalid custom IPv6 address"}\n'
            return 1
        fi
    fi

    # Whitelist add/remove
    if [ -n "$in_add_wl" ]; then
        dom="$(printf '%s' "$in_add_wl" | $TR 'A-Z' 'a-z' | $TR -cd 'a-z0-9.-')"
        if ! is_valid_domain "$dom"; then
            printf '{"ok":false,"error":"Invalid domain name"}\n'
            return 1
        fi
        printf '%s\n' "$dom" >> "$WHITELIST_FILE"
        $SORT -u "$WHITELIST_FILE" > "$WHITELIST_FILE.tmp.$$" && mv "$WHITELIST_FILE.tmp.$$" "$WHITELIST_FILE"
    fi
    if [ -n "$in_del_wl" ]; then
        dom="$(printf '%s' "$in_del_wl" | $TR 'A-Z' 'a-z' | $TR -cd 'a-z0-9.-')"
        $GREP -vxF "$dom" "$WHITELIST_FILE" > "$WHITELIST_FILE.tmp.$$" 2>/dev/null || true
        mv "$WHITELIST_FILE.tmp.$$" "$WHITELIST_FILE"
    fi

    # Blacklist add/remove
    if [ -n "$in_add_bl" ]; then
        dom="$(printf '%s' "$in_add_bl" | $TR 'A-Z' 'a-z' | $TR -cd 'a-z0-9.-')"
        if ! is_valid_domain "$dom"; then
            printf '{"ok":false,"error":"Invalid domain name"}\n'
            return 1
        fi
        printf '%s\n' "$dom" >> "$BLACKLIST_FILE"
        $SORT -u "$BLACKLIST_FILE" > "$BLACKLIST_FILE.tmp.$$" && mv "$BLACKLIST_FILE.tmp.$$" "$BLACKLIST_FILE"
    fi
    if [ -n "$in_del_bl" ]; then
        dom="$(printf '%s' "$in_del_bl" | $TR 'A-Z' 'a-z' | $TR -cd 'a-z0-9.-')"
        $GREP -vxF "$dom" "$BLACKLIST_FILE" > "$BLACKLIST_FILE.tmp.$$" 2>/dev/null || true
        mv "$BLACKLIST_FILE.tmp.$$" "$BLACKLIST_FILE"
    fi

    rebuild_adblock_hosts
    write_dns_json

    if [ "$D_ADBLOCK" = "1" ] || [ "$D_FORCE" = "1" ]; then
        start_dnsmasq
        apply_dns_iptables
    else
        stop_dnsmasq
        flush_dns_iptables
    fi
    sync_host_etc_hosts

    get_status_json
}

cleanup_all() {
    stop_dnsmasq
    flush_dns_iptables
    if [ -f "$DATA_DIR/.hosts_bind_active" ]; then
        umount /system/etc/hosts 2>/dev/null || umount -l /system/etc/hosts 2>/dev/null || true
        rm -f "$DATA_DIR/.hosts_bind_active" "$HOST_MERGED" 2>/dev/null || true
    fi
}

get_status_json() {
    load_dns_config
    resolve_upstreams

    ad_b="false"; [ "$D_ADBLOCK" = "1" ] && ad_b="true"
    fr_b="false"; [ "$D_FORCE" = "1" ] && fr_b="true"
    upd_b="false"; [ -f "$UPDATE_STATE" ] && upd_b="true"

    dm_running="false"
    dpid="$(cat "$DNSMASQ_PID" 2>/dev/null)"
    if [ -n "$dpid" ] && kill -0 "$dpid" 2>/dev/null; then
        dm_running="true"
    fi

    nat_active="false"
    iptables -w 2 -t nat -C PREROUTING -j NETDROID_DNS_PRE 2>/dev/null && nat_active="true"

    dot_blocked="false"
    iptables -w 2 -C FORWARD -j NETDROID_DNS_FWD 2>/dev/null && dot_blocked="true"

    wl_json="$(json_array_from_file "$WHITELIST_FILE")"
    bl_json="$(json_array_from_file "$BLACKLIST_FILE")"
    err_esc="$(printf '%s' "$D_ERR" | $SED 's/\\/\\\\/g; s/"/\\"/g' | $TR -d '\r\n')"

    printf '{"ok":true,"enabled":%s,"adblock_enabled":%s,"force_router_dns":%s,"preset":"%s","custom_ipv4":"%s","custom_ipv6":"%s","active_upstream_v4":"%s","active_upstream_v6":"%s","blocked_domains_count":%s,"last_updated":%s,"updating":%s,"last_error":"%s","dnsmasq_running":%s,"nat_redirect_active":%s,"dot_blocked":%s,"whitelist":%s,"blacklist":%s}\n' \
        "$ad_b" "$ad_b" "$fr_b" "$D_PRESET" "$D_CUSTOM4" "$D_CUSTOM6" \
        "$UP4_1" "$UP6_1" "$D_COUNT" "$D_UPDATED" "$upd_b" "$err_esc" \
        "$dm_running" "$nat_active" "$dot_blocked" "$wl_json" "$bl_json"
}

CMD="$1"
if [ -z "$CMD" ] && [ -n "$REQUEST_METHOD" ]; then
    printf 'Content-Type: application/json\r\nCache-Control: no-store\r\n\r\n'
    get_status_json
    exit 0
fi

case "$CMD" in
    status|"")         get_status_json ;;
    apply)             apply_all ;;
    watchdog)          watchdog_check ;;
    save)              save_config "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}" ;;
    update_lists)      do_update_lists; get_status_json ;;
    update_lists_bg)
        printf '1\n' > "$UPDATE_STATE"
        if [ -n "$BB" ] && "$BB" setsid true >/dev/null 2>&1; then
            "$BB" setsid sh "$0" _update_bg </dev/null >/dev/null 2>&1 &
        else
            sh "$0" _update_bg </dev/null >/dev/null 2>&1 &
        fi
        get_status_json
        ;;
    _update_bg)        do_update_lists ;;
    cleanup)           cleanup_all ;;
    *)                 printf '{"ok":false,"error":"Unknown dns command"}\n'; exit 1 ;;
esac
