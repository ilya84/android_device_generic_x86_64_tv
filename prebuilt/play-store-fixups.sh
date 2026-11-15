#!/system/bin/sh
# Play Store: appop ACTIVATE_VPN. Без него установка приложений из магазина
# зависает на «Подождите…» — в логе падает DownloadService.
#
# Почему: DownloadService объявляет foregroundServiceType=systemExempted, а
# политика платформы (frameworks/base/core/java/android/app/
# ForegroundServiceTypePolicy.java, FGS_TYPE_POLICY_SYSTEM_EXEMPTED) требует
# право FOREGROUND_SERVICE_SYSTEM_EXEMPTED И одно из:
#     SCHEDULE_EXACT_ALARM | USE_EXACT_ALARM | appop ACTIVATE_VPN=MODE_ALLOWED
# Alarm-прав APK Play Store не объявляет вовсе (проверено aapt2 по всем
# вариантам 53.4.17: -34, -24 и base.apk из .apkm), выдать необъявленное право
# нельзя (privapp-allowlist и pm grant работают только с запрошенными), а
# дефолт OP_ACTIVATE_VPN — MODE_IGNORED. Значит достижима ровно одна ручка —
# этот appop. Проверено вживую: с ним VLC скачался и установился.
#
# Выполняется КАЖДУЮ загрузку (не один раз): appop сбрасывается при
# `pm clear com.android.vending` и при восстановлении /data из бэкапа, поэтому
# одноразовый флаг-файл такой сброс бы не заметил.
#
# См. STATE.md и scripts/apply-step27.py.

PKG=com.android.vending
OP=ACTIVATE_VPN

/system/bin/appops set "$PKG" "$OP" allow
rc=$?

state=$(/system/bin/appops get "$PKG" "$OP" 2>/dev/null)
state=${state:-нет-ответа}

if [ "$rc" = "0" ]; then
    /system/bin/log -t play-store-fixups "appop $OP=allow (rc=0; appops get: $state)"
else
    /system/bin/log -t play-store-fixups "ОШИБКА: appops set $PKG $OP allow → rc=$rc (appops get: $state)"
fi

exit "$rc"
