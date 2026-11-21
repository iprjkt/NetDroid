#!/system/bin/sh
# NetDroid - Module Uninstall Cleanup Script
# Stops daemons, restores sysctl TTL/Hop-Limit, restores restricted background apps,
# cleans custom iptables/ip6tables chains, and removes persistent files.

export PATH="/data/adb/ksu/bin:/data/adb/ap/bin:/data/adb/magisk:/system/bin:/system/xbin:/vendor/bin:$PATH"

MODDIR="${0%/*}"
[ "$MODDIR" = "$0" ] && MODDIR="$(pwd)"
DATA_DIR="/data/adb/netdroid"

# 1. Stop running daemons
for pf in "$DATA_DIR/logger.pid" "$DATA_DIR/httpd.pid"; do
    if [ -f "$pf" ]; then
        pid="$(cat "$pf" 2>/dev/null)"
        [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
    fi
done
/data/adb/ksu/bin/busybox pkill -f "httpd.*netdroid" 2>/dev/null || true

# 2. Restore background apps, auto_sync, BPF offload, and TTL/Hop-Limit to defaults (64)
if [ -f "$MODDIR/webroot/cgi-bin/mode.sh" ]; then
    sh "$MODDIR/webroot/cgi-bin/mode.sh" cleanup >/dev/null 2>&1 || true
else
    if [ -s "$DATA_DIR/restricted_apps.list" ]; then
        while IFS= read -r pkg; do
            [ -z "$pkg" ] && continue
            cmd appops set "$pkg" RUN_IN_BACKGROUND allow >/dev/null 2>&1 || true
            cmd appops set "$pkg" RUN_ANY_IN_BACKGROUND allow >/dev/null 2>&1 || true
            am set-inactive "$pkg" false >/dev/null 2>&1 || true
        done < "$DATA_DIR/restricted_apps.list"
    fi
    sysctl -w net.ipv4.ip_default_ttl=64 >/dev/null 2>&1 || true
    sysctl -w net.ipv6.conf.all.hop_limit=64 >/dev/null 2>&1 || true
    sysctl -w net.ipv6.conf.default.hop_limit=64 >/dev/null 2>&1 || true
    settings put global auto_sync 1 >/dev/null 2>&1 || true
    settings put global tether_offload_disabled 0 >/dev/null 2>&1 || true
fi

# 2b. Restore default battery charging & clean DNS/Adblock rules
if [ -f "$MODDIR/webroot/cgi-bin/battery.sh" ]; then
    sh "$MODDIR/webroot/cgi-bin/battery.sh" restore >/dev/null 2>&1 || true
else
    printf '0' > /sys/class/power_supply/battery/input_suspend 2>/dev/null || true
    printf '1' > /sys/class/power_supply/battery/charging_enabled 2>/dev/null || true
fi
if [ -f "$MODDIR/webroot/cgi-bin/dns.sh" ]; then
    sh "$MODDIR/webroot/cgi-bin/dns.sh" cleanup >/dev/null 2>&1 || true
fi
if [ -f "$MODDIR/webroot/cgi-bin/ssh.sh" ]; then
    sh "$MODDIR/webroot/cgi-bin/ssh.sh" stop >/dev/null 2>&1 || true
fi
if [ -f "$MODDIR/webroot/cgi-bin/share.sh" ]; then
    sh "$MODDIR/webroot/cgi-bin/share.sh" stop >/dev/null 2>&1 || true
fi

# 3. Clean custom iptables/ip6tables chains
if [ -f "$MODDIR/webroot/cgi-bin/firewall.sh" ]; then
    sh "$MODDIR/webroot/cgi-bin/firewall.sh" cleanup >/dev/null 2>&1 || true
else
    for ipt in iptables ip6tables; do
        command -v "$ipt" >/dev/null 2>&1 || continue
        for pair in "INPUT:NETDROID_IN" "OUTPUT:NETDROID_OUT" "FORWARD:NETDROID_FWD"; do
            p="${pair%%:*}"; c="${pair##*:}"
            while "$ipt" -w 2 -C "$p" -j "$c" 2>/dev/null; do
                "$ipt" -w 2 -D "$p" -j "$c" 2>/dev/null || break
            done
            "$ipt" -w 2 -F "$c" 2>/dev/null || true
            "$ipt" -w 2 -X "$c" 2>/dev/null || true
        done
        while "$ipt" -w 2 -t mangle -C POSTROUTING -j NETDROID_TTL 2>/dev/null; do
            "$ipt" -w 2 -t mangle -D POSTROUTING -j NETDROID_TTL 2>/dev/null || break
        done
        "$ipt" -w 2 -t mangle -F NETDROID_TTL 2>/dev/null || true
        "$ipt" -w 2 -t mangle -X NETDROID_TTL 2>/dev/null || true
    done
fi

# 4. Remove persistent data directory
rm -rf "$DATA_DIR" 2>/dev/null || true
