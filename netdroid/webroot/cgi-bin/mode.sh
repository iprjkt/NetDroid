#!/system/bin/sh
# NetDroid - Dual Operation Mode (Normal / Tethering) & TTL / Hop-Limit Controller

export PATH="/data/adb/ksu/bin:/data/adb/ap/bin:/data/adb/magisk:/system/bin:/system/xbin:/vendor/bin:$PATH"

DATA_DIR="/data/adb/netdroid"
CONFIG_FILE="$DATA_DIR/config.env"
RESTRICTED_LIST="$DATA_DIR/restricted_apps.list"
LOG_FILE="$DATA_DIR/netdroid.log"

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

# Defaults
MODE="normal"
TTL=65
MANGLE_TTL=1
TTL_STANDALONE=0
AUTO_SYNC_DISABLE=1
BPF_OFFLOAD_DISABLE=0

load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        . "$CONFIG_FILE" 2>/dev/null
    fi
    [ -z "$MODE" ] && MODE="normal"
    [ -z "$TTL" ] && TTL=65
    [ -z "$MANGLE_TTL" ] && MANGLE_TTL=1
    [ -z "$TTL_STANDALONE" ] && TTL_STANDALONE=0
    [ -z "$AUTO_SYNC_DISABLE" ] && AUTO_SYNC_DISABLE=1
    [ -z "$BPF_OFFLOAD_DISABLE" ] && BPF_OFFLOAD_DISABLE=0
}

save_config_key() {
    key="$1"
    val="$2"
    mkdir -p "$DATA_DIR" 2>/dev/null
    [ -f "$CONFIG_FILE" ] || : > "$CONFIG_FILE"
    tmp="$DATA_DIR/.config.env.tmp.$$"
    $GREP -v "^${key}=" "$CONFIG_FILE" > "$tmp" 2>/dev/null || true
    printf '%s=%s\n' "$key" "$val" >> "$tmp"
    mv "$tmp" "$CONFIG_FILE"
    chmod 0600 "$CONFIG_FILE" 2>/dev/null || true
}

log_msg() {
    ts="$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo '0')"
    printf '[%s] [mode] %s\n' "$ts" "$1" >> "$LOG_FILE" 2>/dev/null || true
}

is_valid_ttl() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$1" -ge 1 ] && [ "$1" -le 255 ]
}

has_xt_ttl() {
    [ -r /proc/net/ip_tables_targets ] && $GREP -qx 'TTL' /proc/net/ip_tables_targets 2>/dev/null
}

has_xt_hl() {
    [ -r /proc/net/ip6_tables_targets ] && $GREP -qx 'HL' /proc/net/ip6_tables_targets 2>/dev/null
}

flush_mangle_ttl() {
    for ipt in iptables ip6tables; do
        command -v "$ipt" >/dev/null 2>&1 || continue
        while "$ipt" -w 2 -t mangle -C POSTROUTING -j NETDROID_TTL 2>/dev/null; do
            "$ipt" -w 2 -t mangle -D POSTROUTING -j NETDROID_TTL 2>/dev/null || break
        done
        "$ipt" -w 2 -t mangle -F NETDROID_TTL 2>/dev/null || true
        "$ipt" -w 2 -t mangle -X NETDROID_TTL 2>/dev/null || true
    done
}

apply_mangle_ttl() {
    target_ttl="$1"
    flush_mangle_ttl

    if [ "$MANGLE_TTL" != "1" ]; then
        return 0
    fi

    if has_xt_ttl && command -v iptables >/dev/null 2>&1; then
        iptables -w 2 -t mangle -N NETDROID_TTL 2>/dev/null || true
        iptables -w 2 -t mangle -I POSTROUTING 1 -j NETDROID_TTL 2>/dev/null || true
        for iface in rmnet+ r_rmnet+ ccmni+ wwan+ pdp+; do
            iptables -w 2 -t mangle -A NETDROID_TTL -o "$iface" -j TTL --ttl-set "$target_ttl" 2>/dev/null || true
        done
    fi

    if has_xt_hl && command -v ip6tables >/dev/null 2>&1; then
        ip6tables -w 2 -t mangle -N NETDROID_TTL 2>/dev/null || true
        ip6tables -w 2 -t mangle -I POSTROUTING 1 -j NETDROID_TTL 2>/dev/null || true
        for iface in rmnet+ r_rmnet+ ccmni+ wwan+ pdp+; do
            ip6tables -w 2 -t mangle -A NETDROID_TTL -o "$iface" -j HL --hl-set "$target_ttl" 2>/dev/null || true
        done
    fi
}

