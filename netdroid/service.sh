#!/system/bin/sh
# NetDroid - Boot-Time Service Daemon
# Starts BusyBox httpd, persistent quota logger, network security boundary,
# and restores saved firewall & mode/TTL state.

export PATH="/data/adb/ksu/bin:/data/adb/ap/bin:/data/adb/magisk:/system/bin:/system/xbin:/vendor/bin:$PATH"

MODDIR="${0%/*}"
[ "$MODDIR" = "$0" ] && MODDIR="$(pwd)"
MODDIR="$(CDPATH= cd -- "$MODDIR" && pwd)"

DATA_DIR="/data/adb/netdroid"
CONFIG_FILE="$DATA_DIR/config.env"
WEBROOT="$MODDIR/webroot"
CGI_DIR="$WEBROOT/cgi-bin"
HTTPD_PID="$DATA_DIR/httpd.pid"
LOGGER_PID="$DATA_DIR/logger.pid"
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

log_msg() {
    ts="$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo '0')"
    printf '[%s] [service] %s\n' "$ts" "$1" >> "$LOG_FILE" 2>/dev/null || true
    # Keep log bounded (~200 lines)
    if [ -f "$LOG_FILE" ] && [ "$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)" -gt 300 ]; then
        $BB tail -n 150 "$LOG_FILE" > "$LOG_FILE.tmp.$$" 2>/dev/null && mv "$LOG_FILE.tmp.$$" "$LOG_FILE"
    fi
}

load_port() {
    PORT=8765
    if [ -f "$CONFIG_FILE" ]; then
        . "$CONFIG_FILE" 2>/dev/null
    fi
    [ -z "$PORT" ] && PORT=8765
}

ensure_data_dir() {
    mkdir -p "$DATA_DIR/config" 2>/dev/null
    chmod 0755 "$DATA_DIR" "$DATA_DIR/config" 2>/dev/null || true
    # Keep /data/adb/modules/netdroid/config symlinked to persistent /data/adb/netdroid/config
    if [ ! -e "$MODDIR/config" ]; then
        ln -s "$DATA_DIR/config" "$MODDIR/config" 2>/dev/null || true
    fi
    if [ ! -f "$CONFIG_FILE" ]; then
        DEFAULT_HASH="03ac674216f3e15c761ee1a5e255f067953623c8b388b4459e13f978d7c846f4"
        cat <<EOF > "$CONFIG_FILE"
PORT=8765
MODE=normal
TTL=65
MANGLE_TTL=1
TTL_STANDALONE=0
AUTO_SYNC_DISABLE=1
BPF_OFFLOAD_DISABLE=0
AUTH_ENABLED=1
PIN_HASH=$DEFAULT_HASH
PIN_IS_DEFAULT=1
QUOTA_DAILY_MB=2048
QUOTA_MONTHLY_MB=30720
QUOTA_WARN_PCT=80
QUOTA_CRIT_PCT=90
EOF
        chmod 0600 "$CONFIG_FILE" 2>/dev/null || true
    fi
    [ -f "$DATA_DIR/firewall.rules" ] || : > "$DATA_DIR/firewall.rules"
    [ -f "$DATA_DIR/auth_tokens.db" ] || : > "$DATA_DIR/auth_tokens.db"
}

stop_httpd() {
    if [ -f "$HTTPD_PID" ]; then
        old_pid="$(cat "$HTTPD_PID" 2>/dev/null)"
        if [ -n "$old_pid" ]; then
            kill "$old_pid" 2>/dev/null || true
        fi
        rm -f "$HTTPD_PID"
    fi
    # Clean any stray netdroid httpd instances bound to our webroot
    if [ -n "$BB" ]; then
        $BB pkill -f "httpd.*$WEBROOT" 2>/dev/null || true
    fi
}

