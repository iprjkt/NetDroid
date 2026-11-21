#!/system/bin/sh
# NetDroid - Smart Battery & Charging Control Engine
# Auto-detects kernel power_supply sysfs nodes (Qualcomm sm6125/ginkgo + generic),
# enforces charge stop/resume thresholds with hysteresis, Idle/Bypass mode,
# charging current limits, and thermal safety cutoff.

export PATH="/data/adb/ksu/bin:/data/adb/ap/bin:/data/adb/magisk:/system/bin:/system/xbin:/vendor/bin:$PATH"

DATA_DIR="/data/adb/netdroid"
CFG_DIR="$DATA_DIR/config"
BATTERY_JSON="$CFG_DIR/battery.json"
MAIN_CFG="$DATA_DIR/config.env"
STATE_FILE="$DATA_DIR/.battery_state"
ORIG_CURR_FILE="$DATA_DIR/.orig_charge_current_ua"
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
TR="${BB:+$BB tr}"; [ -z "$TR" ] && TR="tr"

mkdir -p "$CFG_DIR" 2>/dev/null

# Ensure symlink /data/adb/modules/netdroid/config -> /data/adb/netdroid/config
for md in /data/adb/modules/netdroid /data/adb/modules_update/netdroid; do
    if [ -d "$md" ] && [ ! -e "$md/config" ]; then
        ln -s "$CFG_DIR" "$md/config" 2>/dev/null || true
    fi
done

ensure_default_config() {
    if [ ! -s "$BATTERY_JSON" ]; then
        cat <<'EOF' > "$BATTERY_JSON"
{"enabled":false,"stop_threshold":80,"resume_threshold":65,"max_temp":42.0,"current_limit_ma":0,"tethering_only":false}
EOF
        chmod 0644 "$BATTERY_JSON" 2>/dev/null || true
    fi
}

log_msg() {
    ts="$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo '0')"
    printf '[%s] [battery] %s\n' "$ts" "$1" >> "$LOG_FILE" 2>/dev/null || true
}

# Detect charging switch & current limit sysfs nodes
detect_nodes() {
    SWITCH_NODE=""
    SWITCH_MODE="none"        # charging_enabled | battery_charging_enabled | input_suspend
    SUSPEND_NODE=""
    IDLE_BYPASS="false"
    CURRENT_NODE=""
    CURRENT_NODE_MAIN=""

    if [ -w /sys/class/power_supply/battery/input_suspend ]; then
        SUSPEND_NODE="/sys/class/power_supply/battery/input_suspend"
    fi

    if [ -w /sys/class/power_supply/battery/charging_enabled ]; then
        SWITCH_NODE="/sys/class/power_supply/battery/charging_enabled"
        SWITCH_MODE="charging_enabled"
        IDLE_BYPASS="true"
    elif [ -w /sys/class/power_supply/battery/battery_charging_enabled ]; then
        SWITCH_NODE="/sys/class/power_supply/battery/battery_charging_enabled"
        SWITCH_MODE="battery_charging_enabled"
        IDLE_BYPASS="true"
    elif [ -n "$SUSPEND_NODE" ]; then
        SWITCH_NODE="$SUSPEND_NODE"
        SWITCH_MODE="input_suspend"
        IDLE_BYPASS="false"
    elif [ -w /sys/class/power_supply/usb/input_suspend ]; then
        SWITCH_NODE="/sys/class/power_supply/usb/input_suspend"
        SWITCH_MODE="input_suspend"
        IDLE_BYPASS="false"
    fi

    if [ -w /sys/class/power_supply/battery/constant_charge_current_max ]; then
        CURRENT_NODE="/sys/class/power_supply/battery/constant_charge_current_max"
        [ -w /sys/class/power_supply/main/constant_charge_current_max ] && \
            CURRENT_NODE_MAIN="/sys/class/power_supply/main/constant_charge_current_max"
    elif [ -w /sys/class/power_supply/usb/input_current_limit ]; then
        CURRENT_NODE="/sys/class/power_supply/usb/input_current_limit"
    elif [ -w /sys/class/power_supply/battery/input_current_limit ]; then
        CURRENT_NODE="/sys/class/power_supply/battery/input_current_limit"
    elif [ -w /sys/class/power_supply/usb/current_max ]; then
        CURRENT_NODE="/sys/class/power_supply/usb/current_max"
    fi

    # Snapshot original max charging current once so "Default" restores stock speed
    if [ -n "$CURRENT_NODE" ] && [ ! -s "$ORIG_CURR_FILE" ]; then
        orig="$(cat "$CURRENT_NODE" 2>/dev/null | $TR -cd '0-9')"
        if [ -n "$orig" ] && [ "$orig" -ge 500000 ] 2>/dev/null; then
            printf '%s\n' "$orig" > "$ORIG_CURR_FILE"
        fi
    fi
}

