#!/vendor/bin/sh
#
# los-tv: маркер запрошенного режима загрузки для меню GRUB (2026-11-01).
#
# Запускается init'ом на триггере `shutdown` (через exec, синхронно).
# Источник истины — BCB в разделе misc: init пишет туда "boot-recovery"
# (а для sideload ещё и "--sideload") ДО запуска shutdown-действий, и initrd
# при загрузке читает ровно эти байты. Значит маркер в /boot/grub всегда
# совпадает с тем, куда реально уйдёт следующая загрузка.
#
# initrd удаляет маркеры при старте, поэтому суффикс в заголовке GRUB живёт
# ровно одну загрузку.

GRUBDIR=/boot/grub
[ -f "$GRUBDIR/grub.cfg" ] || GRUBDIR=/mnt/cdrom/boot/grub

SIDE_MARK="$GRUBDIR/mode-sideload"
REC_MARK="$GRUBDIR/mode-recovery"
MISC=/dev/block/by-name/misc

klog() {
    echo "los-tv-boot-mode: $*" > /dev/kmsg 2>/dev/null
}

if [ ! -d "$GRUBDIR" ]; then
    klog "no grub dir ($GRUBDIR), skip"
    exit 0
fi

# Всегда начинаем с чистого состояния: маркеры относятся к одной загрузке.
rm -f "$SIDE_MARK" "$REC_MARK" 2>/dev/null

mode=normal
if [ -r "$MISC" ]; then
    if head -c 1200 "$MISC" 2>/dev/null | grep -q -- "--sideload"; then
        mode=sideload
    elif head -c 1200 "$MISC" 2>/dev/null | grep -q -- "boot-recovery"; then
        mode=recovery
    fi
fi

case "$mode" in
    sideload) touch "$SIDE_MARK" ;;
    recovery) touch "$REC_MARK" ;;
esac

# los-tv: MODE in android.cfg is normally written by boot-mode-selection.sh,
# but that service is triggered by sys.shutdown.requested, which only the
# framework ShutdownThread sets.  CLI paths (adb reboot recovery) bypass it,
# so the GRUB recovery fix (RECOVERY_EXTRA) would not apply.  We already know
# the mode from the BCB, so update android.cfg here as well.
CFG="$GRUBDIR/android.cfg"
if [ -f "$CFG" ] && [ -w "$CFG" ]; then
    sed -i "s/^MODE=.*/MODE=$mode/" "$CFG" 2>/dev/null && \
        klog "android.cfg MODE=$mode"
fi

klog "mode=$mode (grub dir $GRUBDIR)"
sync
