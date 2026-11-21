#!/system/bin/sh
# NetDroid - Firewall Engine & Network Security Boundary (iptables / ip6tables)
# Supports per-app UID control (Wi-Fi & Mobile Data), LAN client MAC/IP blocking,
# and strict WAN port-blocking security boundary.

export PATH="/data/adb/ksu/bin:/data/adb/ap/bin:/data/adb/magisk:/system/bin:/system/xbin:/vendor/bin:$PATH"

DATA_DIR="/data/adb/netdroid"
CONFIG_FILE="$DATA_DIR/config.env"
RULES_FILE="$DATA_DIR/firewall.rules"
JSON_FILE="$DATA_DIR/firewall.json"
APP_CACHE="$DATA_DIR/.apps_cache"
LOCK_FILE="$DATA_DIR/.firewall.lock"

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
SORT="${BB:+$BB sort}"; [ -z "$SORT" ] && SORT="sort"
TR="${BB:+$BB tr}"; [ -z "$TR" ] && TR="tr"

PORT=8765
if [ -f "$CONFIG_FILE" ]; then
    . "$CONFIG_FILE" 2>/dev/null
fi
[ -z "$PORT" ] && PORT=8765

mkdir -p "$DATA_DIR" 2>/dev/null
[ -f "$RULES_FILE" ] || : > "$RULES_FILE"

json_escape() {
    printf '%s' "$1" | $SED 's/\\/\\\\/g; s/"/\\"/g; s/	/\\t/g' | $TR -d '\r\n'
}

# Validate helpers
is_uint() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

is_mac() {
    printf '%s' "$1" | $GREP -qiE '^([0-9a-f]{2}:){5}[0-9a-f]{2}$'
}

is_ipv4() {
    printf '%s' "$1" | $GREP -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'
}

# Ensure a custom chain exists and is hooked at position 1 of parent chain
ensure_chain_hook() {
    ipt="$1"
    parent="$2"
    chain="$3"
    "$ipt" -w 2 -N "$chain" 2>/dev/null || true
    while "$ipt" -w 2 -C "$parent" -j "$chain" 2>/dev/null; do
        "$ipt" -w 2 -D "$parent" -j "$chain" 2>/dev/null || break
    done
    "$ipt" -w 2 -I "$parent" 1 -j "$chain" 2>/dev/null || true
}

remove_chain_hook() {
    ipt="$1"
    parent="$2"
    chain="$3"
    while "$ipt" -w 2 -C "$parent" -j "$chain" 2>/dev/null; do
        "$ipt" -w 2 -D "$parent" -j "$chain" 2>/dev/null || break
    done
    "$ipt" -w 2 -F "$chain" 2>/dev/null || true
    "$ipt" -w 2 -X "$chain" 2>/dev/null || true
}

# 1. Network Security Boundary:
#    Allow port $PORT ONLY on lo and local hotspot/LAN interfaces.
#    Explicitly DROP on rmnet+, r_rmnet+, ccmni+, wwan+, pdp+ and default-drop others.
apply_boundary() {
    for ipt in iptables ip6tables; do
        command -v "$ipt" >/dev/null 2>&1 || continue
        ensure_chain_hook "$ipt" INPUT NETDROID_IN
        "$ipt" -w 2 -F NETDROID_IN 2>/dev/null || true

        # Allow localhost and local LAN / hotspot / USB tether interfaces (WebUI + local DNS 5353)
        for iface in lo wlan+ ap+ swlan+ softap+ rndis+ usb+ ncm+; do
            "$ipt" -w 2 -A NETDROID_IN -i "$iface" -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null || true
            "$ipt" -w 2 -A NETDROID_IN -i "$iface" -p udp --dport 5353 -j ACCEPT 2>/dev/null || true
            "$ipt" -w 2 -A NETDROID_IN -i "$iface" -p tcp --dport 5353 -j ACCEPT 2>/dev/null || true
        done

        # Explicitly block public cellular interfaces
        for wiface in rmnet+ r_rmnet+ ccmni+ wwan+ pdp+; do
            "$ipt" -w 2 -A NETDROID_IN -i "$wiface" -p tcp --dport "$PORT" -j DROP 2>/dev/null || true
            "$ipt" -w 2 -A NETDROID_IN -i "$wiface" -p udp --dport 5353 -j DROP 2>/dev/null || true
            "$ipt" -w 2 -A NETDROID_IN -i "$wiface" -p tcp --dport 5353 -j DROP 2>/dev/null || true
        done

        # Default deny WebUI port & local DNS 5353 from any other interface
        "$ipt" -w 2 -A NETDROID_IN -p tcp --dport "$PORT" -j DROP 2>/dev/null || true
        "$ipt" -w 2 -A NETDROID_IN -p udp --dport 5353 -j DROP 2>/dev/null || true
        "$ipt" -w 2 -A NETDROID_IN -p tcp --dport 5353 -j DROP 2>/dev/null || true
    done
}

