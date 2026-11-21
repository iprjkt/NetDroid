#!/system/bin/sh
# NetDroid - Main JSON API Router (BusyBox httpd CGI + KernelSU Native Adapter)

export PATH="/data/adb/ksu/bin:/data/adb/ap/bin:/data/adb/magisk:/system/bin:/system/xbin:/vendor/bin:$PATH"

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
MOD_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)"
DATA_DIR="/data/adb/netdroid"
CONFIG_FILE="$DATA_DIR/config.env"
TOKENS_FILE="$DATA_DIR/auth_tokens.db"
THEME_FILE="$DATA_DIR/theme.json"
META_FILE="$DATA_DIR/custom_bg.meta"

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
PORT=8765
MODE="normal"
TTL=65
MANGLE_TTL=1
TTL_STANDALONE=0
AUTO_SYNC_DISABLE=1
BPF_OFFLOAD_DISABLE=0
AUTH_ENABLED=1
PIN_HASH="03ac674216f3e15c761ee1a5e255f067953623c8b388b4459e13f978d7c846f4"
PIN_IS_DEFAULT=1
QUOTA_DAILY_MB=2048
QUOTA_MONTHLY_MB=30720
QUOTA_WARN_PCT=80
QUOTA_CRIT_PCT=90

mkdir -p "$DATA_DIR" 2>/dev/null
if [ -f "$CONFIG_FILE" ]; then
    . "$CONFIG_FILE" 2>/dev/null
fi

# Read POST body once (bounded to 64KB for JSON/form API payloads)
POST_BODY=""
if [ "$REQUEST_METHOD" = "POST" ]; then
    if [ -n "$CONTENT_LENGTH" ] && [ "$CONTENT_LENGTH" -gt 0 ] 2>/dev/null; then
        len="$CONTENT_LENGTH"
        [ "$len" -gt 65536 ] && len=65536
        POST_BODY="$($BB head -c "$len" 2>/dev/null)"
    fi
fi

# URL decode using busybox httpd -d
urldecode() {
    if [ -n "$BB" ]; then
        "$BB" httpd -d "$1" 2>/dev/null
    else
        printf '%s' "$1"
    fi
}

# Extract parameter from QUERY_STRING or form-encoded/JSON POST_BODY
param_get() {
    key="$1"
    # 1. Check QUERY_STRING first
    val="$(printf '%s' "$QUERY_STRING" | $AWK -v k="$key" '
    BEGIN { RS="&" }
    {
        idx = index($0, "=")
        if (idx > 0 && substr($0, 1, idx - 1) == k) {
            print substr($0, idx + 1)
            exit
        }
    }')"
    if [ -n "$val" ]; then
        urldecode "$val"
        return 0
    fi

    [ -z "$POST_BODY" ] && return 0

    # 2. If POST_BODY starts with '{', parse flat JSON key
    case "$POST_BODY" in
        \{*)
            printf '%s' "$POST_BODY" | $AWK -v k="$key" '
            {
                s = s $0
            }
            END {
                # Match string value: "key":"value"
                r1 = "\"" k "\"[[:space:]]*:[[:space:]]*\"([^\"]*)\""
                if (match(s, r1)) {
                    m = substr(s, RSTART, RLENGTH)
                    sub(/^[^:]+:[[:space:]]*"/, "", m)
                    sub(/"$/, "", m)
                    print m
                    exit
                }
                # Match number/bool value: "key":123 or true/false
                r2 = "\"" k "\"[[:space:]]*:[[:space:]]*([0-9.-]+|true|false)"
                if (match(s, r2)) {
                    m = substr(s, RSTART, RLENGTH)
                    sub(/^[^:]+:[[:space:]]*/, "", m)
                    print m
                    exit
                }
            }'
            ;;
        *)
            val="$(printf '%s' "$POST_BODY" | $AWK -v k="$key" '
            BEGIN { RS="&" }
            {
                idx = index($0, "=")
                if (idx > 0 && substr($0, 1, idx - 1) == k) {
                    print substr($0, idx + 1)
                    exit
                }
            }')"
            [ -n "$val" ] && urldecode "$val"
            ;;
    esac
}

send_headers() {
    status="${1:-200 OK}"
    if [ -n "$REQUEST_METHOD" ] && [ -z "$NETDROID_CLI_RAW" ]; then
        printf 'Status: %s\r\n' "$status"
        printf 'Content-Type: application/json; charset=utf-8\r\n'
        printf 'Cache-Control: no-store, no-cache\r\n'
        printf 'Access-Control-Allow-Origin: *\r\n'
        printf 'Access-Control-Allow-Headers: Content-Type, X-NetDroid-Token\r\n'
        printf 'Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n\r\n'
    fi
}

# Handle CORS preflight
if [ "$REQUEST_METHOD" = "OPTIONS" ]; then
    send_headers "204 No Content"
    exit 0
fi

is_local_client() {
    case "$REMOTE_ADDR" in
        ""|"127.0.0.1"|"::1"|"::ffff:127.0.0.1") return 0 ;;
        *) return 1 ;;
    esac
}

