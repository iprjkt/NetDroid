#!/system/bin/sh
# NetDroid - SSH Server Manager (Dropbear bundled/auto-detected + OpenSSH fallback)
# Manages LAN-only SSH daemon, authorized_keys, NetDroid PIN password auth,
# host key generation, and active SSH session monitoring.

export PATH="/data/adb/ksu/bin:/data/adb/ap/bin:/data/adb/magisk:/system/bin:/system/xbin:/product/bin:/vendor/bin:$PATH"

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
MOD_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)"
DATA_DIR="/data/adb/netdroid"
CFG_DIR="$DATA_DIR/config"
SSH_DIR="$DATA_DIR/ssh"
SSH_JSON="$CFG_DIR/ssh.json"
AUTH_KEYS="$CFG_DIR/authorized_keys"
DOT_SSH="$DATA_DIR/.ssh"
SSH_PID="$SSH_DIR/ssh.pid"
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

mkdir -p "$CFG_DIR" "$SSH_DIR" "$DOT_SSH" 2>/dev/null
chmod 0755 "$DATA_DIR" "$CFG_DIR" 2>/dev/null || true
chmod 0700 "$SSH_DIR" "$DOT_SSH" 2>/dev/null || true

# Ensure module config symlink exists
if [ -d "$MOD_DIR" ] && [ ! -e "$MOD_DIR/config" ]; then
    ln -s "$CFG_DIR" "$MOD_DIR/config" 2>/dev/null || true
fi

log_msg() {
    ts="$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo '0')"
    printf '[%s] [ssh] %s\n' "$ts" "$1" >> "$LOG_FILE" 2>/dev/null || true
}

ensure_default_config() {
    if [ ! -s "$SSH_JSON" ]; then
        printf '{"enabled":false,"port":2222,"password_auth":true}\n' > "$SSH_JSON"
        chmod 0644 "$SSH_JSON" 2>/dev/null || true
    fi
    if [ ! -f "$AUTH_KEYS" ]; then
        : > "$AUTH_KEYS"
    fi
    sync_authorized_keys_perms
}

# Keep /data/adb/netdroid/.ssh/authorized_keys strictly synced with config/authorized_keys (0600, root:root)
sync_authorized_keys_perms() {
    chmod 0700 "$DOT_SSH" 2>/dev/null || true
    chmod 0600 "$AUTH_KEYS" 2>/dev/null || true
    cp "$AUTH_KEYS" "$DOT_SSH/authorized_keys" 2>/dev/null || true
    chmod 0600 "$DOT_SSH/authorized_keys" 2>/dev/null || true
    chown 0:0 "$DOT_SSH" "$DOT_SSH/authorized_keys" "$AUTH_KEYS" 2>/dev/null || true
}

load_ssh_config() {
    ensure_default_config
    eval "$($AWK '
    function gb(s, k, def,   m, r) {
        r = "\"" k "\"[[:space:]]*:[[:space:]]*(true|false)"
        if (match(s, r)) { m = substr(s, RSTART, RLENGTH); return (m ~ /true/) ? 1 : 0 }
        return def
    }
    function gn(s, k, def,   m, r) {
        r = "\"" k "\"[[:space:]]*:[[:space:]]*[0-9]+"
        if (match(s, r)) { m = substr(s, RSTART, RLENGTH); sub(/^[^:]+:[[:space:]]*/, "", m); return m + 0 }
        return def
    }
    { line = line $0 }
    END {
        printf "S_ENABLED=%d\n", gb(line, "enabled", 0)
        printf "S_PORT=%d\n", gn(line, "port", 2222)
        printf "S_PASSWD=%d\n", gb(line, "password_auth", 1)
    }
    ' "$SSH_JSON" 2>/dev/null)"
    [ -z "$S_ENABLED" ] && S_ENABLED=0
    [ -z "$S_PORT" ] && S_PORT=2222
    [ -z "$S_PASSWD" ] && S_PASSWD=1
}