# Rebuild firewall.json from firewall.rules
sync_firewall_json() {
    tmp_json="$DATA_DIR/.firewall.json.tmp.$$"
    $AWK -F'|' '
    function esc(s) {
        gsub(/\\/, "\\\\", s)
        gsub(/"/, "\\\"", s)
        gsub(/\r|\n/, "", s)
        return s
    }
    BEGIN { app_n = 0; cli_n = 0 }
    /^APP\|/ {
        uid = $2; pkg = $3; wifi = ($4 == "1" ? "true" : "false"); mob = ($5 == "1" ? "true" : "false")
        if (wifi == "true" || mob == "true") {
            app_uid[app_n] = uid
            app_pkg[app_n] = esc(pkg)
            app_wifi[app_n] = wifi
            app_mob[app_n] = mob
            app_n++
        }
    }
    /^CLIENT\|/ {
        mac = tolower($2); ip = $3; host = $4; blk = ($5 == "1" ? "true" : "false")
        if (blk == "true") {
            cli_mac[cli_n] = esc(mac)
            cli_ip[cli_n] = esc(ip)
            cli_host[cli_n] = esc(host)
            cli_n++
        }
    }
    END {
        printf "{\"apps\":{"
        for (i = 0; i < app_n; i++) {
            if (i > 0) printf ","
            printf "\"%s\":{\"uid\":%s,\"package\":\"%s\",\"wifi_blocked\":%s,\"mobile_blocked\":%s}", app_uid[i], app_uid[i], app_pkg[i], app_wifi[i], app_mob[i]
        }
        printf "},\"clients\":{"
        for (i = 0; i < cli_n; i++) {
            if (i > 0) printf ","
            printf "\"%s\":{\"mac\":\"%s\",\"ip\":\"%s\",\"hostname\":\"%s\",\"blocked\":true}", cli_mac[i], cli_mac[i], cli_ip[i], cli_host[i]
        }
        printf "}}\n"
    }
    ' "$RULES_FILE" > "$tmp_json" && mv "$tmp_json" "$JSON_FILE"
    chmod 0644 "$JSON_FILE" 2>/dev/null || true
}

# 2. Apply all persisted app UID and LAN client rules
apply_rules() {
    for ipt in iptables ip6tables; do
        command -v "$ipt" >/dev/null 2>&1 || continue
        ensure_chain_hook "$ipt" OUTPUT NETDROID_OUT
        ensure_chain_hook "$ipt" FORWARD NETDROID_FWD
        "$ipt" -w 2 -F NETDROID_OUT 2>/dev/null || true
        "$ipt" -w 2 -F NETDROID_FWD 2>/dev/null || true
    done

    if [ ! -f "$RULES_FILE" ]; then
        sync_firewall_json
        return 0
    fi

    while IFS='|' read -r rtype f1 f2 f3 f4; do
        case "$rtype" in
            APP)
                uid="$f1"
                wifi_blk="$f3"
                mob_blk="$f4"
                is_uint "$uid" || continue

                if [ "$mob_blk" = "1" ]; then
                    for ipt in iptables ip6tables; do
                        command -v "$ipt" >/dev/null 2>&1 || continue
                        for mif in rmnet+ r_rmnet+ ccmni+ wwan+ pdp+; do
                            "$ipt" -w 2 -A NETDROID_OUT -m owner --uid-owner "$uid" -o "$mif" -j DROP 2>/dev/null || true
                        done
                    done
                fi

                if [ "$wifi_blk" = "1" ]; then
                    for ipt in iptables ip6tables; do
                        command -v "$ipt" >/dev/null 2>&1 || continue
                        for wif in wlan+ eth+; do
                            "$ipt" -w 2 -A NETDROID_OUT -m owner --uid-owner "$uid" -o "$wif" -j DROP 2>/dev/null || true
                        done
                    done
                fi
                ;;
            CLIENT)
                mac="$(printf '%s' "$f1" | $TR 'A-F' 'a-f')"
                ip="$f2"
                blk="$f4"
                [ "$blk" = "1" ] || continue

                if is_mac "$mac"; then
                    for ipt in iptables ip6tables; do
                        command -v "$ipt" >/dev/null 2>&1 || continue
                        "$ipt" -w 2 -A NETDROID_FWD -m mac --mac-source "$mac" -j DROP 2>/dev/null || true
                    done
                fi

                if is_ipv4 "$ip"; then
                    iptables -w 2 -A NETDROID_FWD -s "$ip" -j DROP 2>/dev/null || true
                    iptables -w 2 -A NETDROID_FWD -d "$ip" -j DROP 2>/dev/null || true
                fi
                ;;
        esac
    done < "$RULES_FILE"

    sync_firewall_json
}

