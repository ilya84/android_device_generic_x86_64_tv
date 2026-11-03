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

klog "mode=$mode (grub dir $GRUBDIR)"
sync