# Parse battery.json into shell variables
load_battery_config() {
    ensure_default_config
    eval "$($AWK '
    function gnum(s, k, def,   m, r) {
        r = "\"" k "\"[[:space:]]*:[[:space:]]*[0-9.]+"
        if (match(s, r)) {
            m = substr(s, RSTART, RLENGTH)
            sub(/^[^:]+:[[:space:]]*/, "", m)
            return m
        }
        return def
    }
    function gbool(s, k, def,   m, r) {
        r = "\"" k "\"[[:space:]]*:[[:space:]]*(true|false)"
        if (match(s, r)) {
            m = substr(s, RSTART, RLENGTH)
            return (m ~ /true/) ? 1 : 0
        }
        return def
    }
    { line = line $0 }
    END {
        printf "B_ENABLED=%d\n", gbool(line, "enabled", 0)
        printf "B_STOP=%d\n", gnum(line, "stop_threshold", 80) + 0
        printf "B_RESUME=%d\n", gnum(line, "resume_threshold", 65) + 0
        printf "B_MAX_TEMP=%s\n", gnum(line, "max_temp", 42.0)
        printf "B_CURR_MA=%d\n", gnum(line, "current_limit_ma", 0) + 0
        printf "B_TETH_ONLY=%d\n", gbool(line, "tethering_only", 0)
    }
    ' "$BATTERY_JSON" 2>/dev/null)"

    [ -z "$B_ENABLED" ] && B_ENABLED=0
    [ -z "$B_STOP" ] && B_STOP=80
    [ -z "$B_RESUME" ] && B_RESUME=65
    [ -z "$B_MAX_TEMP" ] && B_MAX_TEMP="42.0"
    [ -z "$B_CURR_MA" ] && B_CURR_MA=0
    [ -z "$B_TETH_ONLY" ] && B_TETH_ONLY=0
}

read_telemetry() {
    BAT_CAP="$(cat /sys/class/power_supply/battery/capacity 2>/dev/null | $TR -cd '0-9')"
    [ -z "$BAT_CAP" ] && BAT_CAP=0

    BAT_TEMP_RAW="$(cat /sys/class/power_supply/battery/temp 2>/dev/null | $TR -cd '0-9-')"
    [ -z "$BAT_TEMP_RAW" ] && BAT_TEMP_RAW=0
    BAT_TEMP_C="$($AWK -v t="$BAT_TEMP_RAW" 'BEGIN { printf "%.1f", t / 10 }')"

    BAT_STATUS_RAW="$(cat /sys/class/power_supply/battery/status 2>/dev/null | $TR -d '\r\n')"
    [ -z "$BAT_STATUS_RAW" ] && BAT_STATUS_RAW="Unknown"

    volt_raw="$(cat /sys/class/power_supply/battery/voltage_now 2>/dev/null | $TR -cd '0-9')"
    [ -z "$volt_raw" ] && volt_raw=0
    BAT_VOLT_MV="$($AWK -v v="$volt_raw" 'BEGIN { if (v > 100000) printf "%.0f", v / 1000; else printf "%.0f", v }')"

    curr_raw="$(cat /sys/class/power_supply/battery/current_now 2>/dev/null | $TR -cd '0-9-')"
    [ -z "$curr_raw" ] && curr_raw=0
    BAT_CURR_MA="$($AWK -v c="$curr_raw" 'BEGIN { ac = (c < 0 ? -c : c); if (ac > 10000) printf "%.0f", c / 1000; else printf "%.0f", c }')"
}

