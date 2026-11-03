#!/system/bin/sh
# Android TV: сообщение в шторке уведомлений, если телевизор не принял
# физический режим, который просили (apply-step33).
#
# Зачем отдельный скрипт: уведомление «cmd notification post» из-под root НЕ
# создаётся (система выводит имя пакета из uid: у root получается пакет «root»,
# которого нет), а TV-панель рисует только уведомления с Notification.TvExtender
# (флаг -T у «cmd notification post», apply-step32). Поэтому сообщение показывает
# этот oneshot-сервис, объявленный как `user shell` (uid 2000 = com.android.shell).
#
# Запускается по свойству sys.los_tv.phys_fail, которое поднимает display-fixups
# (root), когда запрошенный режим панели не встал. В свойстве два слова:
#   <что просили> <что реально стало>
#
# Текст согласован с пользователем: обязательно упоминаем и галочку в меню
# загрузчика, и ручную правку /boot/grub/tvres.cfg (кто правил файл руками,
# галочек не трогал и иначе не поймёт, что делать).
#
# См. STATE.md, scripts/apply-step33.py.

MSG=$(/system/bin/getprop sys.los_tv.phys_fail)
if [ -z "$MSG" ]; then
    exit 0
fi

WANT=${MSG%% *}
ACTIVE=${MSG##* }
[ "$ACTIVE" = "$WANT" ] && ACTIVE="неизвестен"

TEXT="$WANT не поддерживается этим ТВ (активен $ACTIVE). Чтобы это сообщение не появлялось: снимите галочку «менять физический режим» в меню загрузчика или пропишите валидное разрешение в /boot/grub/tvres.cfg."

/system/bin/log -t tvres-notify "показываю: $TEXT"
/system/bin/cmd notification post -T -S bigtext -t "Физическое разрешение" los-tv-phys "$TEXT"
exit 0
