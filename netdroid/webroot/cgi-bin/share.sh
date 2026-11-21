#!/system/bin/sh
# NetDroid - LAN Shared Folder (Pocket NAS) Engine
# Streaming HTTP File Server (with Range/206 resume & zero-RAM streaming uploads),
# strict path-traversal sanitization, storage capacity reporting, and optional rclone WebDAV.

export PATH="/data/adb/ksu/bin:/data/adb/ap/bin:/data/adb/magisk:/system/bin:/system/xbin:/product/bin:/vendor/bin:$PATH"

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
MOD_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)"
DATA_DIR="/data/adb/netdroid"
CFG_DIR="$DATA_DIR/config"
CONFIG_FILE="$DATA_DIR/config.env"
TOKENS_FILE="$DATA_DIR/auth_tokens.db"
SHARE_JSON="$CFG_DIR/share.json"
WEBDAV_PID="$DATA_DIR/webdav.pid"
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
SORT="${BB:+$BB sort}"; [ -z "$SORT" ] && SORT="sort"

mkdir -p "$CFG_DIR" 2>/dev/null
if [ -d "$MOD_DIR" ] && [ ! -e "$MOD_DIR/config" ]; then
    ln -s "$CFG_DIR" "$MOD_DIR/config" 2>/dev/null || true
fi

AUTH_ENABLED=1
if [ -f "$CONFIG_FILE" ]; then
    . "$CONFIG_FILE" 2>/dev/null
fi

urldecode() {
    if [ -n "$BB" ]; then
        "$BB" httpd -d "$1" 2>/dev/null
    else
        printf '%s' "$1"
    fi
}

qs_get() {
    key="$1"
    val="$(printf '%s' "$QUERY_STRING" | $AWK -v k="$key" '
    BEGIN { RS="&" }
    {
        idx = index($0, "=")
        if (idx > 0 && substr($0, 1, idx - 1) == k) {
            print substr($0, idx + 1)
            exit
        }
    }')"
    [ -n "$val" ] && urldecode "$val"
}

is_local_client() {
    case "$REMOTE_ADDR" in
        ""|"127.0.0.1"|"::1"|"::ffff:127.0.0.1") return 0 ;;
        *) return 1 ;;
    esac
}

verify_auth() {
    if is_local_client || [ "$AUTH_ENABLED" != "1" ]; then
        return 0
    fi
    tok="$HTTP_X_NETDROID_TOKEN"
    [ -z "$tok" ] && tok="$(qs_get token)"
    [ -z "$tok" ] && return 1
    [ ! -f "$TOKENS_FILE" ] && return 1
    now="$(date +%s 2>/dev/null || echo 0)"
    matched="$($AWK -F'|' -v t="$tok" -v now="$now" '$1 == t && ($2 + 0) > now { print "1"; exit }' "$TOKENS_FILE" 2>/dev/null)"
    [ "$matched" = "1" ]
}

json_hdr() {
    status="${1:-200 OK}"
    if [ -n "$REQUEST_METHOD" ] && [ -z "$NETDROID_CLI_RAW" ]; then
        printf 'Status: %s\r\n' "$status"
        printf 'Content-Type: application/json; charset=utf-8\r\n'
        printf 'Cache-Control: no-store\r\n'
        printf 'Access-Control-Allow-Origin: *\r\n'
        printf 'Access-Control-Allow-Headers: Content-Type, X-NetDroid-Token\r\n'
        printf 'Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n\r\n'
    fi
}

json_escape() {
    printf '%s' "$1" | $SED 's/\\/\\\\/g; s/"/\\"/g; s/	/\\t/g' | $TR -d '\r\n'
}

ensure_default_config() {
    if [ ! -s "$SHARE_JSON" ]; then
        printf '{"enabled":true,"root_path":"/sdcard/NetDroidShare","read_only":false,"webdav_enabled":false,"webdav_port":8766}\n' > "$SHARE_JSON"
        chmod 0644 "$SHARE_JSON" 2>/dev/null || true
    fi
}

