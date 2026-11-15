#!/system/bin/sh
# los-tv: состояние проприетарных компонентов (2026-11-01).
#
# Запускается init-сервисом после sys.boot_completed:
#   * выставляет sys.los_tv.addon_installed / addon_payload (приложение читает);
#   * выдаёт приложению доступ к /sdcard (MANAGE_EXTERNAL_STORAGE);
#   * скрывает плитку, когда компоненты установлены;
#   * если recovery оставил маркер addon-needs-files — возвращает плитку и
#     просит показать уведомление (следующий сервис).

PKG=org.los.tv.addon
ACT=$PKG/.MainActivity

installed=0
if [ -f /system/lib64/libndk_translation.so ] && \
   [ -f /system/vendor/bin/hw/android.hardware.drm-service-lazy.widevine ]; then
    installed=1
fi
setprop sys.los_tv.addon_installed $installed

payload=0
[ -f /mnt/cdrom/los-tv-proprietary.tar.gz ] && payload=1
[ -f /data/los-tv-proprietary.tar.gz ] && payload=1
setprop sys.los_tv.addon_payload $payload

# Приложение скачивает в /sdcard/los-tv-proprietary и пишет LINKS.txt.
cmd appops set $PKG MANAGE_EXTERNAL_STORAGE allow 2>/dev/null
pm grant $PKG android.permission.POST_NOTIFICATIONS 2>/dev/null

log -t los-tv-addon "installed=$installed payload=$payload"

if [ "$installed" = "1" ]; then
    if [ -f /boot/grub/addon-needs-files ]; then
        # Пользователь запустил установщик, но файлов нет (хочет добавить
        # APK или переустановить) — возвращаем плитку.
        rm -f /boot/grub/addon-needs-files
        pm enable $ACT >/dev/null 2>&1
        setprop sys.los_tv.addon_needed 1
    else
        # Компоненты стоят и запроса не было — плитка больше не нужна.
        # disable-user для КОМПОНЕНТА в этом build не работает (ставит
        # enabled), а «pm disable --user» — работает.
        pm disable --user 0 $ACT >/dev/null 2>&1
    fi
    exit 0
fi

# Плитка скрыта пользователем — не трогаем, пока нет нового события
# «файлов не хватает» из recovery.
if [ -f /boot/grub/addon-needs-files ]; then
    rm -f /boot/grub/addon-needs-files
    pm enable $ACT >/dev/null 2>&1
    setprop sys.los_tv.addon_needed 1
fi