# Hardware switch writers
hw_pause_charging() {
    case "$SWITCH_MODE" in
        charging_enabled|battery_charging_enabled)
            # Prefer true Idle / Power-Bypass mode: input_suspend=0 + charging_enabled=0
            [ -n "$SUSPEND_NODE" ] && printf '0' > "$SUSPEND_NODE" 2>/dev/null || true
            printf '0' > "$SWITCH_NODE" 2>/dev/null || true
            ;;
        input_suspend)
            printf '1' > "$SWITCH_NODE" 2>/dev/null || true
            ;;
    esac
}

hw_enable_charging() {
    case "$SWITCH_MODE" in
        charging_enabled|battery_charging_enabled)
            [ -n "$SUSPEND_NODE" ] && printf '0' > "$SUSPEND_NODE" 2>/dev/null || true
            printf '1' > "$SWITCH_NODE" 2>/dev/null || true
            ;;
        input_suspend)
            printf '0' > "$SWITCH_NODE" 2>/dev/null || true
            ;;
    esac
}

hw_apply_current_limit() {
    limit_ma="$1"
    [ -z "$CURRENT_NODE" ] && return 0

    if [ "$limit_ma" -gt 0 ] 2>/dev/null; then
        ua=$((limit_ma * 1000))
        printf '%s' "$ua" > "$CURRENT_NODE" 2>/dev/null || true
        [ -n "$CURRENT_NODE_MAIN" ] && printf '%s' "$ua" > "$CURRENT_NODE_MAIN" 2>/dev/null || true
    else
        # Restore stock current limit
        if [ -s "$ORIG_CURR_FILE" ]; then
            orig="$(cat "$ORIG_CURR_FILE" 2>/dev/null | $TR -cd '0-9')"
            if [ -n "$orig" ]; then
                printf '%s' "$orig" > "$CURRENT_NODE" 2>/dev/null || true
                [ -n "$CURRENT_NODE_MAIN" ] && printf '%s' "$orig" > "$CURRENT_NODE_MAIN" 2>/dev/null || true
            fi
        fi
    fi
}

is_hw_paused() {
    case "$SWITCH_MODE" in
        charging_enabled|battery_charging_enabled)
            val="$(cat "$SWITCH_NODE" 2>/dev/null | $TR -cd '0-9')"
            [ "$val" = "0" ] && return 0
            ;;
        input_suspend)
            val="$(cat "$SWITCH_NODE" 2>/dev/null | $TR -cd '0-9')"
            [ "$val" = "1" ] && return 0
            ;;
    esac
    return 1
}