apply_sysctl_ttl() {
    target_ttl="$1"
    sysctl -w net.ipv4.ip_default_ttl="$target_ttl" >/dev/null 2>&1 || \
        printf '%s' "$target_ttl" > /proc/sys/net/ipv4/ip_default_ttl 2>/dev/null || true

    sysctl -w net.ipv6.conf.all.hop_limit="$target_ttl" >/dev/null 2>&1 || \
        printf '%s' "$target_ttl" > /proc/sys/net/ipv6/conf/all/hop_limit 2>/dev/null || true

    sysctl -w net.ipv6.conf.default.hop_limit="$target_ttl" >/dev/null 2>&1 || \
        printf '%s' "$target_ttl" > /proc/sys/net/ipv6/conf/default/hop_limit 2>/dev/null || true

    # Update active cellular IPv6 interfaces immediately
    for f in /proc/sys/net/ipv6/conf/rmnet*/hop_limit /proc/sys/net/ipv6/conf/ccmni*/hop_limit /proc/sys/net/ipv6/conf/wwan*/hop_limit; do
        [ -w "$f" ] && printf '%s' "$target_ttl" > "$f" 2>/dev/null || true
    done
}

# Packages excluded from background restriction in Tethering Mode
is_exempt_pkg() {
    case "$1" in
        me.weishu.kernelsu*|com.rifsxd.ksunext*|me.bmax.apatch*|com.topjohnwu.magisk*|\
        io.github.vvb2060.magisk*|com.android.*|android|com.google.android.webview*|\
        com.google.android.networkstack*|com.qualcomm.*|org.codeaurora.*)
            return 0 ;;
        *)
            return 1 ;;
    esac
}

restrict_background_apps() {
    tmp_list="$DATA_DIR/.restricted.tmp.$$"
    : > "$tmp_list"

    # Snapshot all third-party packages
    pm list packages -3 2>/dev/null | $SED 's/^package://; s/\r$//' | while IFS= read -r pkg; do
        [ -z "$pkg" ] && continue
        is_exempt_pkg "$pkg" && continue
        printf '%s\n' "$pkg" >> "$tmp_list"
    done

    # Merge any previously restricted apps so nothing gets orphaned
    if [ -s "$RESTRICTED_LIST" ]; then
        cat "$RESTRICTED_LIST" >> "$tmp_list"
    fi
    $BB sort -u "$tmp_list" > "$RESTRICTED_LIST" 2>/dev/null || mv "$tmp_list" "$RESTRICTED_LIST"
    rm -f "$tmp_list" 2>/dev/null

    # Apply background restrictions asynchronously-safe or fast sequential
    while IFS= read -r pkg; do
        [ -z "$pkg" ] && continue
        cmd appops set "$pkg" RUN_IN_BACKGROUND ignore >/dev/null 2>&1 || true
        cmd appops set "$pkg" RUN_ANY_IN_BACKGROUND ignore >/dev/null 2>&1 || true
        am set-inactive "$pkg" true >/dev/null 2>&1 || true
    done < "$RESTRICTED_LIST"

    # Lightweight Doze & memory trim without killing hotspot or httpd
    am kill-all >/dev/null 2>&1 || true
    dumpsys deviceidle step light >/dev/null 2>&1 || true

    if [ "$AUTO_SYNC_DISABLE" = "1" ]; then
        settings put global auto_sync 0 >/dev/null 2>&1 || true
    fi
}

