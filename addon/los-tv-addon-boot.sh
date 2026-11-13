#!/system/bin/sh
#
# los-tv: драйвер установки проприетарных компонентов из recovery.
#
# Запускается из init.recovery.sh, если:
#   * GRUB передал androidboot.los_tv_addon=1 (пункт меню «Установить
#     проприетарные компоненты»), или
#   * в /sdcard/los-tv-proprietary лежит .install-request (плитка в Android).
#
# Что делает:
#   * компоненты уже установлены и есть только APK — добавляет Play Store /
#     YouTube TV в АКТИВНЫЙ слот (без клонирования и без переключения);
#   * есть образы или готовый payload — полная установка: клонирование в
#     неактивный слот (обычный режим) либо на месте в активный (post-OTA,
#     маркер addon-pending);
#   * файлов нет — показывает на экране, чего не хватает, оставляет маркер
#     для Android и перезагружается в систему.
#
# Логи и экран — как раньше: всё пишется в /mnt/cdrom/los-tv-addon.log.

set -u

# Ранняя диагностика: до монтирования data-раздела писать в лог некуда.
echo "los-tv-addon-boot: start" > /dev/kmsg

CDROM=/mnt/cdrom
LOG=$CDROM/los-tv-addon.log
ADDON=/system/bin/los-tv-addon.sh
ASSETS=/system/etc/los-tv-addon
WORK=$CDROM/los-tv-addon-work
PAYLOAD=$CDROM/los-tv-proprietary.tar.gz
USERDIR=$CDROM/data/media/0/los-tv-proprietary
APPDIR=$CDROM/data/media/0/Android/data/org.los.tv.addon/files
REQFILE=$USERDIR/.install-request
NEEDSFILE=$CDROM/boot/grub/addon-needs-files
CFG=$CDROM/boot/grub/android.cfg

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') addon-boot: $*"; }
die() { log "ОШИБКА: $*"; finish 1; }

finish() {
    log "завершено, код $1; перезагрузка"
    # Успешная установка сбрасывает счётчик попыток автовосстановления.
    if [ "$1" = "0" ]; then
        rm -f "$CDROM/boot/grub/addon-attempts"
        rm -f "$NEEDSFILE"
    fi
    # Возвращаем GRUB в обычный режим: recovery.bms.sh в recovery не
    # запускается (sys.shutdown.requested выставляет только Android), поэтому
    # после reboot("recovery") из приложения MODE мог остаться recovery —
    # тогда следующая загрузка снова ушла бы в recovery без флагов.
    if [ -f "$CDROM/boot/grub/android.cfg" ]; then
        sed -i 's/^MODE=.*/MODE=normal/' "$CDROM/boot/grub/android.cfg" 2>/dev/null
    fi
    sync
    sleep 2
    reboot
}

# data-раздел (в нём лежат образы слотов и сюда кладёт файлы пользователь)
if [ ! -e "$CDROM/system_a.img" ]; then
    mkdir -p "$CDROM"
    mount -t ext4 /dev/block/by-name/cdrom "$CDROM" || {
        echo "addon-boot: не удалось смонтировать /dev/block/by-name/cdrom" > /dev/kmsg
        reboot
        exit 1
    }
fi
echo "los-tv-addon-boot: cdrom mounted" > /dev/kmsg

# Чистим BCB (misc): мы останавливаем recovery раньше, чем его main успевает
# это сделать, иначе после установки устройство снова уйдёт в recovery —
# уже без флага los_tv_addon (проверено 2026-11-01).
if [ -e /dev/block/by-name/misc ]; then
    dd if=/dev/zero of=/dev/block/by-name/misc bs=1 count=2048 2>/dev/null
fi

# Маркер автозапуска означает post-OTA: ставим компоненты НА МЕСТЕ в активный
# слот, не клонируя его поверх рабочего бэкапа в другом слоте.
INPLACE=0
[ -f "$CDROM/boot/grub/addon-pending" ] && INPLACE=1
rm -f "$CDROM/boot/grub/addon-pending"

# Запрос из приложения-плитки (Android). Убираем сразу: повторный запуск
# должен требовать нового действия пользователя.
REQUESTED=0
[ -f "$REQFILE" ] && REQUESTED=1
rm -f "$REQFILE"

exec >> "$LOG" 2>&1

msg() { /system/bin/los-tv-msg "$@" >/dev/null 2>&1 || true; }

stop recovery 2>/dev/null
sleep 2

log "=== старт установки проприетарных компонентов (inplace=$INPLACE, request=$REQUESTED)"

# Куда пользователь может положить файлы (и куда качает приложение).
SRC_DIRS="$USERDIR
$APPDIR
$CDROM/data/media/0/Download
$CDROM/los-tv-proprietary
$CDROM/data/local/tmp/los-tv-proprietary
/data/los-tv-proprietary"