load_share_config() {
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
    function gs(s, k, def,   m, r) {
        r = "\"" k "\"[[:space:]]*:[[:space:]]*\"[^\"]*\""
        if (match(s, r)) { m = substr(s, RSTART, RLENGTH); sub(/^[^:]+:[[:space:]]*"/, "", m); sub(/"$/, "", m); return m }
        return def
    }
    { line = line $0 }
    END {
        printf "SH_ENABLED=%d\n", gb(line, "enabled", 1)
        printf "SH_ROOT=\"%s\"\n", gs(line, "root_path", "/sdcard/NetDroidShare")
        printf "SH_RO=%d\n", gb(line, "read_only", 0)
        printf "SH_WEBDAV=%d\n", gb(line, "webdav_enabled", 0)
        printf "SH_WEBDAV_PORT=%d\n", gn(line, "webdav_port", 8766)
    }
    ' "$SHARE_JSON" 2>/dev/null)"
    [ -z "$SH_ROOT" ] && SH_ROOT="/sdcard/NetDroidShare"
    [ -z "$SH_WEBDAV_PORT" ] && SH_WEBDAV_PORT=8766

    # Auto-create default shared directory if missing
    if [ "$SH_ROOT" = "/sdcard/NetDroidShare" ] && [ ! -d "$SH_ROOT" ]; then
        mkdir -p /storage/emulated/0/NetDroidShare 2>/dev/null || mkdir -p "$SH_ROOT" 2>/dev/null || true
    fi
}

write_share_json() {
    en_b="false"; [ "$SH_ENABLED" = "1" ] && en_b="true"
    ro_b="false"; [ "$SH_RO" = "1" ] && ro_b="true"
    wd_b="false"; [ "$SH_WEBDAV" = "1" ] && wd_b="true"
    tmp="$CFG_DIR/.share.json.tmp.$$"
    printf '{"enabled":%s,"root_path":"%s","read_only":%s,"webdav_enabled":%s,"webdav_port":%s}\n' \
        "$en_b" "$(json_escape "$SH_ROOT")" "$ro_b" "$wd_b" "$SH_WEBDAV_PORT" > "$tmp" && mv "$tmp" "$SHARE_JSON"
    chmod 0644 "$SHARE_JSON" 2>/dev/null || true
}