start_httpd() {
    load_port
    stop_httpd

    if [ -z "$BB" ]; then
        log_msg "ERROR: BusyBox not found, cannot start httpd"
        return 1
    fi

    # Write lightweight httpd.conf in DATA_DIR for proper MIME types
    # Note: BusyBox httpd uses leading dot (.ext:mime), NOT *.ext:mime (which means CGI interpreter!)
    HTTPD_CONF="$DATA_DIR/httpd.conf"
    cat <<'EOF' > "$HTTPD_CONF"
I:index.html
.html:text/html; charset=utf-8
.css:text/css; charset=utf-8
.js:application/javascript; charset=utf-8
.json:application/json; charset=utf-8
.svg:image/svg+xml
.webp:image/webp
.png:image/png
.jpg:image/jpeg
.jpeg:image/jpeg
.ico:image/x-icon
EOF

    # Ensure CGI scripts are executable
    chmod 0755 "$CGI_DIR"/*.sh 2>/dev/null || true

    # Detach cleanly with setsid & closed stdio so callers (adb/CGI) never block
    if "$BB" setsid true >/dev/null 2>&1; then
        "$BB" setsid "$BB" httpd -f -p "0.0.0.0:$PORT" -h "$WEBROOT" -c "$HTTPD_CONF" </dev/null >/dev/null 2>&1 &
    else
        "$BB" httpd -f -p "0.0.0.0:$PORT" -h "$WEBROOT" -c "$HTTPD_CONF" </dev/null >/dev/null 2>&1 &
    fi
    pid=$!
    printf '%s\n' "$pid" > "$HTTPD_PID"
    log_msg "Started BusyBox httpd (PID=$pid) on 0.0.0.0:$PORT"
}

stop_logger() {
    if [ -f "$LOGGER_PID" ]; then
        old_pid="$(cat "$LOGGER_PID" 2>/dev/null)"
        if [ -n "$old_pid" ]; then
            kill "$old_pid" 2>/dev/null || true
        fi
        rm -f "$LOGGER_PID"
    fi
}

start_logger() {
    stop_logger
    logger_cmd="
        export PATH=\"$PATH\"
        tick=0
        while true; do
            sh \"$CGI_DIR/monitor.sh\" update_quota >/dev/null 2>&1 || true
            tick=\$((tick + 1))
            # Every 15 seconds (3 ticks): enforce Smart Charging & Thermal Guard policy
            if [ \$((tick % 3)) -eq 0 ]; then
                sh \"$CGI_DIR/battery.sh\" enforce >/dev/null 2>&1 || true
            fi
            # Every 30 seconds (6 ticks): watchdog httpd, firewall boundary & DNS/Adblock
            if [ \$((tick % 6)) -eq 0 ]; then
                hpid=\"\$(cat \"$HTTPD_PID\" 2>/dev/null)\"
                if [ -z \"\$hpid\" ] || ! kill -0 \"\$hpid\" 2>/dev/null; then
                    sh \"$MODDIR/service.sh\" restart_httpd >/dev/null 2>&1 || true
                fi
                if ! iptables -w 2 -C INPUT -j NETDROID_IN 2>/dev/null; then
                    sh \"$CGI_DIR/firewall.sh\" apply_all >/dev/null 2>&1 || true
                fi
                sh \"$CGI_DIR/dns.sh\" watchdog >/dev/null 2>&1 || true
            fi
            sleep 5
        done
    "
    if [ -n "$BB" ] && "$BB" setsid true >/dev/null 2>&1; then
        "$BB" setsid sh -c "$logger_cmd" </dev/null >/dev/null 2>&1 &
    else
        sh -c "$logger_cmd" </dev/null >/dev/null 2>&1 &
    fi
    lpid=$!
    printf '%s\n' "$lpid" > "$LOGGER_PID"
    log_msg "Started quota logger & watchdog daemon (PID=$lpid)"
}

# Handle direct management subcommands
case "$1" in
    restart_httpd)
        ensure_data_dir
        sh "$CGI_DIR/firewall.sh" apply_boundary >/dev/null 2>&1 || true
        start_httpd
        exit 0
        ;;
    stop)
        stop_logger
        stop_httpd
        sh "$CGI_DIR/dns.sh" cleanup >/dev/null 2>&1 || true
        sh "$CGI_DIR/battery.sh" restore >/dev/null 2>&1 || true
        log_msg "Stopped NetDroid daemons"
        exit 0
        ;;
    start|restart)
        ensure_data_dir
        sh "$CGI_DIR/firewall.sh" apply_all >/dev/null 2>&1 || true
        sh "$CGI_DIR/mode.sh" restore_boot >/dev/null 2>&1 || true
        sh "$CGI_DIR/battery.sh" enforce >/dev/null 2>&1 || true
        sh "$CGI_DIR/dns.sh" apply >/dev/null 2>&1 || true
        start_httpd
        start_logger
        exit 0
        ;;
esac

# Default boot-time execution
# Wait until Android finishes booting (max 90 seconds)
wait_cnt=0
while [ "$(getprop sys.boot_completed 2>/dev/null)" != "1" ] && [ "$wait_cnt" -lt 45 ]; do
    sleep 2
    wait_cnt=$((wait_cnt + 1))
done
sleep 3

ensure_data_dir
log_msg "NetDroid boot service starting..."

# 1. Apply network security boundary & persisted firewall rules
sh "$CGI_DIR/firewall.sh" apply_all >/dev/null 2>&1 || true

# 2. Restore saved mode & TTL / Hop-Limit state
sh "$CGI_DIR/mode.sh" restore_boot >/dev/null 2>&1 || true

# 3. Apply Smart Charging & Network-Wide DNS/Adblock state
sh "$CGI_DIR/battery.sh" enforce >/dev/null 2>&1 || true
sh "$CGI_DIR/dns.sh" apply >/dev/null 2>&1 || true

# 4. Start BusyBox httpd & quota/battery/dns daemon
start_httpd
start_logger

log_msg "NetDroid boot service ready"