apply_all() {
    apply_boundary
    apply_rules
}

set_app_rule() {
    uid="$1"
    pkg="$2"
    wifi_blk="$3"
    mob_blk="$4"

    is_uint "$uid" || { printf '{"ok":false,"error":"Invalid UID"}\n'; return 1; }
    [ "$wifi_blk" = "1" ] || wifi_blk="0"
    [ "$mob_blk" = "1" ] || mob_blk="0"
    clean_pkg="$(printf '%s' "$pkg" | $TR -cd 'A-Za-z0-9._-')"

    tmp_rules="$DATA_DIR/.firewall.rules.tmp.$$"
    $GREP -v "^APP|${uid}|" "$RULES_FILE" > "$tmp_rules" 2>/dev/null || true
    if [ "$wifi_blk" = "1" ] || [ "$mob_blk" = "1" ]; then
        printf 'APP|%s|%s|%s|%s\n' "$uid" "$clean_pkg" "$wifi_blk" "$mob_blk" >> "$tmp_rules"
    fi
    mv "$tmp_rules" "$RULES_FILE"
    chmod 0644 "$RULES_FILE" 2>/dev/null || true

    apply_rules
    printf '{"ok":true,"uid":%s,"package":"%s","wifi_blocked":%s,"mobile_blocked":%s}\n' \
        "$uid" "$(json_escape "$clean_pkg")" \
        "$([ "$wifi_blk" = "1" ] && echo true || echo false)" \
        "$([ "$mob_blk" = "1" ] && echo true || echo false)"
}

set_client_rule() {
    mac="$(printf '%s' "$1" | $TR 'A-F' 'a-f' | $TR -cd '0-9a-f:')"
    ip="$(printf '%s' "$2" | $TR -cd '0-9.')"
    host="$(printf '%s' "$3" | $TR -d '|\r\n')"
    blk="$4"

    if ! is_mac "$mac" && ! is_ipv4 "$ip"; then
        printf '{"ok":false,"error":"Valid MAC or IPv4 address required"}\n'
        return 1
    fi
    [ "$blk" = "1" ] || blk="0"
    [ -z "$mac" ] && mac="ip:$ip"

    tmp_rules="$DATA_DIR/.firewall.rules.tmp.$$"
    $GREP -iv "^CLIENT|${mac}|" "$RULES_FILE" > "$tmp_rules" 2>/dev/null || true
    if [ "$blk" = "1" ]; then
        printf 'CLIENT|%s|%s|%s|1\n' "$mac" "$ip" "$host" >> "$tmp_rules"
    fi
    mv "$tmp_rules" "$RULES_FILE"
    chmod 0644 "$RULES_FILE" 2>/dev/null || true

    apply_rules
    printf '{"ok":true,"mac":"%s","ip":"%s","blocked":%s}\n' \
        "$(json_escape "$mac")" "$(json_escape "$ip")" \
        "$([ "$blk" = "1" ] && echo true || echo false)"
}

clear_all_rules() {
    : > "$RULES_FILE"
    apply_rules
    printf '{"ok":true,"message":"All firewall rules cleared"}\n'
}

cleanup_chains() {
    for ipt in iptables ip6tables; do
        command -v "$ipt" >/dev/null 2>&1 || continue
        remove_chain_hook "$ipt" INPUT NETDROID_IN
        remove_chain_hook "$ipt" OUTPUT NETDROID_OUT
        remove_chain_hook "$ipt" FORWARD NETDROID_FWD
    done
}