restore_background_apps() {
    if [ -s "$RESTRICTED_LIST" ]; then
        while IFS= read -r pkg; do
            [ -z "$pkg" ] && continue
            cmd appops set "$pkg" RUN_IN_BACKGROUND allow >/dev/null 2>&1 || true
            cmd appops set "$pkg" RUN_ANY_IN_BACKGROUND allow >/dev/null 2>&1 || true
            am set-inactive "$pkg" false >/dev/null 2>&1 || true
        done < "$RESTRICTED_LIST"
    fi
    : > "$RESTRICTED_LIST"

    if [ "$AUTO_SYNC_DISABLE" = "1" ]; then
        settings put global auto_sync 1 >/dev/null 2>&1 || true
    fi
}

enter_tethering_mode() {
    load_config
    target_ttl="$TTL"
    is_valid_ttl "$target_ttl" || target_ttl=65

    # Enable IPv4 forwarding
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || \
        printf '1' > /proc/sys/net/ipv4/ip_forward 2>/dev/null || true

    # Apply TTL / Hop-Limit + Mangle failsafe
    apply_sysctl_ttl "$target_ttl"
    apply_mangle_ttl "$target_ttl"

    if [ "$BPF_OFFLOAD_DISABLE" = "1" ]; then
        settings put global tether_offload_disabled 1 >/dev/null 2>&1 || true
    fi

    save_config_key MODE "tethering"
    MODE="tethering"

    # Restrict third-party background apps (runs in background if requested, or inline)
    if [ "$1" = "async" ]; then
        restrict_background_apps >/dev/null 2>&1 &
    else
        restrict_background_apps
    fi

    # Re-evaluate Smart Charging policy when switching modes (for tethering_only)
    SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
    [ -x "$SCRIPT_DIR/battery.sh" ] && sh "$SCRIPT_DIR/battery.sh" enforce >/dev/null 2>&1 || true

    log_msg "Switched to Tethering Mode (TTL=$target_ttl, MANGLE=$MANGLE_TTL)"
    get_status
}

enter_normal_mode() {
    load_config

    restore_background_apps

    if [ "$TTL_STANDALONE" = "1" ]; then
        apply_sysctl_ttl "$TTL"
        apply_mangle_ttl "$TTL"
    else
        apply_sysctl_ttl 64
        flush_mangle_ttl
    fi

    if [ "$BPF_OFFLOAD_DISABLE" = "1" ]; then
        settings put global tether_offload_disabled 0 >/dev/null 2>&1 || true
    fi

    save_config_key MODE "normal"
    MODE="normal"

    # Re-evaluate Smart Charging policy when returning to Normal Mode
    SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
    [ -x "$SCRIPT_DIR/battery.sh" ] && sh "$SCRIPT_DIR/battery.sh" enforce >/dev/null 2>&1 || true

    log_msg "Switched to Normal Mode"
    get_status
}

set_ttl_config() {
    load_config
    new_ttl="$1"
    new_mangle="$2"
    new_standalone="$3"

    if ! is_valid_ttl "$new_ttl"; then
        printf '{"ok":false,"error":"TTL must be between 1 and 255"}\n'
        return 1
    fi

    save_config_key TTL "$new_ttl"
    TTL="$new_ttl"

    if [ -n "$new_mangle" ]; then
        [ "$new_mangle" = "1" ] && MANGLE_TTL=1 || MANGLE_TTL=0
        save_config_key MANGLE_TTL "$MANGLE_TTL"
    fi

    if [ -n "$new_standalone" ]; then
        [ "$new_standalone" = "1" ] && TTL_STANDALONE=1 || TTL_STANDALONE=0
        save_config_key TTL_STANDALONE "$TTL_STANDALONE"
    fi

    # Immediately apply if in Tethering Mode OR standalone TTL override is on (or if explicit non-64 requested)
    if [ "$MODE" = "tethering" ] || [ "$TTL_STANDALONE" = "1" ]; then
        apply_sysctl_ttl "$TTL"
        apply_mangle_ttl "$TTL"
    elif [ "$new_ttl" = "64" ]; then
        apply_sysctl_ttl 64
        flush_mangle_ttl
    else
        # User explicitly clicked a custom TTL in Settings: enable standalone override and apply
        TTL_STANDALONE=1
        save_config_key TTL_STANDALONE 1
        apply_sysctl_ttl "$TTL"
        apply_mangle_ttl "$TTL"
    fi

    log_msg "Updated TTL=$TTL MANGLE=$MANGLE_TTL STANDALONE=$TTL_STANDALONE"
    get_status
}

