#!/system/bin/sh
# NetDroid - KernelSU Module Installer Script

SKIPUNZIP=0

DATA_DIR="/data/adb/netdroid"

detect_busybox() {
    for bb in /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox /data/adb/magisk/busybox /system/xbin/busybox /system/bin/busybox; do
        if [ -x "$bb" ]; then
            echo "$bb"
            return 0
        fi
    done
    command -v busybox 2>/dev/null
}

BB="$(detect_busybox)"

ui_print "*********************************************"
ui_print "   NetDroid - Pocket Router & Expressive UI  "
ui_print "*********************************************"
ui_print "- Initializing persistent storage: $DATA_DIR"

mkdir -p "$DATA_DIR/config"
chmod 0755 "$DATA_DIR" "$DATA_DIR/config"
ln -sf "$DATA_DIR/config" "$MODPATH/config" 2>/dev/null || true

# Initialize Smart Charging & DNS/Adblock configs if missing
if [ ! -f "$DATA_DIR/config/battery.json" ]; then
    printf '{"enabled":false,"stop_threshold":80,"resume_threshold":65,"max_temp":42.0,"current_limit_ma":0,"tethering_only":false}\n' > "$DATA_DIR/config/battery.json"
fi
if [ ! -f "$DATA_DIR/config/dns.json" ]; then
    printf '{"adblock_enabled":false,"force_router_dns":false,"preset":"adguard","custom_ipv4":"","custom_ipv6":"","whitelist":[],"blacklist":[],"blocked_domains_count":0,"last_updated":0,"last_error":""}\n' > "$DATA_DIR/config/dns.json"
fi
[ -f "$DATA_DIR/config/adblock.hosts" ] || : > "$DATA_DIR/config/adblock.hosts"
if [ ! -f "$DATA_DIR/config/ssh.json" ]; then
    printf '{"enabled":false,"port":2222,"password_auth":true}\n' > "$DATA_DIR/config/ssh.json"
fi
[ -f "$DATA_DIR/config/authorized_keys" ] || : > "$DATA_DIR/config/authorized_keys"
if [ ! -f "$DATA_DIR/config/share.json" ]; then
    printf '{"enabled":true,"root_path":"/sdcard/NetDroidShare","read_only":false,"webdav_enabled":false,"webdav_port":8766}\n' > "$DATA_DIR/config/share.json"
fi
chmod 0644 "$DATA_DIR/config/battery.json" "$DATA_DIR/config/dns.json" "$DATA_DIR/config/adblock.hosts" "$DATA_DIR/config/ssh.json" "$DATA_DIR/config/share.json" 2>/dev/null
chmod 0600 "$DATA_DIR/config/authorized_keys" 2>/dev/null

# Compute SHA-256 of default PIN "1234"
if [ -n "$BB" ]; then
    DEFAULT_PIN_HASH="$(printf '%s' '1234' | "$BB" sha256sum | "$BB" awk '{print $1}')"
else
    DEFAULT_PIN_HASH="03ac674216f3e15c761ee1a5e255f067953623c8b388b4459e13f978d7c846f4"
fi

# Initialize default config.env if missing (preserves existing config on upgrade)
if [ ! -f "$DATA_DIR/config.env" ]; then
    ui_print "- Creating default configuration..."
    cat <<EOF > "$DATA_DIR/config.env"
PORT=8765
MODE=normal
TTL=65
MANGLE_TTL=1
TTL_STANDALONE=0
AUTO_SYNC_DISABLE=1
BPF_OFFLOAD_DISABLE=0
AUTH_ENABLED=1
PIN_HASH=$DEFAULT_PIN_HASH
PIN_IS_DEFAULT=1
QUOTA_DAILY_MB=2048
QUOTA_MONTHLY_MB=30720
QUOTA_WARN_PCT=80
QUOTA_CRIT_PCT=90
EOF
fi

# Initialize persistent quota.json if missing
if [ ! -f "$DATA_DIR/quota.json" ]; then
    TODAY="$(date +%Y-%m-%d 2>/dev/null || echo '1970-01-01')"
    MONTH="$(date +%Y-%m 2>/dev/null || echo '1970-01')"
    NOW="$(date +%s 2>/dev/null || echo 0)"
    cat <<EOF > "$DATA_DIR/quota.json"
{"session_rx":0,"session_tx":0,"daily_rx":0,"daily_tx":0,"monthly_rx":0,"monthly_tx":0,"hotspot_session_rx":0,"hotspot_session_tx":0,"day_key":"$TODAY","month_key":"$MONTH","session_started":$NOW,"last_cell_rx":0,"last_cell_tx":0,"last_hs_rx":0,"last_hs_tx":0,"last_ts":$NOW}
EOF
fi

# Initialize persistent firewall state if missing
if [ ! -f "$DATA_DIR/firewall.rules" ]; then
    : > "$DATA_DIR/firewall.rules"
fi

if [ ! -f "$DATA_DIR/firewall.json" ]; then
    printf '{"apps":{},"clients":{}}\n' > "$DATA_DIR/firewall.json"
fi

# Initialize persistent theme preferences if missing
if [ ! -f "$DATA_DIR/theme.json" ]; then
    cat <<'EOF' > "$DATA_DIR/theme.json"
{"mode":"dark","preset":"aurora","useCustomBg":false,"autoExtract":true,"accent":"#A8C7FA","blur":12,"dim":42,"cardOpacity":76}
EOF
fi

if [ ! -f "$DATA_DIR/auth_tokens.db" ]; then
    : > "$DATA_DIR/auth_tokens.db"
fi

chmod 0600 "$DATA_DIR/config.env" "$DATA_DIR/auth_tokens.db" 2>/dev/null
chmod 0644 "$DATA_DIR/quota.json" "$DATA_DIR/firewall.json" "$DATA_DIR/firewall.rules" "$DATA_DIR/theme.json" 2>/dev/null

ui_print "- Setting module file permissions..."
set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm_recursive "$MODPATH/webroot/cgi-bin" 0 0 0755 0755
set_perm_recursive "$MODPATH/system/bin" 0 0 0755 0755
[ -d "$MODPATH/bin" ] && set_perm_recursive "$MODPATH/bin" 0 0 0755 0755
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/uninstall.sh" 0 0 0755

if [ -n "$BB" ]; then
    ui_print "- BusyBox detected: $BB"
else
    ui_print "! Warning: BusyBox not found in standard KSU path"
fi

ui_print "- Installation complete!"
ui_print "- WebUI (Local): http://127.0.0.1:8765"
ui_print "- WebUI (LAN):   http://<hotspot-gateway>:8765"
ui_print "- Default LAN PIN: 1234 (change in Settings)"
ui_print "- CLI Helper: netdroid status"
ui_print "*********************************************"