# find_first <glob>... — первый подходящий файл в любом из SRC_DIRS.
find_first() {
    local d pat f
    for d in $SRC_DIRS; do
        for pat in "$@"; do
            for f in "$d"/$pat; do
                if [ -f "$f" ]; then
                    printf '%s\n' "$f"
                    return 0
                fi
            done
        done
    done
    return 1
}

slot_has_components() {
    local s img dev ok
    s=$1
    [ -n "$s" ] || return 1
    img="$CDROM/system_$s.img"
    [ -f "$img" ] || return 1
    dev=$(losetup -f 2>/dev/null) || return 1
    losetup -r "$dev" "$img" 2>/dev/null || return 1
    mkdir -p /mnt/los-tv-check
    if mount -t ext4 -o ro "$dev" /mnt/los-tv-check 2>/dev/null; then
        ok=1
        [ -f /mnt/los-tv-check/system/lib64/libndk_translation.so ] || ok=0
        [ -f /mnt/los-tv-check/system/vendor/bin/hw/android.hardware.drm-service-lazy.widevine ] || ok=0
        umount /mnt/los-tv-check 2>/dev/null
        losetup -d "$dev" 2>/dev/null
        [ "$ok" = "1" ] && return 0
        return 1
    fi
    losetup -d "$dev" 2>/dev/null
    return 1
}

stage_apks() {
    rm -rf "$WORK/apks"
    mkdir -p "$WORK/apks" || die "не удалось создать $WORK/apks"
    [ -n "$PLAYAPK" ] && ln -sf "$PLAYAPK" "$WORK/apks/$(basename "$PLAYAPK")"
    [ -n "$YTAPK" ] && ln -sf "$YTAPK" "$WORK/apks/$(basename "$YTAPK")"
    [ -n "$YTSPLIT" ] && ln -sf "$YTSPLIT" "$WORK/apks/YouTubeTV-split_config.arm64_v8a.apk"
    return 0
}

show_missing() {
    # $@ — что не найдено (строки для экрана)
    msg --reset "Files for proprietary components not found" \
        "Missing:" \
        "$@" \
        "Copy them to /sdcard/los-tv-proprietary" \
        "or use the add-on tile in Android." \
        "Rebooting to Android in 20 seconds..."
    {
        echo "time=$(date '+%F %T')"
        for m in "$@"; do echo "missing: $m"; done
    } > "$NEEDSFILE" 2>/dev/null
    sync
    log "файлов нет: $*"
    sleep 20
    log "перезагрузка в Android для загрузки файлов"
    reboot
}

active=$(sed -n 's/^SLOT=_\([ab]\)$/\1/p' "$CFG" 2>/dev/null | head -1)
[ -n "$active" ] || active=$(getprop ro.boot.slot_suffix | tr -d '_')
log "активный слот: _${active:-?}"

# Тип образа определяем по СОДЕРЖИМОМУ архива, а не по имени файла:
# ChromeOS recovery содержит .bin, google_apis — system.img.
find_all() {
    local d pat f
    for d in $SRC_DIRS; do
        for pat in "$@"; do
            for f in "$d"/$pat; do
                [ -f "$f" ] && printf '%s\n' "$f"
            done
        done
    done
}

CHROMEOS=
GA=
for z in $(find_all "*.zip"); do
    if unzip -l "$z" 2>/dev/null | grep -qE '\.bin$'; then
        [ -z "$CHROMEOS" ] && CHROMEOS=$z
    elif unzip -l "$z" 2>/dev/null | grep -qE '(^|/)system\.img$'; then
        [ -z "$GA" ] && GA=$z
    fi
done
[ -n "$CHROMEOS" ] && log "ChromeOS (по содержимому): $CHROMEOS"
[ -n "$GA" ] && log "google_apis (по содержимому): $GA"
PLAYAPK=$(find_first 'PlayStore-TV.apk' '*vending*.apk' '*PlayStore*.apk' || true)
YTAPK=$(find_first 'YouTube-TV.apk' '*youtube.tv*.apkm' '*youtube.tv*.apk' 'YouTube*.apk' || true)
YTSPLIT=$(find_first 'YouTubeTV-split_config.arm64_v8a.apk' '*-split_config.arm64_v8a.apk' || true)

[ -n "$CHROMEOS" ] && log "ChromeOS: $CHROMEOS"
[ -n "$GA" ] && log "google_apis: $GA"
[ -n "$PLAYAPK" ] && log "Play Store APK: $PLAYAPK"
[ -n "$YTAPK" ] && log "YouTube TV APK: $YTAPK"
[ -n "$YTSPLIT" ] && log "YouTube TV split: $YTSPLIT"
[ -z "$YTSPLIT" ] && log "ВНИМАНИЕ: YouTube TV split не найден"
[ -f "$PAYLOAD" ] && log "payload: $PAYLOAD"