# Canonicalize root and safely resolve relative path strictly inside root (blocks .. traversal)
resolve_safe_path() {
    rel="$1"
    REAL_ROOT="$($BB realpath "$SH_ROOT" 2>/dev/null)"
    if [ -z "$REAL_ROOT" ] || [ ! -d "$REAL_ROOT" ]; then
        return 1
    fi

    # Strip leading slashes
    clean="$(printf '%s' "$rel" | $SED 's#^/*##; s#//*#/#g')"
    # Reject any ".." segment or control chars
    case "/$clean/" in
        *"/../"*) return 2 ;;
    esac

    if [ -z "$clean" ] || [ "$clean" = "." ]; then
        RESOLVED_PATH="$REAL_ROOT"
        REL_CLEAN=""
        return 0
    fi

    candidate="$REAL_ROOT/$clean"
    if [ -e "$candidate" ]; then
        RESOLVED_PATH="$($BB realpath "$candidate" 2>/dev/null)"
    else
        # Validate parent dir when target doesn't exist yet (upload/mkdir/rename dest)
        parent="$(dirname "$candidate")"
        base="$(basename "$candidate")"
        real_parent="$($BB realpath "$parent" 2>/dev/null)"
        [ -z "$real_parent" ] && return 2
        RESOLVED_PATH="$real_parent/$base"
    fi

    case "$RESOLVED_PATH" in
        "$REAL_ROOT"|"$REAL_ROOT"/*)
            REL_CLEAN="$clean"
            return 0
            ;;
        *)
            return 2
            ;;
    esac
}

mime_for_file() {
    lower="$(printf '%s' "$1" | $TR 'A-Z' 'a-z')"
    case "$lower" in
        *.jpg|*.jpeg) echo "image/jpeg" ;;
        *.png)        echo "image/png" ;;
        *.webp)       echo "image/webp" ;;
        *.gif)        echo "image/gif" ;;
        *.svg)        echo "image/svg+xml" ;;
        *.mp4|*.m4v)  echo "video/mp4" ;;
        *.mkv)        echo "video/x-matroska" ;;
        *.webm)       echo "video/webm" ;;
        *.mp3)        echo "audio/mpeg" ;;
        *.flac)       echo "audio/flac" ;;
        *.ogg|*.opus) echo "audio/ogg" ;;
        *.wav)        echo "audio/wav" ;;
        *.pdf)        echo "application/pdf" ;;
        *.zip)        echo "application/zip" ;;
        *.apk)        echo "application/vnd.android.package-archive" ;;
        *.tar|*.gz|*.xz|*.7z|*.rar) echo "application/x-compressed" ;;
        *.img|*.iso)  echo "application/octet-stream" ;;
        *.txt|*.md|*.log|*.sh|*.conf|*.ini|*.cfg) echo "text/plain; charset=utf-8" ;;
        *.json)       echo "application/json" ;;
        *.html|*.htm) echo "text/html; charset=utf-8" ;;
        *)            echo "application/octet-stream" ;;
    esac
}

detect_webdav_bin() {
    WEBDAV_BIN=""
    for b in /data/adb/modules/netdroid/bin/rclone /system/bin/rclone /data/data/com.termux/files/usr/bin/rclone; do
        if [ -x "$b" ]; then WEBDAV_BIN="$b"; return 0; fi
    done
    WEBDAV_BIN="$(command -v rclone 2>/dev/null)"
}

sync_webdav() {
    detect_webdav_bin
    if [ -f "$WEBDAV_PID" ]; then
        wpid="$(cat "$WEBDAV_PID" 2>/dev/null)"
        [ -n "$wpid" ] && kill "$wpid" 2>/dev/null || true
        rm -f "$WEBDAV_PID"
    fi
    if [ "$SH_WEBDAV" = "1" ] && [ -n "$WEBDAV_BIN" ] && [ -d "$SH_ROOT" ]; then
        ro_flag=""
        [ "$SH_RO" = "1" ] && ro_flag="--read-only"
        "$BB" setsid "$WEBDAV_BIN" serve webdav "$SH_ROOT" --addr "0.0.0.0:$SH_WEBDAV_PORT" $ro_flag </dev/null >/dev/null 2>&1 &
        printf '%s\n' "$!" > "$WEBDAV_PID"
    fi
}

# List directory + storage capacity + available roots
do_list() {
    load_share_config
    rel_path="$1"

    if ! resolve_safe_path "$rel_path"; then
        printf '{"ok":false,"error":"Invalid or inaccessible shared path"}\n'
        return 1
    fi
    if [ ! -d "$RESOLVED_PATH" ]; then
        printf '{"ok":false,"error":"Directory not found"}\n'
        return 1
    fi

    # Storage capacity via df -k (returns 1K blocks -> multiply by 1024 in awk float)
    storage_json="$($BB df -k "$RESOLVED_PATH" 2>/dev/null | $AWK '
    NR == 2 {
        tot = ($2 + 0) * 1024
        used = ($3 + 0) * 1024
        avail = ($4 + 0) * 1024
        pct = (tot > 0) ? int((used * 100) / tot + 0.5) : 0
        printf "{\"total_bytes\":%.0f,\"used_bytes\":%.0f,\"free_bytes\":%.0f,\"used_pct\":%d}", tot, used, avail, pct
        ok = 1
    }
    END { if (!ok) printf "{\"total_bytes\":0,\"used_bytes\":0,\"free_bytes\":0,\"used_pct\":0}" }
    ')"

    # Available storage roots (internal presets + mounted USB OTG drives)
    roots_json='["/sdcard/NetDroidShare","/sdcard/Download","/sdcard"'
    if [ -d /mnt/media_rw ]; then
        for otg in /mnt/media_rw/*; do
            if [ -d "$otg" ]; then
                roots_json="$roots_json,\"$(json_escape "$otg")\""
            fi
        done
    fi
    roots_json="$roots_json]"

    # Enumerate entries cleanly (dirs first, then files, sorted by name)
    tmp_dirs="$DATA_DIR/.sh_dirs.$$"
    tmp_files="$DATA_DIR/.sh_files.$$"
    : > "$tmp_dirs"; : > "$tmp_files"

    for entry in "$RESOLVED_PATH"/* "$RESOLVED_PATH"/.*; do
        base="$(basename "$entry")"
        [ "$base" = "." ] || [ "$base" = ".." ] || [ "$base" = "*" ] || [ "$base" = ".*" ] && continue
        [ -e "$entry" ] || continue
        mtime="$($BB stat -c %Y "$entry" 2>/dev/null || echo 0)"
        if [ -d "$entry" ]; then
            printf '%s\t1\t0\t%s\tinode/directory\n' "$base" "$mtime" >> "$tmp_dirs"
        else
            fsize="$($BB stat -c %s "$entry" 2>/dev/null || echo 0)"
            fmime="$(mime_for_file "$base")"
            printf '%s\t0\t%s\t%s\t%s\n' "$base" "$fsize" "$mtime" "$fmime" >> "$tmp_files"
        fi
    done

    items_json="$({ $SORT -f "$tmp_dirs" 2>/dev/null; $SORT -f "$tmp_files" 2>/dev/null; } | $AWK -F'\t' '
    function esc(s) {
        gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); gsub(/\r|\n/, "", s)
        return s
    }
    BEGIN { printf "["; first = 1 }
    NF >= 5 {
        if (!first) printf ","
        first = 0
        printf "{\"name\":\"%s\",\"is_dir\":%s,\"size\":%s,\"mtime\":%s,\"mime\":\"%s\"}", \
            esc($1), ($2 == "1" ? "true" : "false"), $3, $4, esc($5)
    }
    END { printf "]" }
    ')"
    rm -f "$tmp_dirs" "$tmp_files" 2>/dev/null

    detect_webdav_bin
    wd_sup="false"; [ -n "$WEBDAV_BIN" ] && wd_sup="true"
    wd_run="false"
    if [ -f "$WEBDAV_PID" ] && kill -0 "$(cat "$WEBDAV_PID" 2>/dev/null)" 2>/dev/null; then
        wd_run="true"
    fi

    ro_b="false"; [ "$SH_RO" = "1" ] && ro_b="true"
    en_b="false"; [ "$SH_ENABLED" = "1" ] && en_b="true"

    printf '{"ok":true,"enabled":%s,"read_only":%s,"root_path":"%s","path":"/%s","storage":%s,"available_roots":%s,"webdav":{"supported":%s,"running":%s,"port":%s},"items":%s}\n' \
        "$en_b" "$ro_b" "$(json_escape "$SH_ROOT")" "$(json_escape "$REL_CLEAN")" \
        "$storage_json" "$roots_json" "$wd_sup" "$wd_run" "$SH_WEBDAV_PORT" "$items_json"
}

# Streaming file download with full HTTP Range (206 Partial Content) support
do_download() {
    load_share_config
    rel_file="$1"
    inline_mode="$2"

    if ! resolve_safe_path "$rel_file" || [ ! -f "$RESOLVED_PATH" ]; then
        json_hdr "404 Not Found"
        printf '{"ok":false,"error":"File not found"}\n'
        return 0
    fi

    fsize="$($BB stat -c %s "$RESOLVED_PATH" 2>/dev/null || echo 0)"
    fname="$(basename "$RESOLVED_PATH" | $TR -d '\r\n"')"
    fmime="$(mime_for_file "$fname")"
    disp="attachment"
    [ "$inline_mode" = "1" ] && disp="inline"

    # Parse HTTP_RANGE header or explicit ?range=START-END query parameter
    raw_range="$HTTP_RANGE"
    if [ -z "$raw_range" ]; then
        q_rng="$(qs_get range)"
        if [ -n "$q_rng" ]; then
            case "$q_rng" in
                bytes=*) raw_range="$q_rng" ;;
                *)       raw_range="bytes=$q_rng" ;;
            esac
        fi
    fi

    if [ -n "$raw_range" ] && [ "$fsize" -gt 0 ] 2>/dev/null; then
        range_spec="$(printf '%s' "$raw_range" | $SED -n 's/^bytes=\([0-9]*\)-\([0-9]*\).*/\1 \2/p')"
        if [ -n "$range_spec" ]; then
            set -- $range_spec
            r_start="$1"
            r_end="$2"
            [ -z "$r_start" ] && r_start=0
            [ -z "$r_end" ] && r_end=$((fsize - 1))
            if [ "$r_end" -ge "$fsize" ]; then r_end=$((fsize - 1)); fi

            if [ "$r_start" -gt "$r_end" ] || [ "$r_start" -ge "$fsize" ]; then
                printf 'Status: 416 Range Not Satisfiable\r\n'
                printf 'Content-Range: bytes */%s\r\n\r\n' "$fsize"
                return 0
            fi

            chunk_len=$((r_end - r_start + 1))
            printf 'Status: 206 Partial Content\r\n'
            printf 'Content-Type: %s\r\n' "$fmime"
            printf 'Content-Disposition: %s; filename="%s"\r\n' "$disp" "$fname"
            printf 'Accept-Ranges: bytes\r\n'
            printf 'Content-Range: bytes %s-%s/%s\r\n' "$r_start" "$r_end" "$fsize"
            printf 'Content-Length: %s\r\n' "$chunk_len"
            printf 'Access-Control-Allow-Origin: *\r\n\r\n'

            # Stream byte-exact slice with zero RAM buffering
            "$BB" tail -c "+$((r_start + 1))" "$RESOLVED_PATH" | "$BB" head -c "$chunk_len"
            return 0
        fi
    fi

    printf 'Status: 200 OK\r\n'
    printf 'Content-Type: %s\r\n' "$fmime"
    printf 'Content-Disposition: %s; filename="%s"\r\n' "$disp" "$fname"
    printf 'Accept-Ranges: bytes\r\n'
    printf 'Content-Length: %s\r\n' "$fsize"
    printf 'Access-Control-Allow-Origin: *\r\n\r\n'
    cat "$RESOLVED_PATH"
}

