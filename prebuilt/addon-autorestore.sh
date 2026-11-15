#!/system/bin/sh
#
# los-tv: восстановление проприетарных компонентов после OTA (2026-11-01).
#
# Запускается init-действием при sys.boot_completed=1 через `exec`, без
# service-блока: в этой сборке init парсит action из нашего rc-файла, но
# service из него не регистрирует (причина не выяснена; preinstall-apps из
# того же каталога регистрируется). exec делает то же самое без сервисов.
#
# Если на загрузочном разделе лежит подготовленный архив
# (los-tv-proprietary.tar.gz), а в системе нет Widevine/NDK translation
# (например, после полного OTA, который заменил system-раздел базовым
# образом), создаём маркер <boot>/grub/addon-pending. GRUB при следующей
# загрузке увидит маркер и первым пунктом запустит установку компонентов.
#
# Наличие архива — это и есть «флаг»: нет архива — нет автозапуска.
#
# В обычной загрузке /boot — это bind-монтирование /mnt/cdrom/boot, а сам
# архив установщик кладёт в корень раздела (/mnt/cdrom). Поэтому ищем payload
# в нескольких местах, а маркер пишем туда, где реально лежит grub.cfg.

LOG_TAG=addon-autorestore

PAYLOAD=
for c in /mnt/cdrom/los-tv-proprietary.tar.gz \
         /boot/los-tv-proprietary.tar.gz \
         /mnt/cdrom/boot/los-tv-proprietary.tar.gz; do
    if [ -f "$c" ]; then
        PAYLOAD="$c"
        break
    fi
done

GRUBDIR=/boot/grub
[ -f "$GRUBDIR/grub.cfg" ] || GRUBDIR=/mnt/cdrom/boot/grub

MARKER="$GRUBDIR/addon-pending"
ATTEMPTS_FILE="$GRUBDIR/addon-attempts"

# --- YouTube payload sync -------------------------------------------------
# Keep /sdcard/los-tv-proprietary up to date with the installed YouTube while
# the system is healthy. This runs on every boot, not only before the add-on
# recovery reboot: if /data/app becomes a ghost after an OTA, there is no APK
# left to copy at that point.
YT_DIR=/sdcard/los-tv-proprietary
YT_BASE="$YT_DIR/YouTube-TV.apk"
YT_SPLIT="$YT_DIR/YouTubeTV-split_config.arm64_v8a.apk"
YT_VER="$YT_DIR/YouTubeTV.versionCode"

yt_log() { echo "$LOG_TAG: $*" | log -t "$LOG_TAG" -p i; }

# versionCode is trusted only if it matches the base APK currently on sdcard
yt_sidecar_version() {
    [ -f "$YT_VER" ] && [ -f "$YT_BASE" ] || return 1
    set -- $(cat "$YT_VER" 2>/dev/null)
    case "${1:-}" in ''|*[!0-9]*) return 1;; esac
    [ -n "${2:-}" ] || return 1
    [ "$(sha256sum "$YT_BASE" | cut -d' ' -f1)" = "$2" ] || return 1
    echo "$1"
}