write_ssh_json() {
    en_b="false"; [ "$S_ENABLED" = "1" ] && en_b="true"
    pw_b="false"; [ "$S_PASSWD" = "1" ] && pw_b="true"
    tmp="$CFG_DIR/.ssh.json.tmp.$$"
    printf '{"enabled":%s,"port":%s,"password_auth":%s}\n' "$en_b" "$S_PORT" "$pw_b" > "$tmp" && mv "$tmp" "$SSH_JSON"
    chmod 0644 "$SSH_JSON" 2>/dev/null || true
}

# Detect SSH daemon binary (prefers bundled/installed dropbear, falls back to OpenSSH sshd)
detect_ssh_daemon() {
    SSH_DAEMON="none"
    SSH_BIN=""
    KEYGEN_BIN=""

    for db in \
        "$MOD_DIR/bin/dropbear" \
        "$MOD_DIR/bin/dropbearmulti" \
        "/data/adb/modules/netdroid/bin/dropbear" \
        "/data/adb/modules/netdroid/bin/dropbearmulti" \
        "/system/bin/dropbear" \
        "/system/xbin/dropbear" \
        "/data/data/com.termux/files/usr/bin/dropbear"; do
        if [ -x "$db" ]; then
            SSH_DAEMON="dropbear"
            SSH_BIN="$db"
            # Locate dropbearkey
            case "$db" in
                *dropbearmulti) KEYGEN_BIN="$db" ;;
                *)
                    dir="$(dirname "$db")"
                    if [ -x "$dir/dropbearkey" ]; then KEYGEN_BIN="$dir/dropbearkey"
                    elif [ -x "$dir/dropbearmulti" ]; then KEYGEN_BIN="$dir/dropbearmulti"
                    fi
                    ;;
            esac
            return 0
        fi
    done

    for sd in \
        "/product/bin/sshd" \
        "/system/product/bin/sshd" \
        "/system/bin/sshd" \
        "/data/data/com.termux/files/usr/bin/sshd"; do
        if [ -x "$sd" ]; then
            SSH_DAEMON="openssh"
            SSH_BIN="$sd"
            dir="$(dirname "$sd")"
            [ -x "$dir/ssh-keygen" ] && KEYGEN_BIN="$dir/ssh-keygen"
            return 0
        fi
    done
}

# Prepare clean shell profile for SSH sessions
prepare_ssh_profile() {
    cat <<'EOF' > "$SSH_DIR/profile"
export PATH="/data/adb/ksu/bin:/data/adb/ap/bin:/data/adb/magisk:/system/bin:/system/xbin:/product/bin:/vendor/bin:$PATH"
export HOME="/data/adb/netdroid"
export TERM="${TERM:-xterm-256color}"
EOF
    chmod 0644 "$SSH_DIR/profile" 2>/dev/null || true
}

