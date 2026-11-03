#!/system/bin/sh
# Включает check-in microG при первой загрузке (одноразово).
# Причина: дефолт checkin_enable_service в microG — false → android-id=0 →
# Play Store «Cannot sync with 0 Android ID». См. STATE.md / apply-step24.py.
# Выполняется от root (init, user root): permission WRITE_SETTINGS
# protectionLevel=signature — обычным uid недоступен.
FLAG=/data/misc/checkin-enabler.done
URI=content://com.google.android.gms.microg.settings/check-in

[ -e "$FLAG" ] && exit 0

# Ждём провайдер microG (после boot_completed он поднимается ещё до секунд).
enabled=""
i=0
while [ $i -lt 30 ]; do
    enabled=$(/system/bin/content query --uri "$URI" --projection checkin_enable_service 2>/dev/null | /system/bin/grep -o "checkin_enable_service=[01]")
    [ -n "$enabled" ] && break
    /system/bin/sleep 2
    i=$((i+1))
done

[ -z "$enabled" ] && exit 1

if [ "$enabled" = "checkin_enable_service=0" ]; then
    /system/bin/content update --uri "$URI" --bind checkin_enable_service:i:1 || exit 1
    /system/bin/am broadcast -n com.google.android.gms/org.microg.gms.checkin.TriggerReceiver >/dev/null 2>&1
fi

touch "$FLAG"
exit 0