COMP=0
if slot_has_components "$active"; then
    COMP=1
fi
# Отладочный обход проверки слота (для тестов сценария «файлов нет»).
[ "${LOSTV_ADDON_ASSUME_MISSING:-0}" = "1" ] && COMP=0
log "компоненты в активном слоте: $COMP"

# --- Компоненты уже стоят: только APK --------------------------------------
# Образы в этом случае игнорируем: они нужны лишь тогда, когда компонентов
# ещё нет. Так плитка «Добавить приложения» не запускает 20-минутный клон.
INSTALLED_YT=
for d in /data/app/*/com.google.android.youtube.tv-* \
         /data/app/com.google.android.youtube.tv-*; do
    [ -d "$d" ] || continue
    if [ -f "$d/base.apk" ]; then
        INSTALLED_YT=1
        break
    fi
done
if [ "$COMP" = "1" ]; then
    if [ -n "$PLAYAPK" ] || [ -n "$YTAPK" ] || [ "$INSTALLED_YT" = "1" ]; then
        mkdir -p "$WORK"
        stage_apks
        msg --reset "Adding apps (Play Store / YouTube TV)" \
            "Components already installed." \
            "This takes about a minute."
        log "режим только-APK"
        INPLACE=1 SKIP_COMPONENTS=1 APK_ONLY=1 ADDON_SRC="$WORK/apks" \
            ASSETS="$ASSETS" WORK="$WORK" \
            sh "$ADDON" install "$WORK/out" other || die "не удалось добавить APK"
        log "APK добавлены в активный слот _$active"
        finish 0
    fi

    msg --reset "Components already installed" \
        "No APK files found to add." \
        "Put Play Store / YouTube TV APKs into" \
        "/sdcard/los-tv-proprietary." \
        "Rebooting in 10 seconds..."
    # Вернуть плитку в Android: пользователь запустил установщик, но файлов
    # нет. check-сервис включит плитку и покажет уведомление.
    {
        echo "time=$(date '+%F %T')"
        echo "missing: APK Play Store / YouTube TV"
    } > "$NEEDSFILE" 2>/dev/null
    sync
    log "компоненты уже стоят, добавлять нечего; плитка будет возвращена"
    sleep 10
    finish 0
fi

# --- Нет ни образов, ни payload: показать, чего не хватает -----------------
if [ "$COMP" = "0" ] && [ ! -f "$PAYLOAD" ] && \
   { [ -z "$CHROMEOS" ] || [ -z "$GA" ]; }; then
    M1="ChromeOS image: OK"
    [ -z "$CHROMEOS" ] && M1="ChromeOS image: MISSING"
    M2="google_apis image: OK"
    [ -z "$GA" ] && M2="google_apis image: MISSING"
    show_missing "$M1" "$M2"
fi

# --- Полная установка -------------------------------------------------------
[ -x "$ADDON" ] || [ -f "$ADDON" ] || die "нет $ADDON в recovery"
[ -d "$ASSETS" ] || die "нет $ASSETS в recovery"

set -- $(df -k "$CDROM" | tail -1)
log "свободно на $CDROM: $4 КБ"

if [ "$INPLACE" = "1" ]; then
    EST_TIME="This takes 1-3 minutes (post-OTA)."
else
    EST_TIME="This takes 20-30 minutes."
fi
msg --reset "Installing proprietary components" \
    "$EST_TIME" \
    "Do not power off."

mkdir -p "$WORK" || die "не удалось создать $WORK"

if [ -n "$CHROMEOS" ] && [ -n "$GA" ]; then
    ASSETS="$ASSETS" WORK="$WORK" sh "$ADDON" extract "$CHROMEOS" "$GA" "$WORK/out" || \
        die "извлечение компонентов не удалось (см. лог выше)"
else
    # payload уже проверен и используется вместо 10 ГБ образов
    ASSETS="$ASSETS" WORK="$WORK" sh "$ADDON" extract "" "" "$WORK/out" || \
        die "восстановление из payload не удалось (см. лог выше)"
fi

stage_apks

ASSETS="$ASSETS" WORK="$WORK" ADDON_SRC="$WORK/apks" INPLACE="$INPLACE" \
    sh "$ADDON" install "$WORK/out" other || \
    die "установка в слот не удалась (см. лог выше)"

if [ "$INPLACE" = "1" ]; then
    log "успех: компоненты установлены на месте в активный слот _$active (post-OTA)"
else
    log "успех: компоненты установлены, слот переключён"
fi
finish 0