enforce_policy() {
    detect_nodes
    load_battery_config
    read_telemetry

    cur_mode="normal"
    if [ -f "$MAIN_CFG" ]; then
        . "$MAIN_CFG" 2>/dev/null
        [ -n "$MODE" ] && cur_mode="$MODE"
    fi

    prev_state="charging"
    [ -r "$STATE_FILE" ] && prev_state="$(cat "$STATE_FILE" 2>/dev/null | $TR -d '\r\n')"

    # Inactive if disabled OR (tethering_only and not in tethering mode)
    if [ "$B_ENABLED" != "1" ] || { [ "$B_TETH_ONLY" = "1" ] && [ "$cur_mode" != "tethering" ]; }; then
        if [ "$prev_state" != "charging" ] || is_hw_paused; then
            hw_enable_charging
        fi
        hw_apply_current_limit 0
        printf 'charging\n' > "$STATE_FILE"
        return 0
    fi

    # Apply requested charging current cap
    hw_apply_current_limit "$B_CURR_MA"

    # Evaluate thermal cutoff & charge threshold hysteresis using awk for float temp
    next_state="$($AWK -v cap="$BAT_CAP" -v temp="$BAT_TEMP_C" \
        -v stop="$B_STOP" -v res="$B_RESUME" -v maxt="$B_MAX_TEMP" -v prev="$prev_state" '
    BEGIN {
        # 1. Thermal Guard takes absolute priority
        if (temp >= maxt) {
            print "paused_thermal"
            exit
        }
        if (prev == "paused_thermal") {
            if (temp > (maxt - 3.0)) {
                print "paused_thermal"
                exit
            }
            # Cooled down below max_temp - 3C; check capacity
            if (cap >= stop) { print "paused_limit"; exit }
            print "charging"
            exit
        }
        # 2. Capacity threshold hysteresis
        if (cap >= stop) {
            print "paused_limit"
            exit
        }
        if (prev == "paused_limit") {
            if (cap <= res) { print "charging"; exit }
            print "paused_limit"
            exit
        }
        print "charging"
    }')"

    case "$next_state" in
        paused_thermal|paused_limit)
            hw_pause_charging
            if [ "$next_state" != "$prev_state" ]; then
                log_msg "Charging paused ($next_state): cap=${BAT_CAP}%, temp=${BAT_TEMP_C}C"
            fi
            ;;
        *)
            hw_enable_charging
            if [ "$next_state" != "$prev_state" ]; then
                log_msg "Charging resumed: cap=${BAT_CAP}%, temp=${BAT_TEMP_C}C"
            fi
            ;;
    esac

    printf '%s\n' "$next_state" > "$STATE_FILE"
}

save_config() {
    # Args: enabled(0|1) stop resume max_temp current_limit_ma tethering_only(0|1)
    load_battery_config

    in_en="$1"; in_stop="$2"; in_res="$3"; in_temp="$4"; in_curr="$5"; in_teth="$6"

    if [ -n "$in_en" ]; then
        case "$in_en" in 1|true|yes|on) B_ENABLED=1 ;; *) B_ENABLED=0 ;; esac
    fi
    if [ -n "$in_teth" ]; then
        case "$in_teth" in 1|true|yes|on) B_TETH_ONLY=1 ;; *) B_TETH_ONLY=0 ;; esac
    fi
    if [ -n "$in_stop" ]; then
        case "$in_stop" in ''|*[!0-9]*) ;; *) B_STOP="$in_stop" ;; esac
    fi
    if [ -n "$in_res" ]; then
        case "$in_res" in ''|*[!0-9]*) ;; *) B_RESUME="$in_res" ;; esac
    fi
    if [ -n "$in_temp" ]; then
        B_MAX_TEMP="$($AWK -v t="$in_temp" 'BEGIN { v = t + 0; if (v < 35) v = 35; if (v > 50) v = 50; printf "%.1f", v }')"
    fi
    if [ -n "$in_curr" ]; then
        case "$in_curr" in ''|*[!0-9]*) ;; *) B_CURR_MA="$in_curr" ;; esac
    fi

    # Clamp & validate thresholds (resume < stop)
    [ "$B_STOP" -lt 50 ] && B_STOP=50
    [ "$B_STOP" -gt 100 ] && B_STOP=100
    [ "$B_RESUME" -lt 30 ] && B_RESUME=30
    [ "$B_RESUME" -gt 95 ] && B_RESUME=95
    if [ "$B_RESUME" -ge "$B_STOP" ]; then
        B_RESUME=$((B_STOP - 5))
        [ "$B_RESUME" -lt 30 ] && B_RESUME=30
    fi

    en_b="false"; [ "$B_ENABLED" = "1" ] && en_b="true"
    teth_b="false"; [ "$B_TETH_ONLY" = "1" ] && teth_b="true"

    tmp="$CFG_DIR/.battery.json.tmp.$$"
    printf '{"enabled":%s,"stop_threshold":%s,"resume_threshold":%s,"max_temp":%s,"current_limit_ma":%s,"tethering_only":%s}\n' \
        "$en_b" "$B_STOP" "$B_RESUME" "$B_MAX_TEMP" "$B_CURR_MA" "$teth_b" > "$tmp" && mv "$tmp" "$BATTERY_JSON"
    chmod 0644 "$BATTERY_JSON" 2>/dev/null || true

    enforce_policy
    get_status_json
}

