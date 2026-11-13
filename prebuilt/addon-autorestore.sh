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

echo "$LOG_TAG: components missing ($PAYLOAD), scheduling recovery install (attempt $((attempts + 1)))" | \
    log -t "$LOG_TAG" -p i
echo $((attempts + 1)) > "$ATTEMPTS_FILE"
sync
touch "$MARKER" 2>/dev/null
sync
# setprop, а не reboot: init в этот момент занят нашим exec и обработает
# sys.powerctl сразу после возврата.
setprop sys.powerctl reboot