stop_ssh() {
    if [ -f "$SSH_PID" ]; then
        pid="$(cat "$SSH_PID" 2>/dev/null)"
        [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
        rm -f "$SSH_PID"
    fi
    if [ -n "$BB" ]; then
        $BB pkill -f "dropbear.*$SSH_PID" 2>/dev/null || true
        $BB pkill -f "sshd.*$SSH_DIR/sshd_config" 2>/dev/null || true
    fi
}

start_ssh() {
    load_ssh_config
    detect_ssh_daemon
    stop_ssh

    if [ "$SSH_DAEMON" = "none" ]; then
        log_msg "ERROR: No dropbear or sshd binary found"
        return 1
    fi

    sync_authorized_keys_perms
    prepare_ssh_profile

    # Ensure LAN-only security boundary covers $S_PORT
    sh "$SCRIPT_DIR/firewall.sh" apply_boundary >/dev/null 2>&1 || true

    if [ "$SSH_DAEMON" = "dropbear" ]; then
        ed_key="$SSH_DIR/dropbear_ed25519_host_key"
        rsa_key="$SSH_DIR/dropbear_rsa_host_key"

        if [ ! -s "$ed_key" ]; then
            case "$KEYGEN_BIN" in
                *dropbearmulti) "$KEYGEN_BIN" dropbearkey -t ed25519 -f "$ed_key" >/dev/null 2>&1 || true ;;
                *) [ -n "$KEYGEN_BIN" ] && "$KEYGEN_BIN" -t ed25519 -f "$ed_key" >/dev/null 2>&1 || true ;;
            esac
            chmod 0600 "$ed_key" 2>/dev/null || true
        fi
        if [ ! -s "$rsa_key" ]; then
            case "$KEYGEN_BIN" in
                *dropbearmulti) "$KEYGEN_BIN" dropbearkey -t rsa -s 2048 -f "$rsa_key" >/dev/null 2>&1 || true ;;
                *) [ -n "$KEYGEN_BIN" ] && "$KEYGEN_BIN" -t rsa -s 2048 -f "$rsa_key" >/dev/null 2>&1 || true ;;
            esac
            chmod 0600 "$rsa_key" 2>/dev/null || true
        fi

        # Build Dropbear args: -F foreground (detached via setsid), -E stderr log, -p port, -P pidfile, -r hostkeys
        # -s disables password login when S_PASSWD=0
        pw_flag=""
        [ "$S_PASSWD" != "1" ] && pw_flag="-s"

        key_args=""
        [ -s "$ed_key" ] && key_args="$key_args -r $ed_key"
        [ -s "$rsa_key" ] && key_args="$key_args -r $rsa_key"

        db_cmd="$SSH_BIN"
        case "$SSH_BIN" in
            *dropbearmulti) db_cmd="$SSH_BIN dropbear" ;;
        esac

        if [ -n "$BB" ] && "$BB" setsid true >/dev/null 2>&1; then
            "$BB" setsid sh -c "export HOME='$DATA_DIR' ENV='$SSH_DIR/profile' TERM=xterm-256color; exec $db_cmd -F -E -p '$S_PORT' -P '$SSH_PID' $pw_flag $key_args" </dev/null >>"$LOG_FILE" 2>&1 &
        else
            sh -c "export HOME='$DATA_DIR' ENV='$SSH_DIR/profile' TERM=xterm-256color; exec $db_cmd -F -E -p '$S_PORT' -P '$SSH_PID' $pw_flag $key_args" </dev/null >>"$LOG_FILE" 2>&1 &
        fi
        pid=$!
        printf '%s\n' "$pid" > "$SSH_PID"
        log_msg "Started Dropbear SSH daemon (PID=$pid, port=$S_PORT, password_auth=$S_PASSWD)"
    else
        # OpenSSH fallback
        ed_key="$SSH_DIR/ssh_host_ed25519_key"
        if [ ! -s "$ed_key" ] && [ -n "$KEYGEN_BIN" ]; then
            "$KEYGEN_BIN" -t ed25519 -N "" -f "$ed_key" -q 2>/dev/null || true
            chmod 0600 "$ed_key" 2>/dev/null || true
        fi
        cat <<EOF > "$SSH_DIR/sshd_config"
Port $S_PORT
HostKey $ed_key
PermitRootLogin yes
StrictModes no
PubkeyAuthentication yes
AuthorizedKeysFile $AUTH_KEYS
PasswordAuthentication $([ "$S_PASSWD" = "1" ] && echo yes || echo no)
Subsystem sftp internal-sftp
PidFile $SSH_PID
EOF
        if [ -n "$BB" ] && "$BB" setsid true >/dev/null 2>&1; then
            "$BB" setsid "$SSH_BIN" -D -f "$SSH_DIR/sshd_config" </dev/null >>"$LOG_FILE" 2>&1 &
        else
            "$SSH_BIN" -D -f "$SSH_DIR/sshd_config" </dev/null >>"$LOG_FILE" 2>&1 &
        fi
        pid=$!
        printf '%s\n' "$pid" > "$SSH_PID"
        log_msg "Started OpenSSH daemon (PID=$pid, port=$S_PORT)"
    fi
}

apply_ssh() {
    load_ssh_config
    if [ "$S_ENABLED" = "1" ]; then
        start_ssh
    else
        stop_ssh
    fi
}