restore_defaults() {
    detect_nodes
    hw_enable_charging
    hw_apply_current_limit 0
    printf 'charging\n' > "$STATE_FILE"
}

get_status_json() {
    detect_nodes
    load_battery_config
    read_telemetry

    cur_mode="normal"
    if [ -f "$MAIN_CFG" ]; then
        . "$MAIN_CFG" 2>/dev/null
        [ -n "$MODE" ] && cur_mode="$MODE"
    fi

    policy_active="false"
    if [ "$B_ENABLED" = "1" ]; then
        if [ "$B_TETH_ONLY" != "1" ] || [ "$cur_mode" = "tethering" ]; then
            policy_active="true"
        fi
    fi

    st_file="charging"
    [ -r "$STATE_FILE" ] && st_file="$(cat "$STATE_FILE" 2>/dev/null | $TR -d '\r\n')"

    paused="false"
    pause_reason=""
    display_status="$BAT_STATUS_RAW"
    if is_hw_paused; then
        paused="true"
        if [ "$st_file" = "paused_thermal" ]; then
            pause_reason="thermal"
            display_status="Thermal Guard"
        else
            pause_reason="limit"
            if [ "$IDLE_BYPASS" = "true" ]; then
                display_status="Idle / Bypass"
            else
                display_status="Paused"
            fi
        fi
    fi

    en_b="false"; [ "$B_ENABLED" = "1" ] && en_b="true"
    teth_b="false"; [ "$B_TETH_ONLY" = "1" ] && teth_b="true"
    sw_sup="false"; [ -n "$SWITCH_NODE" ] && sw_sup="true"
    curr_sup="false"; [ -n "$CURRENT_NODE" ] && curr_sup="true"

    printf '{"ok":true,"capacity":%s,"status":"%s","raw_status":"%s","temp_c":%s,"voltage_mv":%s,"current_ma":%s,"charging_paused":%s,"pause_reason":"%s","policy_active":%s,"supported_nodes":{"switch_supported":%s,"switch_node":"%s","switch_mode":"%s","idle_bypass":%s,"current_supported":%s,"current_node":"%s"},"enabled":%s,"stop_threshold":%s,"resume_threshold":%s,"max_temp":%s,"current_limit_ma":%s,"tethering_only":%s}\n' \
        "$BAT_CAP" "$display_status" "$BAT_STATUS_RAW" "$BAT_TEMP_C" "$BAT_VOLT_MV" "$BAT_CURR_MA" \
        "$paused" "$pause_reason" "$policy_active" \
        "$sw_sup" "$SWITCH_NODE" "$SWITCH_MODE" "$IDLE_BYPASS" "$curr_sup" "$CURRENT_NODE" \
        "$en_b" "$B_STOP" "$B_RESUME" "$B_MAX_TEMP" "$B_CURR_MA" "$teth_b"
}

CMD="$1"
if [ -z "$CMD" ] && [ -n "$REQUEST_METHOD" ]; then
    printf 'Content-Type: application/json\r\nCache-Control: no-store\r\n\r\n'
    get_status_json
    exit 0
fi

case "$CMD" in
    status|"") get_status_json ;;
    enforce)   enforce_policy ;;
    save)      save_config "$2" "$3" "$4" "$5" "$6" "$7" ;;
    restore)   restore_defaults ;;
    *)         printf '{"ok":false,"error":"Unknown battery command"}\n'; exit 1 ;;
esac
