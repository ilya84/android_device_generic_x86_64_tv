#!/system/bin/sh
# Android TV: базовое разрешение кадра (1080p/720p) + необязательная смена
# физического режима телевизора.
#
# История: step28 (сборка №18) — стандартный кадр 1920x1080@320 вместо «сырого»
# режима панели; step33 (сборка №22) — выбор пользователя (androidboot.tvres /
# androidboot.physres из /boot/grub/tvres.cfg) + уведомление в шторке;
# step36 (сборка №25) — порядок шагов и проверка, что кадр РЕАЛЬНО выводится.
#
# Зачем step36 (разбор: STATE.md, «ИНЦИДЕНТ … 720p + PHYSRES=1»,
# data/2026-10-19-phys720-black-screen-incident.txt):
#   1) 2026-10-19 на связке i915(Haswell) + drm_hwc + ТВ (EDID 2012) повтор 720p
#      с галочкой дал ЧЁРНЫЙ ЭКРАН: фреймворк отчитался «режим встал», а композер
#      не мог вывести кадр (E/drmhwc: Failed to commit pset ret=-22 EINVAL,
#      SurfaceFlinger: present failed BAD_PARAMETER). Ядро отклоняет
#      масштабирование основной плоскости (i915: invalid scaling 1920x1080 -> …),
#      а кадр в момент смены не совпадал с новым режимом. Поэтому теперь СНАЧАЛА
#      выставляется кадр, и только потом меняется режим панели: переход идёт
#      «один к одному» и запросов планарного масштабирования не возникает.
#   2) Одной проверки «режим встал» мало — она смотрит только на данные
#      фреймворка. Добавлена проверка ВЫВОДА: до и после смены считается число
#      ошибок вывода в логе (drm_hwc + SurfaceFlinger). Выросло — режим
#      откатывается назад, галочка снимается (PHYSRES=0), в шторку уходит
#      уведомление. В рабочей загрузке счётчик равен нулю, в трёх ручных
#      переключениях режима прироста не было — сигнал чистый.
#   3) Мелочь: если кадр совпадает с «сырым» режимом панели, `wm size` не печатает
#      строку Override — теперь читаем и Physical, иначе в лог попадало ложное
#      «!! кадр получился @».
#
# Что делает этот запуск:
#   1) валидирует запрос по белому списку (мусор → 1080p, как раньше);
#   2) выставляет логическое разрешение и плотность (wm size / wm density);
#   3) при physres=1 просит DisplayManager сменить РЕЖИМ ПАНЕЛИ на тот же размер
#      (cmd display set-user-preferred-display-mode, без сохранения в настройках),
#      затем проверяет и данные фреймворка, и счётчик ошибок вывода; при неудаче
#      откатывает режим и поднимает sys.los_tv.phys_fail, по которому shell-сервис
#      tvres-notify показывает уведомление в шторке ТВ;
#   4) персистит выбор в /boot/grub/tvres.cfg — загрузчик записать файл не может,
#      поэтому это делает Android после удачной загрузки.
#
# Матрица (замерено на YouTube TV 7.25.302, 2026-10-17):
#     1920x1080 @320 — правильно (эталон)    1280x720 @213 — правильно
#     любой 1366x768 — сломана вёрстка;  1366x768 @320 — приложение виснет.
#
# Если ключей в строке загрузки нет (старый загрузчик, recovery) — работаем
# по-старому (1080p @ 320) и файл НЕ трогаем, чтобы не затереть выбор молча.
#
# Скрипт идемпотентен (~40 мс, если всё уже выставлено) — см. step28.
# См. STATE.md, scripts/apply-step28.py, apply-step33.py, apply-step36.py.

TVRES_FILE=/boot/grub/tvres.cfg
LOGT="display-fixups"

log() { /system/bin/log -t "$LOGT" "$1"; }

# режим панели, который сейчас на самом деле (первый activeMode — встроенный экран)
active_size() {
    /system/bin/dumpsys SurfaceFlinger 2>/dev/null \
        | /system/bin/grep activeMode | /system/bin/head -1 \
        | /system/bin/sed 's/.*resolution=//; s/,.*//'
}

# число ошибок ВЫВОДА кадра в логе текущей загрузки (drm_hwc + SurfaceFlinger).
# Растущий счётчик = кадр не доходит до экрана (инцидент 2026-10-19).
present_errors() {
    a=$(/system/bin/logcat -d -s drmhwc 2>/dev/null | /system/bin/grep -c "Failed to commit pset")
    b=$(/system/bin/logcat -d -s SurfaceFlinger 2>/dev/null | /system/bin/grep -c "present failed")
    echo $(( ${a:-0} + ${b:-0} ))
}

# ---------- 1. запрос из строки загрузки + белый список ---------------------
REQ_TVRES=$(/system/bin/getprop ro.boot.tvres)
REQ_PHYSRES=$(/system/bin/getprop ro.boot.physres)
FROM_LOADER=0
[ -n "$REQ_TVRES" ] && FROM_LOADER=1

case "$REQ_TVRES" in
    720p) WANT_TVRES=720p;  WANT_SIZE=1280x720;  WANT_DENSITY=213 ;;
    *)    WANT_TVRES=1080p; WANT_SIZE=1920x1080; WANT_DENSITY=320 ;;
esac
case "$REQ_PHYSRES" in
    1) WANT_PHYS=1 ;;
    *) WANT_PHYS=0 ;;
esac

log "запрос: tvres=${REQ_TVRES:-нет} physres=${REQ_PHYSRES:-нет} -> $WANT_TVRES (размер $WANT_SIZE @ $WANT_DENSITY, физ. режим: $WANT_PHYS)"
if [ "$FROM_LOADER" = "0" ]; then
    log "ключей в строке загрузки нет — работаю по умолчанию, $TVRES_FILE не трогаю"
