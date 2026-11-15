#!/system/bin/sh
# los-tv: TV-уведомление «нужны файлы для компонентов» (2026-11-01).
#
# Запускается как user shell (как tvres-notify): «cmd notification post»
# из-под root не создаёт уведомление, а TV-панель рисует только уведомления
# с TvExtender (флаг -T).

TEXT="Для установки компонентов или добавления приложений нужны файлы. Откройте плитку «Проприетарные компоненты»: там ссылки на APK и автоматическая загрузка образов."

log -t los-tv-addon "показываю уведомление"
cmd notification post -T -S bigtext -t "Проприетарные компоненты" los-tv-addon "$TEXT"
setprop sys.los_tv.addon_needed 0