sync_youtube_payload() {
    [ -d /sdcard ] || return 0
    [ -d "$YT_DIR" ] || mkdir -p "$YT_DIR" 2>/dev/null || return 0

    paths=$(pm path com.google.android.youtube.tv 2>/dev/null | sed 's/^package://')
    [ -n "$paths" ] || {
        yt_log "YouTube not installed/ghost; payload sync skipped"
        return 0
    }
    base=$(printf '%s\n' "$paths" | grep '/base.apk$' | head -1)
    split=$(printf '%s\n' "$paths" | grep '/split_config.arm64_v8a.apk$' | head -1)
    [ -n "$base" ] && [ -f "$base" ] || {
        yt_log "YouTube base path missing; payload sync skipped"
        return 0
    }

    inst_ver=$(dumpsys package com.google.android.youtube.tv 2>/dev/null | \
        sed -n 's/.*versionCode=\([0-9]*\).*/\1/p' | head -1)
    case "${inst_ver:-}" in
        ''|*[!0-9]*) yt_log "YouTube versionCode unavailable; payload sync skipped"; return 0 ;;
    esac

    sd_ver=$(yt_sidecar_version 2>/dev/null || true)
    if [ -n "$sd_ver" ] && [ -f "$YT_SPLIT" ] && [ -n "$split" ] && \
       [ "$sd_ver" -ge "$inst_ver" ]; then
        yt_log "sdcard YouTube $sd_ver >= installed $inst_ver; keeping payload"
        return 0
    fi

    # Sidecar missing but files equal to installed: restore the sidecar.
    if [ -z "$sd_ver" ] && [ -f "$YT_BASE" ] && [ -f "$YT_SPLIT" ] && \
       [ -n "$split" ] && \
       [ "$(sha256sum "$YT_BASE" | cut -d' ' -f1)" = \
         "$(sha256sum "$base" | cut -d' ' -f1)" ] && \
       [ "$(sha256sum "$YT_SPLIT" | cut -d' ' -f1)" = \
         "$(sha256sum "$split" | cut -d' ' -f1)" ]; then
        printf '%s %s\n' "$inst_ver" "$(sha256sum "$YT_BASE" | cut -d' ' -f1)" \
            > "$YT_VER.tmp.$$" && mv -f "$YT_VER.tmp.$$" "$YT_VER"
        chmod 644 "$YT_VER" 2>/dev/null || true
        yt_log "sdcard YouTube matches installed; sidecar restored"
        return 0
    fi

    # No/invalid sidecar: keep a timestamp-newer sdcard APK (user-provided),
    # but only if its split is present too.
    if [ -z "$sd_ver" ] && [ -f "$YT_BASE" ] && [ -f "$YT_SPLIT" ] && \
       [ "$(stat -c %Y "$YT_BASE" 2>/dev/null || echo 0)" -gt \
         "$(stat -c %Y "$base" 2>/dev/null || echo 0)" ]; then
        yt_log "sdcard YouTube is newer by mtime; keeping payload"
        return 0
    fi

    tmpb="$YT_BASE.tmp.$$"
    tmps="$YT_SPLIT.tmp.$$"
    if ! cp "$base" "$tmpb" 2>/dev/null; then
        rm -f "$tmpb" "$tmps"
        yt_log "copy YouTube base to sdcard failed"
        return 0
    fi
    if [ -n "$split" ]; then
        if ! cp "$split" "$tmps" 2>/dev/null; then
            rm -f "$tmpb" "$tmps"
            yt_log "copy YouTube split to sdcard failed"
            return 0
        fi
    fi
    chmod 660 "$tmpb" 2>/dev/null || true
    [ -n "$split" ] && chmod 660 "$tmps" 2>/dev/null || true
    chown root:everybody "$tmpb" 2>/dev/null || true
    [ -n "$split" ] && chown root:everybody "$tmps" 2>/dev/null || true

    mv -f "$tmpb" "$YT_BASE" || { rm -f "$tmpb" "$tmps"; return 0; }
    if [ -n "$split" ]; then
        mv -f "$tmps" "$YT_SPLIT" || { rm -f "$tmps" "$YT_BASE"; return 0; }
    else
        rm -f "$YT_SPLIT"
    fi
    printf '%s %s\n' "$inst_ver" "$(sha256sum "$YT_BASE" | cut -d' ' -f1)" \
        > "$YT_VER.tmp.$$" && mv -f "$YT_VER.tmp.$$" "$YT_VER"
    chmod 644 "$YT_VER" 2>/dev/null || true
    sync
    yt_log "copied YouTube $inst_ver to sdcard payload"
}

sync_youtube_payload

# Used by preinstall-apps.sh after YouTube was just installed on first boot:
# do the payload sync and exit without touching addon markers/reboot.
if [ "${YOUTUBE_SYNC_ONLY:-0}" = "1" ]; then
    exit 0
fi

if [ -z "$PAYLOAD" ]; then
    rm -f "$MARKER"
    echo "$LOG_TAG: payload not found, nothing to do" | log -t "$LOG_TAG" -p i
    exit 0
fi

if [ -f /system/lib64/libndk_translation.so ] && \
   [ -f /system/vendor/bin/hw/android.hardware.drm-service-lazy.widevine ]; then
    # Компоненты на месте — маркер не нужен.
    rm -f "$MARKER"
    exit 0
fi

attempts=$(cat "$ATTEMPTS_FILE" 2>/dev/null || echo 0)
if [ "$attempts" -ge 3 ]; then
    echo "$LOG_TAG: already tried $attempts times, not rebooting (check payload)" | \
        log -t "$LOG_TAG" -p w
    exit 0
fi

# The reboot into recovery is silent.  On a first boot after an OTA show a
# readable message from the add-on app (base system) and give the user a few
# seconds before rebooting.  If the app is missing (older image), just reboot.
if [ -x /system/bin/am ] && /system/bin/pm path org.los.tv.addon >/dev/null 2>&1; then
    if /system/bin/am start --user 0 -n org.los.tv.addon/.RebootActivity >/dev/null 2>&1; then
        sleep 4
    fi
fi

echo "$LOG_TAG: components missing ($PAYLOAD), scheduling recovery install (attempt $((attempts + 1)))" | \
    log -t "$LOG_TAG" -p i
echo $((attempts + 1)) > "$ATTEMPTS_FILE"
sync
touch "$MARKER" 2>/dev/null
sync
# setprop, а не reboot: init в этот момент занят нашим exec и обработает
# sys.powerctl сразу после возврата.
setprop sys.powerctl reboot