# Zero-RAM streaming file upload (raw binary or chunked append)
do_upload() {
    load_share_config
    if [ "$SH_RO" = "1" ]; then
        json_hdr "403 Forbidden"
        printf '{"ok":false,"error":"Shared folder is in Read-Only mode"}\n'
        return 0
    fi

    dir_rel="$(qs_get path)"
    fname="$(qs_get name)"
    append_flag="$(qs_get append)"

    # Sanitize filename strictly (strip slashes & control chars)
    clean_name="$(printf '%s' "$fname" | $SED 's#.*/##' | $TR -d '\r\n\000')"
    if [ -z "$clean_name" ] || [ "$clean_name" = "." ] || [ "$clean_name" = ".." ]; then
        json_hdr "400 Bad Request"
        printf '{"ok":false,"error":"Valid filename required"}\n'
        return 0
    fi

    target_rel="${dir_rel}/${clean_name}"
    if ! resolve_safe_path "$target_rel"; then
        json_hdr "403 Forbidden"
        printf '{"ok":false,"error":"Invalid target upload path"}\n'
        return 0
    fi

    parent_dir="$(dirname "$RESOLVED_PATH")"
    if [ ! -d "$parent_dir" ]; then
        json_hdr "404 Not Found"
        printf '{"ok":false,"error":"Target folder does not exist"}\n'
        return 0
    fi

    # Stream stdin directly to disk without buffering in RAM
    if [ "$append_flag" = "1" ]; then
        if [ -n "$CONTENT_LENGTH" ] && [ "$CONTENT_LENGTH" -gt 0 ] 2>/dev/null; then
            "$BB" head -c "$CONTENT_LENGTH" >> "$RESOLVED_PATH"
        else
            cat >> "$RESOLVED_PATH"
        fi
    else
        tmp_dest="${parent_dir}/.nd_up_${$}_${clean_name}"
        if [ -n "$CONTENT_LENGTH" ] && [ "$CONTENT_LENGTH" -gt 0 ] 2>/dev/null; then
            "$BB" head -c "$CONTENT_LENGTH" > "$tmp_dest"
        else
            cat > "$tmp_dest"
        fi
        mv "$tmp_dest" "$RESOLVED_PATH"
    fi

    fsize="$($BB stat -c %s "$RESOLVED_PATH" 2>/dev/null || echo 0)"
    json_hdr "200 OK"
    printf '{"ok":true,"name":"%s","size":%s}\n' "$(json_escape "$clean_name")" "$fsize"
}

