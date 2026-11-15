#!/system/bin/sh
# los-tv: recover Bluetooth after the USB HCI adapter is re-enumerated.
#
# Android's Bluetooth stack can keep a stale HOGP/HID "connected" state when
# the USB dongle disappears and comes back (e.g. a pet touches it): the old
# HCI fd is dead, but the stack never re-opens the new /dev/hciX.  Watch the
# USB Bluetooth interface (class E0/01/01) and toggle Bluetooth when its
# device number changes, so the stack re-binds to the fresh adapter.
#
# Disable at runtime with: setprop persist.sys.bt_hotplug 0

TAG=bt_hotplug

log() {
    echo "$TAG: $*" > /dev/kmsg 2>/dev/null
}

# 1 when Bluetooth is enabled in the framework.
bt_enabled() {
    /system/bin/timeout 10 /system/bin/dumpsys bluetooth_manager 2>/dev/null \
        | /system/bin/grep -m1 'enabled:' | /system/bin/grep -q 'true'
}

# 1 when the user wants Bluetooth on.  Never override a manual "off".
bt_wanted() {
    [ "$(/system/bin/timeout 10 /system/bin/settings get global bluetooth_on 2>/dev/null)" != "0" ]
}

# "hciN:inode:ctime" for every registered HCI device.  The kernel destroys
# and re-creates the hciN kobject when the USB adapter is re-enumerated, so
# its inode changes even if the USB device number happens to be reused.
adapter_state() {
    _out=
    for _h in /sys/class/bluetooth/hci*; do
        [ -e "$_h" ] || continue
        _st=$(/system/bin/stat -c '%i:%Z' "$_h" 2>/dev/null)
        [ -n "$_st" ] || continue
        _out="$_out $(/system/bin/basename "$_h"):$_st"
    done
    echo "$_out"
}

restart_bt() {
    if ! bt_wanted; then
        log "adapter changed but Bluetooth is off by user; skipping"
        return
    fi
    log "USB Bluetooth adapter re-enumerated; restarting Bluetooth"
    /system/bin/timeout 20 /system/bin/cmd bluetooth_manager disable >/dev/null 2>&1
    _i=0
    while bt_enabled && [ "$_i" -lt 15 ]; do
        /system/bin/sleep 1
        _i=$((_i + 1))
    done
    /system/bin/sleep 2
    /system/bin/timeout 20 /system/bin/cmd bluetooth_manager enable >/dev/null 2>&1
    _i=0
    while ! bt_enabled && [ "$_i" -lt 20 ]; do
        /system/bin/sleep 1
        _i=$((_i + 1))
    done
    if bt_enabled; then
        log "Bluetooth restarted"
    else
        log "Bluetooth did not come back"
    fi
}

# Allow disabling the watcher without rebuilding the image.
while [ "$(/system/bin/getprop persist.sys.bt_hotplug 2>/dev/null)" = "0" ]; do
    /system/bin/sleep 30
done

# Wait for the framework, then let the initial adapter enumeration settle.
while [ "$(/system/bin/getprop sys.boot_completed 2>/dev/null)" != "1" ]; do
    /system/bin/sleep 2
done
/system/bin/sleep 10

_base=$(adapter_state)
log "started; baseline:${_base:-<none>}"

while true; do
    /system/bin/sleep 5
    [ "$(/system/bin/getprop persist.sys.bt_hotplug 2>/dev/null)" = "0" ] && continue
    _cur=$(adapter_state)
    [ "$_cur" = "$_base" ] && continue

    log "adapter state:${_base:-<none>} ->${_cur:-<none>}"

    # Wait until the adapter state has been stable for two samples.  The
    # state may pass through <none> while USB re-enumerates; that is still
    # the hot-plug event we want to act on, so do not drop it.
    _stable=0
    _i=0
    while [ "$_stable" -lt 2 ] && [ "$_i" -lt 15 ]; do
        /system/bin/sleep 2
        _now=$(adapter_state)
        if [ "$_now" = "$_cur" ]; then
            _stable=$((_stable + 1))
        else
            _stable=0
            _cur=$_now
        fi
        _i=$((_i + 1))
    done

    _base=$_cur
    [ -n "$_base" ] || continue

    restart_bt

    # The toggle itself may briefly remove/return the HCI device; ignore
    # that churn and start from a fresh baseline.
    /system/bin/sleep 10
    _base=$(adapter_state)
    log "new baseline:${_base:-<none>}"
done