restore_boot_state() {
    load_config
    if [ "$MODE" = "tethering" ]; then
        sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
        apply_sysctl_ttl "$TTL"
        apply_mangle_ttl "$TTL"
        if [ "$BPF_OFFLOAD_DISABLE" = "1" ]; then
            settings put global tether_offload_disabled 1 >/dev/null 2>&1 || true
        fi
        log_msg "Boot restore: Tethering Mode active (TTL=$TTL)"
    elif [ "$TTL_STANDALONE" = "1" ]; then
        apply_sysctl_ttl "$TTL"
        apply_mangle_ttl "$TTL"
        log_msg "Boot restore: Normal Mode with standalone TTL=$TTL"
    else
        apply_sysctl_ttl 64
        flush_mangle_ttl
    fi
}

cleanup_all() {
    load_config
    restore_background_apps
    apply_sysctl_ttl 64
    flush_mangle_ttl
    settings put global tether_offload_disabled 0 >/dev/null 2>&1 || true
}

get_status() {
    load_config
    cur_ttl="$(cat /proc/sys/net/ipv4/ip_default_ttl 2>/dev/null || echo 64)"
    cur_hl="$(cat /proc/sys/net/ipv6/conf/all/hop_limit 2>/dev/null || echo 64)"
    cur_fwd="$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo 0)"
    xt_ttl="false"; has_xt_ttl && xt_ttl="true"
    xt_hl="false"; has_xt_hl && xt_hl="true"
    mangle_active="false"
    if iptables -w 2 -t mangle -C POSTROUTING -j NETDROID_TTL 2>/dev/null; then
        mangle_active="true"
    fi
    rest_cnt=0
    [ -s "$RESTRICTED_LIST" ] && rest_cnt="$(wc -l < "$RESTRICTED_LIST" 2>/dev/null | $TR -d ' ')"
    [ -z "$rest_cnt" ] && rest_cnt=0
    bpf_val="$(settings get global tether_offload_disabled 2>/dev/null | $TR -d '\r\n')"
    bpf_off="false"
    [ "$bpf_val" = "1" ] && bpf_off="true"

    printf '{"ok":true,"mode":"%s","configured_ttl":%s,"current_ttl":%s,"current_hop_limit":%s,"ip_forward":%s,"mangle_enabled":%s,"mangle_active":%s,"ttl_standalone":%s,"xt_ttl_supported":%s,"xt_hl_supported":%s,"auto_sync_disable":%s,"bpf_offload_disabled":%s,"restricted_apps_count":%s}\n' \
        "$MODE" "$TTL" "$cur_ttl" "$cur_hl" "$cur_fwd" \
        "$([ "$MANGLE_TTL" = "1" ] && echo true || echo false)" \
        "$mangle_active" \
        "$([ "$TTL_STANDALONE" = "1" ] && echo true || echo false)" \
        "$xt_ttl" "$xt_hl" \
        "$([ "$AUTO_SYNC_DISABLE" = "1" ] && echo true || echo false)" \
        "$bpf_off" "$rest_cnt"
}

CMD="$1"
if [ -z "$CMD" ] && [ -n "$REQUEST_METHOD" ]; then
    printf 'Content-Type: application/json\r\nCache-Control: no-store\r\n\r\n'
    get_status
    exit 0
fi

case "$CMD" in
    tethering)     enter_tethering_mode "$2" ;;
    normal)        enter_normal_mode ;;
    set_ttl)       set_ttl_config "$2" "$3" "$4" ;;
    restore_boot)  restore_boot_state ;;
    cleanup)       cleanup_all ;;
    status|"")     get_status ;;
    *)             printf '{"ok":false,"error":"Unknown mode command"}\n'; exit 1 ;;
esac