sha256_str() {
    printf '%s' "$1" | $BB sha256sum | $AWK '{print $1}'
}

gen_token() {
    $BB head -c 24 /dev/urandom 2>/dev/null | $BB od -An -tx1 2>/dev/null | $TR -d ' \r\n'
}

get_client_token() {
    if [ -n "$HTTP_X_NETDROID_TOKEN" ]; then
        printf '%s' "$HTTP_X_NETDROID_TOKEN"
    else
        param_get token
    fi
}

is_authenticated() {
    if is_local_client || [ "$AUTH_ENABLED" != "1" ]; then
        return 0
    fi
    tok="$(get_client_token)"
    [ -z "$tok" ] && return 1
    [ ! -f "$TOKENS_FILE" ] && return 1

    now="$(date +%s 2>/dev/null || echo 0)"
    ok="$($AWK -F'|' -v t="$tok" -v now="$now" '$1 == t && ($2 + 0) > now { print "1"; exit }' "$TOKENS_FILE" 2>/dev/null)"
    [ "$ok" = "1" ]
}

save_config_key() {
    k="$1"
    v="$2"
    [ -f "$CONFIG_FILE" ] || : > "$CONFIG_FILE"
    tmp="$DATA_DIR/.config.env.tmp.$$"
    $GREP -v "^${k}=" "$CONFIG_FILE" > "$tmp" 2>/dev/null || true
    printf '%s=%s\n' "$k" "$v" >> "$tmp"
    mv "$tmp" "$CONFIG_FILE"
    chmod 0600 "$CONFIG_FILE" 2>/dev/null || true
}

is_uint() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

bool_to_01() {
    case "$1" in
        1|true|yes|on) echo 1 ;;
        *) echo 0 ;;
    esac
}

ACTION="$(param_get action)"
if [ -z "$ACTION" ] && [ -n "$PATH_INFO" ]; then
    case "$PATH_INFO" in
        /api/battery|/battery) ACTION="battery" ;;
        /api/dns/update-lists|/dns/update-lists) ACTION="dns_update_lists" ;;
        /api/dns|/dns) ACTION="dns" ;;
    esac
fi
[ -z "$ACTION" ] && ACTION="$1"
[ -z "$ACTION" ] && ACTION="dashboard"