fi

# ---------- 2. логическое разрешение и плотность ----------------------------
# ВАЖНО (step36): этот блок идёт ДО смены физического режима. Режим меняется,
# когда кадр уже нужного размера, поэтому композер не просит у драйвера
# масштабирования основной плоскости (i915 его не умеет — см. инцидент).
cur_size=$(/system/bin/wm size 2>/dev/null | /system/bin/sed -n 's/.*Override size: //p')
[ -n "$cur_size" ] || cur_size=$(/system/bin/wm size 2>/dev/null | /system/bin/sed -n 's/.*Physical size: //p')
cur_density=$(/system/bin/wm density 2>/dev/null | /system/bin/sed -n 's/.*Override density: //p')
[ -n "$cur_density" ] || cur_density=$(/system/bin/wm density 2>/dev/null | /system/bin/sed -n 's/.*Physical density: //p')
[ "$cur_size" = "$WANT_SIZE" ] || /system/bin/wm size "$WANT_SIZE"
[ "$cur_density" = "$WANT_DENSITY" ] || /system/bin/wm density "$WANT_DENSITY"
new_size=$(/system/bin/wm size 2>/dev/null | /system/bin/sed -n 's/.*Override size: //p')
[ -n "$new_size" ] || new_size=$(/system/bin/wm size 2>/dev/null | /system/bin/sed -n 's/.*Physical size: //p')
new_density=$(/system/bin/wm density 2>/dev/null | /system/bin/sed -n 's/.*Override density: //p')
[ -n "$new_density" ] || new_density=$(/system/bin/wm density 2>/dev/null | /system/bin/sed -n 's/.*Physical density: //p')
if [ "$new_size" = "$WANT_SIZE" ] && [ "$new_density" = "$WANT_DENSITY" ]; then
    log "кадр: $new_size @ $new_density"
else
    log "!! кадр получился $new_size @ $new_density, просили $WANT_SIZE @ $WANT_DENSITY"
fi

# ---------- 3. физический режим панели --------------------------------------
PHYS_FAILED=0
if [ "$WANT_PHYS" = "1" ]; then
    WANT_W=${WANT_SIZE%x*}
    WANT_H=${WANT_SIZE#*x}
    cur_active=$(active_size)
    if [ "$cur_active" = "$WANT_SIZE" ]; then
        log "физический режим уже $cur_active — не трогаю"
    else
        err_before=$(present_errors)
        log "прошу физический режим $WANT_SIZE (сейчас ${cur_active:-?}; ошибок вывода до смены: ${err_before:-?})"
        /system/bin/cmd display set-user-preferred-display-mode "$WANT_W" "$WANT_H" 60 0 false
        /system/bin/sleep 3
        new_active=$(active_size)
        err_after=$(present_errors)
        if [ "$new_active" = "$WANT_SIZE" ] && [ "${err_after:-0}" -le "${err_before:-0}" ]; then
            log "физический режим встал: $new_active (кадр выводится, ошибок вывода ${err_after:-?})"
        else
            PHYS_FAILED=1
            log "физический режим $WANT_SIZE не подтвердился (активен ${new_active:-?}, ошибок вывода было ${err_before:-?}, стало ${err_after:-?}) — откатываю режим и сообщаю в шторку"
            case "$cur_active" in
                *x*)
                    /system/bin/cmd display set-user-preferred-display-mode "${cur_active%x*}" "${cur_active#*x}" 60 0 false
                    /system/bin/sleep 2
                    ;;
            esac
            back_active=$(active_size)
            /system/bin/setprop sys.los_tv.phys_fail "$WANT_SIZE ${back_active:-${cur_active:-?}}"
        fi
    fi
fi

# ---------- 4. персист выбора в /boot/grub/tvres.cfg ------------------------
if [ "$FROM_LOADER" = "1" ]; then
    NEW_TVRES=$WANT_TVRES
    NEW_PHYSRES=$WANT_PHYS
    [ "$PHYS_FAILED" = "1" ] && NEW_PHYSRES=0
    old_tvres=$(/system/bin/sed -n 's/^set TVRES=//p' "$TVRES_FILE" 2>/dev/null | /system/bin/head -1)
    old_phys=$(/system/bin/sed -n 's/^set PHYSRES=//p' "$TVRES_FILE" 2>/dev/null | /system/bin/head -1)
    if [ "$old_tvres" = "$NEW_TVRES" ] && [ "$old_phys" = "$NEW_PHYSRES" ]; then
        log "$TVRES_FILE уже такой: TVRES=$NEW_TVRES PHYSRES=$NEW_PHYSRES"
    else
        /system/bin/printf '%s\n' \
            '# los-tv: базовое разрешение кадра (выбор пользователя).' \
            '# Читает загрузчик (/boot/grub/grub.cfg), а после удачной загрузки' \
            '# перезаписывает Android (сервис display-fixups) — править можно и руками.' \
            '# Допустимые значения: TVRES=1080p|720p, PHYSRES=0|1' \
            "set TVRES=$NEW_TVRES" \
            "set PHYSRES=$NEW_PHYSRES" > "$TVRES_FILE.new"
        if /system/bin/mv -f "$TVRES_FILE.new" "$TVRES_FILE" 2>/dev/null; then
            log "$TVRES_FILE обновлён: TVRES=$NEW_TVRES PHYSRES=$NEW_PHYSRES (было ${old_tvres:-?}/${old_phys:-?})"
        else
            /system/bin/rm -f "$TVRES_FILE.new"
            log "!! не смог записать $TVRES_FILE (осталось ${old_tvres:-?}/${old_phys:-?})"
        fi
    fi
fi

exit 0
