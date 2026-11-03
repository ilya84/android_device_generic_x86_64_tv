#!/system/bin/sh
# Предустановка приложений в /data (2026-10-13; состав — 2026-10-29)
#
# Почему не системными: системное приложение нельзя удалить без
# последствий, его нельзя обновить из внешнего источника, а APK со
# сжатыми .so в /system/app вообще не запускается (PackageManager
# не распаковывает библиотеки системных приложений).
#
# Обычное приложение в /data/app: .so распаковываются автоматически,
# обновление из Play Store/F-Droid работает, удаление не оставляет мусора.
#
# Скрипт выполняется один раз. Уже установленные не трогает: на устройствах,
# обновлённых вручную, приложения и их данные сохраняются.

DIR=/system/etc/preinstall
FLAGDIR=/data/misc/preinstall-apps

# install_app <имя-флага> <package> <apk> [split.apk ...]
#
# Все имена — файлы в /system/etc/preinstall. Base и сплиты ставятся одним
# вызовом: у YouTube/Wink/Кинопоиска в манифесте есть requiredSplitTypes
# (base__abi/base__density), поэтому одиночный base.apk даёт
# INSTALL_FAILED_MISSING_SPLIT.
#
# Android 16: pm install-multiple/install-session-create удалены; список
# файлов передаётся обычному `pm install`.
install_app() {
    name=$1
    pkg=$2
    shift 2

    # Флаг: уже ставили этим скриптом
    [ -f "$FLAGDIR/$name.done" ] && return

    # Уже установлено (пользователем или прошлой установкой) — не трогаем
    if pm path "$pkg" >/dev/null 2>&1; then
        touch "$FLAGDIR/$name.done" 2>/dev/null
        return
    fi

    APKS=""
    MISSING=""
    for f in "$@"; do
        p="$DIR/$f"
        APKS="$APKS $p"
        [ -f "$p" ] || MISSING="$MISSING $p"
    done

    if [ -n "$MISSING" ]; then
        log_preinstall "ОТКАЗ $name: нет файлов$MISSING"
        echo "нет файлов:$MISSING" > "$FLAGDIR/$name.failed" 2>/dev/null
        return
    fi

    log_preinstall "устанавливаю $name ($pkg): $*"
    if OUT=$(pm install -r -g $APKS 2>&1); then
        log_preinstall "OK $name"
        touch "$FLAGDIR/$name.done" 2>/dev/null
    else
        # Отказ фиксируем явно: метка .failed видна после загрузки, по ней
        # приложение можно доставить вручную: pm install -r -g <файлы>
        log_preinstall "ОТКАЗ $name: $OUT"
        echo "$OUT" > "$FLAGDIR/$name.failed" 2>/dev/null
    fi
}

mkdir -p $FLAGDIR 2>/dev/null

# Всё пишем в logcat с тегом "preinstall": иначе отказ не виден нигде.
# ВНИМАНИЕ, здесь была ошибка, стоившая kernel panic (2026-10-14):
#   log() { echo "preinstall: $*" | log -t preinstall -p i; }
# В POSIX-шелле имя внутри тела функции разрешается сначала в функцию, и только
# потом во внешнюю команду — поэтому `log` снова вызывал сам себя. Каждый
# вызов форкал ещё один sh, и на устройстве выросло 1560 процессов, память
# кончилась (свободно 132 МБ из 7778).
# Теперь функция называется иначе и зовёт бинарник по абсолютному пути.
log_preinstall() { echo "preinstall: $*" | /system/bin/log -t preinstall -p i; }

# Ждём готовности package-менеджера (до 2 минут)
i=0
while [ $i -lt 60 ]; do
    cmd package list packages >/dev/null 2>&1 && break
    sleep 2
    i=$((i + 1))
done

# Jellyfin for Android TV (0.19.10, GPL-2.0-or-later): видеоклиент для
# собственного сервера. Работает на x86_64 через Media3/ExoPlayer, то есть
# проверяет штатный MediaCodec-стек без DRM и без Google-компонентов.
install_app JellyfinTV org.jellyfin.androidtv \
    JellyfinTV.apk

# VLC (3.7.1, GPL-3.0, x86_64): локальные файлы, прямые HLS/RTSP/HTTP-ссылки
# и M3U-плейлисты — проверка сети и кодеков без проприетарных сервисов.
install_app VLC org.videolan.vlc \
    VLC-x86_64.apk

log_preinstall "готово; неудачных: $(ls $FLAGDIR/*.failed 2>/dev/null | wc -l)"