# List installed apps with UIDs, user/system classification, and active block flags
list_apps() {
    force_refresh="$1"
    now="$(date +%s 2>/dev/null || echo 0)"
    cache_ok=0

    if [ "$force_refresh" != "1" ] && [ -f "$APP_CACHE" ]; then
        mtime="$($BB stat -c %Y "$APP_CACHE" 2>/dev/null || echo 0)"
        age=$((now - mtime))
        if [ "$age" -ge 0 ] && [ "$age" -lt 45 ] && [ -s "$APP_CACHE" ]; then
            cache_ok=1
        fi
    fi

    if [ "$cache_ok" -eq 0 ]; then
        tmp_all="$DATA_DIR/.pm_all.$$"
        tmp_usr="$DATA_DIR/.pm_usr.$$"
        # Pipe through cat so system_server writes to an anonymous pipe (not adb_data_file FD under SELinux)
        (cmd package list packages -U 2>/dev/null || pm list packages -U 2>/dev/null) | cat > "$tmp_all"
        (cmd package list packages -3 2>/dev/null || pm list packages -3 2>/dev/null) | cat > "$tmp_usr"

        $AWK -v f_usr="$tmp_usr" '
        FILENAME == f_usr {
            sub(/^package:/, "", $0)
            sub(/\r$/, "", $0)
            if ($0 != "") user_pkg[$0] = 1
            next
        }
        /^package:/ {
            sub(/^package:/, "", $0)
            sub(/\r$/, "", $0)
            idx = index($0, " uid:")
            if (idx > 1) {
                pkg = substr($0, 1, idx - 1)
                uid = substr($0, idx + 5)
                sub(/[[:space:],].*/, "", uid)
                if (pkg != "" && uid ~ /^[0-9]+$/) {
                    is_u = (pkg in user_pkg) ? 1 : 0
                    printf "%s|%s|%d\n", pkg, uid, is_u
                }
            }
        }
        ' "$tmp_usr" "$tmp_all" | $SORT -t'|' -k3,3nr -k1,1 > "$APP_CACHE.tmp.$$" 2>/dev/null
        mv "$APP_CACHE.tmp.$$" "$APP_CACHE" 2>/dev/null || true
        rm -f "$tmp_all" "$tmp_usr" 2>/dev/null
    fi

    [ -f "$RULES_FILE" ] || : > "$RULES_FILE"
    [ -f "$APP_CACHE" ] || : > "$APP_CACHE"

    $AWK -F'|' -v f_rules="$RULES_FILE" '
    function esc(s) {
        gsub(/\\/, "\\\\", s)
        gsub(/"/, "\\\"", s)
        return s
    }
    FILENAME == f_rules {
        if ($1 == "APP") {
            w[$2] = ($4 == "1" ? 1 : 0)
            m[$2] = ($5 == "1" ? 1 : 0)
        }
        next
    }
    BEGIN { printf "{\"ok\":true,\"apps\":[" ; first = 1 }
    {
        pkg = $1; uid = $2; is_u = ($3 == "1" ? "true" : "false")
        if (pkg == "" || uid == "") next
        wb = (uid in w && w[uid] == 1) ? "true" : "false"
        mb = (uid in m && m[uid] == 1) ? "true" : "false"
        if (!first) printf ","
        first = 0
        printf "{\"package\":\"%s\",\"uid\":%s,\"is_user\":%s,\"wifi_blocked\":%s,\"mobile_blocked\":%s}", esc(pkg), uid, is_u, wb, mb
    }
    END { printf "]}\n" }
    ' "$RULES_FILE" "$APP_CACHE"
}

get_status() {
    app_cnt="$($AWK '/^APP\|/{c++} END{print c+0}' "$RULES_FILE" 2>/dev/null)"
    cli_cnt="$($AWK '/^CLIENT\|/{c++} END{print c+0}' "$RULES_FILE" 2>/dev/null)"
    [ -z "$app_cnt" ] && app_cnt=0
    [ -z "$cli_cnt" ] && cli_cnt=0
    boundary_ok="false"
    if iptables -w 2 -C INPUT -j NETDROID_IN 2>/dev/null; then
        boundary_ok="true"
    fi
    rules_json='{"apps":{},"clients":{}}'
    [ -s "$JSON_FILE" ] && rules_json="$(cat "$JSON_FILE")"
    printf '{"ok":true,"security_boundary":%s,"port":%s,"blocked_apps_count":%s,"blocked_clients_count":%s,"rules":%s}\n' \
        "$boundary_ok" "$PORT" "$app_cnt" "$cli_cnt" "$rules_json"
}

# Main dispatcher
CMD="$1"
if [ -z "$CMD" ] && [ -n "$REQUEST_METHOD" ]; then
    printf 'Content-Type: application/json\r\nCache-Control: no-store\r\n\r\n'
    get_status
    exit 0
fi

case "$CMD" in
    apply_boundary) apply_boundary ;;
    apply_rules)    apply_rules ;;
    apply_all)      apply_all ;;
    set_app)        set_app_rule "$2" "$3" "$4" "$5" ;;
    set_client)     set_client_rule "$2" "$3" "$4" "$5" ;;
    clear_all)      clear_all_rules ;;
    cleanup)        cleanup_chains ;;
    list_apps)      list_apps "$2" ;;
    status|"")      get_status ;;
    *)              printf '{"ok":false,"error":"Unknown firewall command"}\n'; exit 1 ;;
esac