watchdog_check() {
    load_ssh_config
    if [ "$S_ENABLED" = "1" ]; then
        spid="$(cat "$SSH_PID" 2>/dev/null)"
        if [ -z "$spid" ] || ! kill -0 "$spid" 2>/dev/null; then
            start_ssh
        fi
    fi
}

is_running() {
    spid="$(cat "$SSH_PID" 2>/dev/null)"
    [ -n "$spid" ] && kill -0 "$spid" 2>/dev/null
}

# Parse active ESTABLISHED TCP connections to :$S_PORT
get_sessions_json() {
    if [ -z "$BB" ]; then
        printf '[]'
        return
    fi
    "$BB" netstat -tnp 2>/dev/null | $AWK -v p=":$S_PORT" '
    $6 == "ESTABLISHED" && substr($4, length($4) - length(p) + 1) == p {
        rem = $5
        sub(/:[0-9]+$/, "", rem)
        proc = $7
        split(proc, pa, "/")
        pid = pa[1]
        if (cnt > 0) printf ","
        printf "{\"remote\":\"%s\",\"pid\":\"%s\",\"state\":\"ESTABLISHED\"}", rem, pid
        cnt++
    }
    BEGIN { printf "[" }
    END { printf "]" }
    '
}

# Parse authorized_keys into JSON array
get_keys_json() {
    [ ! -s "$AUTH_KEYS" ] && { printf '[]'; return; }
    $AWK '
    function esc(s) {
        gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); gsub(/\r|\n/, "", s)
        return s
    }
    BEGIN { printf "["; first = 1; idx = 0 }
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    {
        idx++
        ktype = $1
        kbody = $2
        label = ""
        for (i = 3; i <= NF; i++) {
            if (label != "") label = label " "
            label = label $i
        }
        if (label == "") label = "SSH Key #" idx
        prev = (length(kbody) > 22) ? (substr(kbody, 1, 12) "..." substr(kbody, length(kbody) - 8)) : kbody
        if (!first) printf ","
        first = 0
        printf "{\"index\":%d,\"type\":\"%s\",\"label\":\"%s\",\"preview\":\"%s\"}", idx, esc(ktype), esc(label), esc(prev)
    }
    END { printf "]" }
    ' "$AUTH_KEYS"
}

add_pubkey() {
    label="$(printf '%s' "$1" | $TR -cd 'A-Za-z0-9._ -' | $SED 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    raw_key="$(printf '%s' "$2" | $TR '\r\n' '  ' | $SED 's/^[[:space:]]*//; s/[[:space:]]*$//')"

    ktype="$(printf '%s' "$raw_key" | $AWK '{print $1}')"
    kbody="$(printf '%s' "$raw_key" | $AWK '{print $2}')"
    kcomm="$(printf '%s' "$raw_key" | $AWK '{for(i=3;i<=NF;i++) printf "%s%s",(i>3?" ":""),$i}')"

    case "$ktype" in
        ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com)
            ;;
        *)
            printf '{"ok":false,"error":"Unsupported or invalid SSH public key format"}\n'
            return 1
            ;;
    esac

    if [ "${#kbody}" -lt 32 ]; then
        printf '{"ok":false,"error":"SSH public key payload appears truncated"}\n'
        return 1
    fi

    [ -z "$label" ] && label="$kcomm"
    [ -z "$label" ] && label="Client-Key"

    printf '%s %s %s\n' "$ktype" "$kbody" "$label" >> "$AUTH_KEYS"
    sync_authorized_keys_perms
    log_msg "Added SSH public key: $label ($ktype)"
    get_status_json
}

remove_pubkey() {
    target_idx="$1"
    case "$target_idx" in ''|*[!0-9]*) printf '{"ok":false,"error":"Invalid key index"}\n'; return 1 ;; esac

    tmp="$CFG_DIR/.ak.tmp.$$"
    $AWK -v rm_i="$target_idx" '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    {
        idx++
        if (idx != rm_i) print $0
    }
    ' "$AUTH_KEYS" > "$tmp"
    mv "$tmp" "$AUTH_KEYS"
    sync_authorized_keys_perms
    log_msg "Removed SSH public key #$target_idx"
    get_status_json
}