# ==============================================================================
# Public endpoints (no auth token required)
# ==============================================================================
case "$ACTION" in
    auth_status)
        send_headers "200 OK"
        local_flag="false"; is_local_client && local_flag="true"
        auth_flag="false"; is_authenticated && auth_flag="true"
        req_flag="false"
        if [ "$local_flag" = "false" ] && [ "$AUTH_ENABLED" = "1" ]; then
            req_flag="true"
        fi
        def_pin="false"; [ "$PIN_IS_DEFAULT" = "1" ] && def_pin="true"
        dev_code="$(getprop ro.product.device 2>/dev/null | $TR -d '\r\n')"
        dev_model="$(getprop ro.product.model 2>/dev/null | $TR -d '\r\n')"
        printf '{"ok":true,"authenticated":%s,"is_local":%s,"auth_required":%s,"default_pin":%s,"remote_addr":"%s","device":"%s","model":"%s"}\n' \
            "$auth_flag" "$local_flag" "$req_flag" "$def_pin" "$REMOTE_ADDR" "$dev_code" "$dev_model"
        exit 0
        ;;

    login)
        send_headers "200 OK"
        pin="$(param_get pin)"
        if [ -z "$pin" ]; then
            printf '{"ok":false,"error":"PIN is required"}\n'
            exit 0
        fi
        h="$(sha256_str "$pin")"
        if [ "$h" != "$PIN_HASH" ]; then
            printf '{"ok":false,"error":"Incorrect PIN"}\n'
            exit 0
        fi
        tok="$(gen_token)"
        now="$(date +%s 2>/dev/null || echo 0)"
        exp=$((now + 86400))
        # Prune expired tokens & store new one
        tmp_tok="$DATA_DIR/.tokens.tmp.$$"
        if [ -f "$TOKENS_FILE" ]; then
            $AWK -F'|' -v now="$now" '($2 + 0) > now { print }' "$TOKENS_FILE" > "$tmp_tok" 2>/dev/null || true
        fi
        printf '%s|%s|%s\n' "$tok" "$exp" "${REMOTE_ADDR:-local}" >> "$tmp_tok"
        mv "$tmp_tok" "$TOKENS_FILE"
        chmod 0600 "$TOKENS_FILE" 2>/dev/null || true
        printf '{"ok":true,"token":"%s","expires_at":%s}\n' "$tok" "$exp"
        exit 0
        ;;

    logout)
        send_headers "200 OK"
        tok="$(get_client_token)"
        if [ -n "$tok" ] && [ -f "$TOKENS_FILE" ]; then
            tmp_tok="$DATA_DIR/.tokens.tmp.$$"
            $GREP -v "^${tok}|" "$TOKENS_FILE" > "$tmp_tok" 2>/dev/null || true
            mv "$tmp_tok" "$TOKENS_FILE"
            chmod 0600 "$TOKENS_FILE" 2>/dev/null || true
        fi
        printf '{"ok":true}\n'
        exit 0
        ;;

    get_theme)
        send_headers "200 OK"
        theme_json='{"mode":"dark","preset":"aurora","useCustomBg":false,"autoExtract":true,"accent":"#A8C7FA","blur":12,"dim":42,"cardOpacity":76}'
        [ -s "$THEME_FILE" ] && theme_json="$(cat "$THEME_FILE" | $TR -d '\r\n')"
        bg_exists="false"; bg_updated=0; bg_ext=""
        for ext in webp jpg jpeg png; do
            if [ -s "$DATA_DIR/custom_bg.$ext" ]; then
                bg_exists="true"
                bg_ext="$ext"
                bg_updated="$($BB stat -c %Y "$DATA_DIR/custom_bg.$ext" 2>/dev/null || echo 0)"
                break
            fi
        done
        printf '{"ok":true,"theme":%s,"custom_bg":{"exists":%s,"ext":"%s","updated_at":%s}}\n' \
            "$theme_json" "$bg_exists" "$bg_ext" "$bg_updated"
        exit 0
        ;;
esac

# ==============================================================================
# Enforce authentication for all protected endpoints
# ==============================================================================
if ! is_authenticated; then
    send_headers "401 Unauthorized"
    printf '{"ok":false,"error":"Authentication required","auth_required":true}\n'
    exit 0
fi

