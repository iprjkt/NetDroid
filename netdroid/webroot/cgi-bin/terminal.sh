#!/system/bin/sh
# NetDroid - Embedded Web Console Execution Bridge
# Stateful CWD shell runner with safety timeout, tab completion & Ctrl+C abort.

export PATH="/data/adb/ksu/bin:/data/adb/ap/bin:/data/adb/magisk:/system/bin:/system/xbin:/product/bin:/vendor/bin:$PATH"
export HOME="/data/adb/netdroid"
export TERM="xterm-256color"

DATA_DIR="/data/adb/netdroid"
CWD_FILE="$DATA_DIR/.term_cwd"
ACTIVE_PID="$DATA_DIR/.term_active.pid"

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

mkdir -p "$DATA_DIR" 2>/dev/null
[ -s "$CWD_FILE" ] || printf '%s\n' "$DATA_DIR" > "$CWD_FILE"

json_str() {
    $AWK '
    BEGIN { ORS="" }
    {
        gsub(/\\/, "\\\\")
        gsub(/"/, "\\\"")
        gsub(/\t/, "\\t")
        gsub(/\r/, "")
        if (NR > 1) printf "\\n"
        printf "%s", $0
    }'
}

run_exec() {
    cmd="$1"
    cwd="$(cat "$CWD_FILE" 2>/dev/null | $TR -d '\r\n')"
    [ -d "$cwd" ] || cwd="$DATA_DIR"

    if [ -z "$cmd" ]; then
        printf '{"ok":true,"output":"","exit_code":0,"cwd":"%s"}\n' "$(printf '%s' "$cwd" | json_str)"
        return 0
    fi

    tmp_out="$DATA_DIR/.term_out.$$"
    tmp_cwd="$DATA_DIR/.term_cwd.$$"
    tmp_cmd="$DATA_DIR/.term_cmd.$$"

    # Write command to temp script so quoting/pipes/redirects behave identically to an interactive shell
    cat <<EOF > "$tmp_cmd"
cd "$cwd" 2>/dev/null || cd "$DATA_DIR"
$cmd
__nd_rc=\$?
pwd > "$tmp_cwd" 2>/dev/null
exit \$__nd_rc
EOF

    # Execute with 18s safety timeout and cap output at 64KB
    if [ -n "$BB" ]; then
        "$BB" timeout 18 sh "$tmp_cmd" > "$tmp_out" 2>&1 &
        cpid=$!
        printf '%s\n' "$cpid" > "$ACTIVE_PID"
        wait "$cpid"
        rc=$?
        rm -f "$ACTIVE_PID" 2>/dev/null
    else
        sh "$tmp_cmd" > "$tmp_out" 2>&1
        rc=$?
    fi

    if [ -s "$tmp_cwd" ]; then
        new_cwd="$(cat "$tmp_cwd" 2>/dev/null | $TR -d '\r\n')"
        [ -d "$new_cwd" ] && printf '%s\n' "$new_cwd" > "$CWD_FILE"
    fi
    cur_cwd="$(cat "$CWD_FILE" 2>/dev/null | $TR -d '\r\n')"

    # Truncate huge output cleanly to 64KB
    out_json="$($BB head -c 65536 "$tmp_out" 2>/dev/null | json_str)"
    rm -f "$tmp_out" "$tmp_cwd" "$tmp_cmd" 2>/dev/null

    printf '{"ok":true,"output":"%s","exit_code":%s,"cwd":"%s"}\n' \
        "$out_json" "$rc" "$(printf '%s' "$cur_cwd" | json_str)"
}

run_complete() {
    token="$1"
    cwd="$(cat "$CWD_FILE" 2>/dev/null | $TR -d '\r\n')"
    [ -d "$cwd" ] || cwd="$DATA_DIR"
    cd "$cwd" 2>/dev/null || cd "$DATA_DIR"

    matches=""
    count=0
    for item in ${token}*; do
        [ -e "$item" ] || continue
        [ -d "$item" ] && item="${item}/"
        if [ "$count" -gt 0 ]; then matches="$matches,"; fi
        matches="$matches\"$(printf '%s' "$item" | json_str)\""
        count=$((count + 1))
        [ "$count" -ge 25 ] && break
    done

    printf '{"ok":true,"matches":[%s],"cwd":"%s"}\n' "$matches" "$(printf '%s' "$cwd" | json_str)"
}

run_kill() {
    if [ -f "$ACTIVE_PID" ]; then
        pid="$(cat "$ACTIVE_PID" 2>/dev/null)"
        if [ -n "$pid" ]; then
            kill -TERM "$pid" 2>/dev/null || true
            kill -KILL "$pid" 2>/dev/null || true
        fi
        rm -f "$ACTIVE_PID" 2>/dev/null
    fi
    printf '{"ok":true,"killed":true}\n'
}

case "$1" in
    exec)     run_exec "$2" ;;
    complete) run_complete "$2" ;;
    kill)     run_kill ;;
    pwd|"")
        cwd="$(cat "$CWD_FILE" 2>/dev/null | $TR -d '\r\n')"
        [ -d "$cwd" ] || cwd="$DATA_DIR"
        printf '{"ok":true,"cwd":"%s"}\n' "$(printf '%s' "$cwd" | json_str)"
        ;;
    *)        printf '{"ok":false,"error":"Unknown terminal command"}\n'; exit 1 ;;
esac