save_config() {
    # Args: enabled(0|1|'') port password_auth(0|1|'') add_label add_key remove_idx
    load_ssh_config

    in_en="$1"; in_port="$2"; in_pw="$3"
    in_lbl="$4"; in_key="$5"; in_rm="$6"

    if [ -n "$in_key" ]; then
        add_pubkey "$in_lbl" "$in_key"
        return $?
    fi
    if [ -n "$in_rm" ]; then
        remove_pubkey "$in_rm"
        return $?
    fi

    need_restart=0
    if [ -n "$in_en" ]; then
        case "$in_en" in 1|true|yes|on) new_en=1 ;; *) new_en=0 ;; esac
        if [ "$new_en" != "$S_ENABLED" ]; then S_ENABLED="$new_en"; need_restart=1; fi
    fi
    if [ -n "$in_port" ]; then
        case "$in_port" in
            ''|*[!0-9]*) printf '{"ok":false,"error":"Port must be 1024-65535"}\n'; return 1 ;;
        esac
        if [ "$in_port" -lt 1024 ] || [ "$in_port" -gt 65535 ]; then
            printf '{"ok":false,"error":"Port must be 1024-65535"}\n'
            return 1
        fi
        if [ "$in_port" != "$S_PORT" ]; then S_PORT="$in_port"; need_restart=1; fi
    fi
    if [ -n "$in_pw" ]; then
        case "$in_pw" in 1|true|yes|on) new_pw=1 ;; *) new_pw=0 ;; esac
        if [ "$new_pw" != "$S_PASSWD" ]; then S_PASSWD="$new_pw"; need_restart=1; fi
    fi

    write_ssh_json
    if [ "$need_restart" = "1" ]; then
        apply_ssh
        sleep 1
    fi
    get_status_json
}

get_status_json() {
    load_ssh_config
    detect_ssh_daemon

    running="false"
    cur_pid=0
    if is_running; then
        running="true"
        cur_pid="$(cat "$SSH_PID" 2>/dev/null | $TR -cd '0-9')"
        [ -z "$cur_pid" ] && cur_pid=0
    fi

    en_b="false"; [ "$S_ENABLED" = "1" ] && en_b="true"
    pw_b="false"; [ "$S_PASSWD" = "1" ] && pw_b="true"

    lan_ips="$(ip -4 -br addr 2>/dev/null | $AWK '
        $1 ~ /^(wlan|ap|swlan|softap|rndis|usb|ncm)/ && $2 != "DOWN" {
            for (i=3; i<=NF; i++) {
                if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/) {
                    ip = $i; sub(/\/.*/, "", ip)
                    if (out != "") out = out ","
                    out = out "\"" ip "\""
                }
            }
        }
        END { printf "[%s]", out }
    ')"
    [ -z "$lan_ips" ] && lan_ips="[]"

    sessions_json="$(get_sessions_json)"
    keys_json="$(get_keys_json)"

    printf '{"ok":true,"enabled":%s,"running":%s,"daemon":"%s","daemon_path":"%s","port":%s,"pid":%s,"password_auth":%s,"lan_ips":%s,"sessions":%s,"keys":%s}\n' \
        "$en_b" "$running" "$SSH_DAEMON" "$SSH_BIN" "$S_PORT" "$cur_pid" "$pw_b" "$lan_ips" "$sessions_json" "$keys_json"
}

CMD="$1"
if [ -z "$CMD" ] && [ -n "$REQUEST_METHOD" ]; then
    printf 'Content-Type: application/json\r\nCache-Control: no-store\r\n\r\n'
    get_status_json
    exit 0
fi

case "$CMD" in
    status|"")  get_status_json ;;
    apply)      apply_ssh ;;
    watchdog)   watchdog_check ;;
    stop)       stop_ssh ;;
    save)       save_config "$2" "$3" "$4" "$5" "$6" "$7" ;;
    *)          printf '{"ok":false,"error":"Unknown ssh command"}\n'; exit 1 ;;
esac