# Folder/File management & config update
do_manage() {
    # Args: op path name new_name root_path read_only webdav
    load_share_config
    op="$1"; rel_path="$2"; name="$3"; new_name="$4"
    in_root="$5"; in_ro="$6"; in_wd="$7"

    case "$op" in
        config)
            if [ -n "$in_root" ]; then
                # Allow internal storage or /mnt/media_rw paths
                clean_root="$(printf '%s' "$in_root" | $SED 's#//*#/#g; s#/$##')"
                [ -z "$clean_root" ] && clean_root="/sdcard/NetDroidShare"
                if [ ! -d "$clean_root" ]; then
                    mkdir -p "$clean_root" 2>/dev/null || true
                fi
                if [ ! -d "$clean_root" ]; then
                    printf '{"ok":false,"error":"Directory does not exist or cannot be created"}\n'
                    return 1
                fi
                SH_ROOT="$clean_root"
            fi
            if [ -n "$in_ro" ]; then
                case "$in_ro" in 1|true|yes|on) SH_RO=1 ;; *) SH_RO=0 ;; esac
            fi
            if [ -n "$in_wd" ]; then
                case "$in_wd" in 1|true|yes|on) SH_WEBDAV=1 ;; *) SH_WEBDAV=0 ;; esac
            fi
            write_share_json
            sync_webdav
            do_list "/"
            ;;

        mkdir)
            if [ "$SH_RO" = "1" ]; then printf '{"ok":false,"error":"Read-Only mode active"}\n'; return 1; fi
            clean_n="$(printf '%s' "$name" | $SED 's#.*/##' | $TR -d '\r\n')"
            if [ -z "$clean_n" ] || [ "$clean_n" = "." ] || [ "$clean_n" = ".." ]; then
                printf '{"ok":false,"error":"Invalid folder name"}\n'; return 1
            fi
            if ! resolve_safe_path "${rel_path}/${clean_n}"; then
                printf '{"ok":false,"error":"Invalid path"}\n'; return 1
            fi
            mkdir -p "$RESOLVED_PATH" 2>/dev/null || { printf '{"ok":false,"error":"Failed to create folder"}\n'; return 1; }
            printf '{"ok":true,"created":"%s"}\n' "$(json_escape "$clean_n")"
            ;;

        rename)
            if [ "$SH_RO" = "1" ]; then printf '{"ok":false,"error":"Read-Only mode active"}\n'; return 1; fi
            clean_new="$(printf '%s' "$new_name" | $SED 's#.*/##' | $TR -d '\r\n')"
            if [ -z "$clean_new" ] || [ "$clean_new" = "." ] || [ "$clean_new" = ".." ]; then
                printf '{"ok":false,"error":"Invalid new name"}\n'; return 1
            fi
            if ! resolve_safe_path "${rel_path}/${name}" || [ ! -e "$RESOLVED_PATH" ]; then
                printf '{"ok":false,"error":"Source item not found"}\n'; return 1
            fi
            src="$RESOLVED_PATH"
            [ "$src" = "$REAL_ROOT" ] && { printf '{"ok":false,"error":"Cannot rename root"}\n'; return 1; }
            dst="$(dirname "$src")/$clean_new"
            mv "$src" "$dst" 2>/dev/null || { printf '{"ok":false,"error":"Rename failed"}\n'; return 1; }
            printf '{"ok":true,"renamed":"%s"}\n' "$(json_escape "$clean_new")"
            ;;

        delete)
            if [ "$SH_RO" = "1" ]; then printf '{"ok":false,"error":"Read-Only mode active"}\n'; return 1; fi
            if ! resolve_safe_path "${rel_path}/${name}" || [ ! -e "$RESOLVED_PATH" ]; then
                printf '{"ok":false,"error":"Item not found"}\n'; return 1
            fi
            if [ "$RESOLVED_PATH" = "$REAL_ROOT" ]; then
                printf '{"ok":false,"error":"Cannot delete shared root directory"}\n'; return 1
            fi
            rm -rf "$RESOLVED_PATH" 2>/dev/null || { printf '{"ok":false,"error":"Delete failed"}\n'; return 1; }
            printf '{"ok":true,"deleted":"%s"}\n' "$(json_escape "$name")"
            ;;

        *)
            printf '{"ok":false,"error":"Unknown share manage operation"}\n'
            return 1
            ;;
    esac
}