# ==============================================================================
# Protected endpoints
# ==============================================================================
case "$ACTION" in
    dashboard)
        send_headers "200 OK"
        sh "$SCRIPT_DIR/monitor.sh" dashboard
        ;;

    clients)
        send_headers "200 OK"
        refresh="$(param_get refresh)"
        sh "$SCRIPT_DIR/monitor.sh" clients "$refresh"
        ;;

    reset_quota)
        send_headers "200 OK"
        scope="$(param_get scope)"
        case "$scope" in
            session|daily|monthly|all) ;;
            *) scope="session" ;;
        esac
        sh "$SCRIPT_DIR/monitor.sh" reset_quota "$scope"
        ;;

    mode_status)
        send_headers "200 OK"
        sh "$SCRIPT_DIR/mode.sh" status
        ;;

    set_mode)
        send_headers "200 OK"
        target_mode="$(param_get mode)"
        case "$target_mode" in
            tethering) sh "$SCRIPT_DIR/mode.sh" tethering async ;;
            normal)    sh "$SCRIPT_DIR/mode.sh" normal ;;
            *)         printf '{"ok":false,"error":"Invalid mode (use normal or tethering)"}\n' ;;
        esac
        ;;

    set_ttl)
        send_headers "200 OK"
        ttl_val="$(param_get ttl)"
        mangle_val="$(param_get mangle)"
        standalone_val="$(param_get standalone)"
        [ -n "$mangle_val" ] && mangle_val="$(bool_to_01 "$mangle_val")"
        [ -n "$standalone_val" ] && standalone_val="$(bool_to_01 "$standalone_val")"
        sh "$SCRIPT_DIR/mode.sh" set_ttl "$ttl_val" "$mangle_val" "$standalone_val"
        ;;

    apps)
        send_headers "200 OK"
        refresh="$(param_get refresh)"
        sh "$SCRIPT_DIR/firewall.sh" list_apps "$refresh"
        ;;

    firewall_status)
        send_headers "200 OK"
        sh "$SCRIPT_DIR/firewall.sh" status
        ;;

    set_app_rule)
        send_headers "200 OK"
        uid="$(param_get uid)"
        pkg="$(param_get package)"
        wifi="$(bool_to_01 "$(param_get wifi)")"
        mobile="$(bool_to_01 "$(param_get mobile)")"
        sh "$SCRIPT_DIR/firewall.sh" set_app "$uid" "$pkg" "$wifi" "$mobile"
        ;;

    set_client_rule)
        send_headers "200 OK"
        mac="$(param_get mac)"
        ip="$(param_get ip)"
        host="$(param_get hostname)"
        blocked="$(bool_to_01 "$(param_get blocked)")"
        sh "$SCRIPT_DIR/firewall.sh" set_client "$mac" "$ip" "$host" "$blocked"
        ;;

    clear_firewall)
        send_headers "200 OK"
        sh "$SCRIPT_DIR/firewall.sh" clear_all
        ;;

    settings)
        send_headers "200 OK"
        mode_json="$(sh "$SCRIPT_DIR/mode.sh" status)"
        boundary_ok="false"
        iptables -w 2 -C INPUT -j NETDROID_IN 2>/dev/null && boundary_ok="true"
        printf '{"ok":true,"port":%s,"auth_enabled":%s,"pin_is_default":%s,"security_boundary":%s,"quota_daily_mb":%s,"quota_monthly_mb":%s,"quota_warn_pct":%s,"quota_crit_pct":%s,"mode_info":%s}\n' \
            "$PORT" \
            "$([ "$AUTH_ENABLED" = "1" ] && echo true || echo false)" \
            "$([ "$PIN_IS_DEFAULT" = "1" ] && echo true || echo false)" \
            "$boundary_ok" \
            "$QUOTA_DAILY_MB" "$QUOTA_MONTHLY_MB" "$QUOTA_WARN_PCT" "$QUOTA_CRIT_PCT" \
            "$mode_json"
        ;;

    save_settings)
        send_headers "200 OK"
        port_changed=0

        new_port="$(param_get port)"
        if [ -n "$new_port" ]; then
            if is_uint "$new_port" && [ "$new_port" -ge 1024 ] && [ "$new_port" -le 65535 ]; then
                if [ "$new_port" != "$PORT" ]; then
                    save_config_key PORT "$new_port"
                    PORT="$new_port"
                    port_changed=1
                fi
            else
                printf '{"ok":false,"error":"Port must be between 1024 and 65535"}\n'
                exit 0
            fi
        fi

        d_mb="$(param_get quota_daily_mb)"
        if [ -n "$d_mb" ] && is_uint "$d_mb" && [ "$d_mb" -ge 10 ]; then
            save_config_key QUOTA_DAILY_MB "$d_mb"
        fi

        m_mb="$(param_get quota_monthly_mb)"
        if [ -n "$m_mb" ] && is_uint "$m_mb" && [ "$m_mb" -ge 10 ]; then
            save_config_key QUOTA_MONTHLY_MB "$m_mb"
        fi

        w_pct="$(param_get quota_warn_pct)"
        if [ -n "$w_pct" ] && is_uint "$w_pct" && [ "$w_pct" -ge 10 ] && [ "$w_pct" -le 99 ]; then
            save_config_key QUOTA_WARN_PCT "$w_pct"
        fi

        c_pct="$(param_get quota_crit_pct)"
        if [ -n "$c_pct" ] && is_uint "$c_pct" && [ "$c_pct" -ge 10 ] && [ "$c_pct" -le 100 ]; then
            save_config_key QUOTA_CRIT_PCT "$c_pct"
        fi

        as_dis="$(param_get auto_sync_disable)"
        if [ -n "$as_dis" ]; then
            save_config_key AUTO_SYNC_DISABLE "$(bool_to_01 "$as_dis")"
        fi

        bpf_dis="$(param_get bpf_offload_disable)"
        if [ -n "$bpf_dis" ]; then
            v="$(bool_to_01 "$bpf_dis")"
            save_config_key BPF_OFFLOAD_DISABLE "$v"
            settings put global tether_offload_disabled "$v" >/dev/null 2>&1 || true
        fi

        auth_en="$(param_get auth_enabled)"
        if [ -n "$auth_en" ]; then
            save_config_key AUTH_ENABLED "$(bool_to_01 "$auth_en")"
        fi

        if [ "$port_changed" = "1" ]; then
            sh "$SCRIPT_DIR/firewall.sh" apply_boundary >/dev/null 2>&1
            # Restart httpd asynchronously after response flushes
            ( sleep 1; sh "$MOD_DIR/service.sh" restart_httpd ) >/dev/null 2>&1 &
        fi

        printf '{"ok":true,"port":%s,"port_changed":%s}\n' "$PORT" "$([ "$port_changed" = "1" ] && echo true || echo false)"
        ;;

    change_pin)
        send_headers "200 OK"
        cur_pin="$(param_get current_pin)"
        new_pin="$(param_get new_pin)"
        if ! is_uint "$new_pin" || [ "${#new_pin}" -lt 4 ] || [ "${#new_pin}" -gt 12 ]; then
            printf '{"ok":false,"error":"PIN must be 4 to 12 digits"}\n'
            exit 0
        fi
        if ! is_local_client; then
            if [ "$(sha256_str "$cur_pin")" != "$PIN_HASH" ]; then
                printf '{"ok":false,"error":"Current PIN is incorrect"}\n'
                exit 0
            fi
        fi
        new_hash="$(sha256_str "$new_pin")"
        save_config_key PIN_HASH "$new_hash"
        save_config_key PIN_IS_DEFAULT 0
        # Keep only current token if LAN client changed PIN
        cur_tok="$(get_client_token)"
        if [ -n "$cur_tok" ] && [ -f "$TOKENS_FILE" ]; then
            tmp_tok="$DATA_DIR/.tokens.tmp.$$"
            $GREP "^${cur_tok}|" "$TOKENS_FILE" > "$tmp_tok" 2>/dev/null || true
            mv "$tmp_tok" "$TOKENS_FILE"
        else
            : > "$TOKENS_FILE"
        fi
        chmod 0600 "$TOKENS_FILE" 2>/dev/null || true
        printf '{"ok":true,"message":"PIN updated successfully"}\n'
        ;;

    save_theme)
        send_headers "200 OK"
        t_mode="$(param_get mode)"
        t_preset="$(param_get preset)"
        t_custom="$(param_get useCustomBg)"
        t_auto="$(param_get autoExtract)"
        t_accent="$(param_get accent)"
        t_blur="$(param_get blur)"
        t_dim="$(param_get dim)"
        t_opacity="$(param_get cardOpacity)"

        case "$t_mode" in dark|light) ;; *) t_mode="dark" ;; esac
        t_preset="$(printf '%s' "$t_preset" | $TR -cd 'a-z0-9_-')"
        [ -z "$t_preset" ] && t_preset="aurora"
        case "$t_custom" in true|1) t_custom="true" ;; *) t_custom="false" ;; esac
        case "$t_auto" in false|0) t_auto="false" ;; *) t_auto="true" ;; esac
        t_accent="$(printf '%s' "$t_accent" | $TR -cd '#0-9a-fA-F')"
        [ -z "$t_accent" ] && t_accent="#A8C7FA"
        is_uint "$t_blur" || t_blur=12
        [ "$t_blur" -gt 24 ] && t_blur=24
        is_uint "$t_dim" || t_dim=42
        [ "$t_dim" -lt 10 ] && t_dim=10; [ "$t_dim" -gt 85 ] && t_dim=85
        is_uint "$t_opacity" || t_opacity=76
        [ "$t_opacity" -lt 40 ] && t_opacity=40; [ "$t_opacity" -gt 95 ] && t_opacity=95

        printf '{"mode":"%s","preset":"%s","useCustomBg":%s,"autoExtract":%s,"accent":"%s","blur":%s,"dim":%s,"cardOpacity":%s}\n' \
            "$t_mode" "$t_preset" "$t_custom" "$t_auto" "$t_accent" "$t_blur" "$t_dim" "$t_opacity" > "$THEME_FILE.tmp.$$" && \
            mv "$THEME_FILE.tmp.$$" "$THEME_FILE"
        chmod 0644 "$THEME_FILE" 2>/dev/null || true
        printf '{"ok":true}\n'
        ;;

    restart_server)
        send_headers "200 OK"
        ( sleep 1; sh "$MOD_DIR/service.sh" restart_httpd ) >/dev/null 2>&1 &
        printf '{"ok":true,"message":"HTTP server restarting on port %s"}\n' "$PORT"
        ;;

    battery)
        send_headers "200 OK"
        if [ "$REQUEST_METHOD" = "POST" ]; then
            b_en="$(param_get enabled)"
            b_stop="$(param_get stop_threshold)"
            b_res="$(param_get resume_threshold)"
            b_temp="$(param_get max_temp)"
            b_curr="$(param_get current_limit_ma)"
            b_teth="$(param_get tethering_only)"
            sh "$SCRIPT_DIR/battery.sh" save "$b_en" "$b_stop" "$b_res" "$b_temp" "$b_curr" "$b_teth"
        else
            sh "$SCRIPT_DIR/battery.sh" status
        fi
        ;;

    dns)
        send_headers "200 OK"
        if [ "$REQUEST_METHOD" = "POST" ]; then
            d_ad="$(param_get adblock_enabled)"
            [ -z "$d_ad" ] && d_ad="$(param_get enabled)"
            d_fr="$(param_get force_router_dns)"
            d_pre="$(param_get preset)"
            # Detect whether custom_ipv4 / custom_ipv6 were explicitly sent
            d_c4="__UNCHANGED__"
            d_c6="__UNCHANGED__"
            case "&${QUERY_STRING}&${POST_BODY}&" in
                *"custom_ipv4="*|*"\"custom_ipv4\""*) d_c4="$(param_get custom_ipv4)" ;;
            esac
            case "&${QUERY_STRING}&${POST_BODY}&" in
                *"custom_ipv6="*|*"\"custom_ipv6\""*) d_c6="$(param_get custom_ipv6)" ;;
            esac
            d_add_wl="$(param_get add_whitelist)"
            d_del_wl="$(param_get remove_whitelist)"
            d_add_bl="$(param_get add_blacklist)"
            d_del_bl="$(param_get remove_blacklist)"
            sh "$SCRIPT_DIR/dns.sh" save "$d_ad" "$d_fr" "$d_pre" "$d_c4" "$d_c6" "$d_add_wl" "$d_del_wl" "$d_add_bl" "$d_del_bl"
        else
            sh "$SCRIPT_DIR/dns.sh" status
        fi
        ;;

    dns_update_lists)
        send_headers "200 OK"
        if [ "$(param_get async)" = "1" ]; then
            sh "$SCRIPT_DIR/dns.sh" update_lists_bg
        else
            sh "$SCRIPT_DIR/dns.sh" update_lists
        fi
        ;;

    *)
        send_headers "400 Bad Request"
        printf '{"ok":false,"error":"Unknown API action"}\n'
        ;;
esac
