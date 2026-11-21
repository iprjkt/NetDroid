#!/system/bin/sh
# NetDroid - Custom Background Image Upload, Persistence & Sync Server
# Saves uploaded wallpaper to /data/adb/netdroid/custom_bg.<ext> so it syncs
# across both the host device (ginkgo) and remote LAN clients (tanzanite).

export PATH="/data/adb/ksu/bin:/data/adb/ap/bin:/data/adb/magisk:/system/bin:/system/xbin:/vendor/bin:$PATH"

DATA_DIR="/data/adb/netdroid"
CONFIG_FILE="$DATA_DIR/config.env"
TOKENS_FILE="$DATA_DIR/auth_tokens.db"
META_FILE="$DATA_DIR/custom_bg.meta"
MAX_BYTES=6291456

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
TR="${BB:+$BB tr}"; [ -z "$TR" ] && TR="tr"

AUTH_ENABLED=1
if [ -f "$CONFIG_FILE" ]; then
    . "$CONFIG_FILE" 2>/dev/null
fi

mkdir -p "$DATA_DIR" 2>/dev/null

# Parse query string key
qs_get() {
    key="$1"
    printf '%s' "$QUERY_STRING" | $AWK -v k="$key" '
    BEGIN { RS="&" }
    {
        idx = index($0, "=")
        if (idx > 0 && substr($0, 1, idx - 1) == k) {
            print substr($0, idx + 1)
            exit
        }
    }'
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
    if [ -n "$REQUEST_METHOD" ]; then
        printf 'Status: %s\r\n' "$status"
        printf 'Content-Type: application/json\r\n'
        printf 'Cache-Control: no-store\r\n'
        printf 'Access-Control-Allow-Origin: *\r\n'
        printf 'Access-Control-Allow-Headers: Content-Type, X-NetDroid-Token\r\n'
        printf 'Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n\r\n'
    fi
}

find_bg_file() {
    for ext in webp jpg jpeg png; do
        if [ -f "$DATA_DIR/custom_bg.$ext" ] && [ -s "$DATA_DIR/custom_bg.$ext" ]; then
            echo "$DATA_DIR/custom_bg.$ext"
            return 0
        fi
    done
    return 1
}

ext_to_mime() {
    case "$1" in
        webp) echo "image/webp" ;;
        jpg|jpeg) echo "image/jpeg" ;;
        png) echo "image/png" ;;
        *) echo "application/octet-stream" ;;
    esac
}

# Handle CORS preflight
if [ "$REQUEST_METHOD" = "OPTIONS" ]; then
    json_hdr "204 No Content"
    exit 0
fi

# CLI / ksu.exec mode support
if [ -z "$REQUEST_METHOD" ] && [ -n "$1" ]; then
    case "$1" in
        info)    ACTION="info"; REQUEST_METHOD="" ;;
        datauri) ACTION="datauri"; REQUEST_METHOD="" ;;
        clear)   ACTION="clear"; REQUEST_METHOD="" ;;
        save_b64)
            ACTION="save_b64"
            BG_TYPE="${2:-webp}"
            ;;
    esac
else
    ACTION="$(qs_get action)"
    BG_TYPE="$(qs_get type)"
    ENCODING="$(qs_get encoding)"
fi

if [ "$ACTION" = "info" ]; then
    json_hdr "200 OK"
    bg="$(find_bg_file)"
    if [ -n "$bg" ]; then
        ext="${bg##*.}"
        mime="$(ext_to_mime "$ext")"
        size="$($BB stat -c %s "$bg" 2>/dev/null || echo 0)"
        mtime="$($BB stat -c %Y "$bg" 2>/dev/null || echo 0)"
        printf '{"ok":true,"exists":true,"ext":"%s","mime":"%s","size":%s,"updated_at":%s}\n' "$ext" "$mime" "$size" "$mtime"
    else
        printf '{"ok":true,"exists":false}\n'
    fi
    exit 0
fi

if [ "$ACTION" = "datauri" ]; then
    json_hdr "200 OK"
    bg="$(find_bg_file)"
    if [ -n "$bg" ]; then
        ext="${bg##*.}"
        mime="$(ext_to_mime "$ext")"
        printf '{"ok":true,"exists":true,"data_uri":"data:%s;base64,' "$mime"
        $BB base64 "$bg" 2>/dev/null | $TR -d '\r\n'
        printf '"}\n'
    else
        printf '{"ok":true,"exists":false,"data_uri":""}\n'
    fi
    exit 0
fi