# Handle direct CGI invocation (download / upload / list)
if [ -z "$1" ] && [ -n "$REQUEST_METHOD" ]; then
    if [ "$REQUEST_METHOD" = "OPTIONS" ]; then
        json_hdr "204 No Content"
        exit 0
    fi
    if ! verify_auth; then
        json_hdr "401 Unauthorized"
        printf '{"ok":false,"error":"Authentication required","auth_required":true}\n'
        exit 0
    fi
    act="$(qs_get action)"
    case "$act" in
        download)
            do_download "$(qs_get file)" "$(qs_get inline)"
            ;;
        upload)
            do_upload
            ;;
        list|"")
            json_hdr "200 OK"
            do_list "$(qs_get path)"
            ;;
        *)
            json_hdr "400 Bad Request"
            printf '{"ok":false,"error":"Unknown share CGI action"}\n'
            ;;
    esac
    exit 0
fi

# CLI invocation from api.sh / service.sh
case "$1" in
    list|"") do_list "$2" ;;
    manage)  do_manage "$2" "$3" "$4" "$5" "$6" "$7" "$8" ;;
    sync)    load_share_config; sync_webdav ;;
    stop)
        if [ -f "$WEBDAV_PID" ]; then
            kill "$(cat "$WEBDAV_PID" 2>/dev/null)" 2>/dev/null || true
            rm -f "$WEBDAV_PID"
        fi
        ;;
    *)       printf '{"ok":false,"error":"Unknown share command"}\n'; exit 1 ;;
esac