if [ "$ACTION" = "clear" ]; then
    if ! verify_auth; then
        json_hdr "401 Unauthorized"
        printf '{"ok":false,"error":"Authentication required"}\n'
        exit 0
    fi
    rm -f "$DATA_DIR"/custom_bg.webp "$DATA_DIR"/custom_bg.jpg "$DATA_DIR"/custom_bg.jpeg "$DATA_DIR"/custom_bg.png "$META_FILE" 2>/dev/null
    json_hdr "200 OK"
    printf '{"ok":true,"cleared":true}\n'
    exit 0
fi

if [ "$ACTION" = "save_b64" ] || [ "$REQUEST_METHOD" = "POST" ]; then
    if ! verify_auth; then
        json_hdr "401 Unauthorized"
        printf '{"ok":false,"error":"Authentication required"}\n'
        exit 0
    fi

    # Determine extension from query param or Content-Type
    if [ -z "$BG_TYPE" ]; then
        case "$CONTENT_TYPE" in
            *webp*) BG_TYPE="webp" ;;
            *png*)  BG_TYPE="png" ;;
            *jpeg*|*jpg*) BG_TYPE="jpg" ;;
            *) BG_TYPE="webp" ;;
        esac
    fi

    case "$BG_TYPE" in
        webp|jpg|jpeg|png) ;;
        *) BG_TYPE="webp" ;;
    esac
    [ "$BG_TYPE" = "jpeg" ] && BG_TYPE="jpg"

    if [ -n "$CONTENT_LENGTH" ] && [ "$CONTENT_LENGTH" -gt "$MAX_BYTES" ] 2>/dev/null; then
        json_hdr "413 Payload Too Large"
        printf '{"ok":false,"error":"Image exceeds 6MB limit"}\n'
        exit 0
    fi

    tmp_file="$DATA_DIR/.custom_bg_upload.$$"
    if [ "$ACTION" = "save_b64" ] || [ "$ENCODING" = "base64" ]; then
        $TR -d '\r\n ' | $BB base64 -d > "$tmp_file" 2>/dev/null
    else
        if [ -n "$CONTENT_LENGTH" ] && [ "$CONTENT_LENGTH" -gt 0 ] 2>/dev/null; then
            $BB head -c "$CONTENT_LENGTH" > "$tmp_file" 2>/dev/null || cat > "$tmp_file"
        else
            $BB head -c "$MAX_BYTES" > "$tmp_file" 2>/dev/null || cat > "$tmp_file"
        fi
    fi

    fsize="$($BB stat -c %s "$tmp_file" 2>/dev/null || echo 0)"
    if [ "$fsize" -lt 64 ] 2>/dev/null; then
        rm -f "$tmp_file" 2>/dev/null
        json_hdr "400 Bad Request"
        printf '{"ok":false,"error":"Empty or invalid image payload"}\n'
        exit 0
    fi

    # Remove old background files before moving new one in place
    rm -f "$DATA_DIR"/custom_bg.webp "$DATA_DIR"/custom_bg.jpg "$DATA_DIR"/custom_bg.jpeg "$DATA_DIR"/custom_bg.png 2>/dev/null
    target="$DATA_DIR/custom_bg.$BG_TYPE"
    mv "$tmp_file" "$target"
    chmod 0644 "$target" 2>/dev/null || true

    now="$(date +%s 2>/dev/null || echo 0)"
    printf 'EXT=%s\nSIZE=%s\nUPDATED=%s\n' "$BG_TYPE" "$fsize" "$now" > "$META_FILE"

    json_hdr "200 OK"
    printf '{"ok":true,"ext":"%s","size":%s,"updated_at":%s}\n' "$BG_TYPE" "$fsize" "$now"
    exit 0
fi

# Default GET: stream binary image file
bg="$(find_bg_file)"
if [ -z "$bg" ]; then
    json_hdr "404 Not Found"
    printf '{"ok":false,"error":"No custom background uploaded"}\n'
    exit 0
fi

ext="${bg##*.}"
mime="$(ext_to_mime "$ext")"
size="$($BB stat -c %s "$bg" 2>/dev/null || echo 0)"

if [ -n "$REQUEST_METHOD" ]; then
    printf 'Status: 200 OK\r\n'
    printf 'Content-Type: %s\r\n' "$mime"
    printf 'Content-Length: %s\r\n' "$size"
    printf 'Cache-Control: no-cache\r\n'
    printf 'Access-Control-Allow-Origin: *\r\n\r\n'
fi
cat "$bg"
