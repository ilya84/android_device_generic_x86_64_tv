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
# Имена без ведущего / — файлы в /system/etc/preinstall; абсолютные пути
# допустимы (нужно для сплита YouTube с /data/media/0). Base и сплиты ставятся
# одним вызовом: у YouTube/Wink/Кинопоиска в манифесте есть requiredSplitTypes
# (base__abi/base__density), поэтому одиночный base.apk даёт
# INSTALL_FAILED_MISSING_SPLIT.
#
# Android 16: pm install-multiple/install-session-create удалены; multi-APK
# ставится через install-create/install-write/install-commit.
install_app() {
    name=$1
    pkg=$2
    shift 2

    # Ghost-safe: сначала проверяем codePath. Если PM помнит пакет, но APK
    # исчез (после reflash/смены слота), .done не должен блокировать установку.
    if pm path "$pkg" >/dev/null 2>&1; then
        touch "$FLAGDIR/$name.done" 2>/dev/null
        return
    fi
    # Отличаем ghost после перепрошивки от осознанного удаления пользователем:
    # при ghost каталог данных остаётся, при `pm uninstall` он удаляется.
    # Иначе preinstall воскрешал бы удалённые Jellyfin/VLC/YouTube на каждом
    # ребуте.
    if [ ! -d "/data/user/0/$pkg" ] && [ -f "$FLAGDIR/$name.done" ]; then
        log_preinstall "пропускаю $name: удалён пользователем (каталога данных нет)"
        return
    fi
    rm -f "$FLAGDIR/$name.done" "$FLAGDIR/$name.failed" 2>/dev/null

    APKS=""
    MISSING=""
    for f in "$@"; do
        case "$f" in
            /*) p="$f" ;;
            *)  p="$DIR/$f" ;;
        esac
        APKS="$APKS $p"
        [ -f "$p" ] || MISSING="$MISSING $p"
    done

    if [ -n "$MISSING" ]; then
        log_preinstall "ОТКАЗ $name: нет файлов$MISSING"
        echo "нет файлов:$MISSING" > "$FLAGDIR/$name.failed" 2>/dev/null
        return
    fi

    log_preinstall "устанавливаю $name ($pkg): $*"
    # Android 16: `pm install base.apk split.apk` не передаёт split
    # (INSTALL_FAILED_MISSING_SPLIT). Для multi-APK используем install-session.
    if [ $# -eq 1 ]; then
        case "$1" in
            /*) p="$1" ;;
            *)  p="$DIR/$1" ;;
        esac
        OUT=$(pm install -r -g "$p" 2>&1)
        WRITE_FAIL=
    else
        SZ=0
        for f in "$@"; do
            case "$f" in
                /*) p="$f" ;;
                *)  p="$DIR/$f" ;;
            esac
            SZ=$((SZ + $(stat -c%s "$p")))
        done
        SESS=$(pm install-create -r -g -S "$SZ" "$pkg" 2>&1 | sed -n 's/.*\[\([0-9]*\)\].*/\1/p')
        WRITE_FAIL=
        if [ -z "$SESS" ]; then
            OUT="install-create failed"
        else
            for f in "$@"; do
                case "$f" in
                    /*) p="$f" ;;
                    *)  p="$DIR/$f" ;;
                esac
                pm install-write -S "$(stat -c%s "$p")" "$SESS" "$(basename "$p")" "$p" >/dev/null 2>&1 || WRITE_FAIL=$f
            done
            if [ -n "$WRITE_FAIL" ]; then
                pm install-abandon "$SESS" >/dev/null 2>&1
                OUT="install-write failed: $WRITE_FAIL"
            else
                OUT=$(pm install-commit "$SESS" 2>&1)
            fi
        fi
    fi
    if [ -z "$WRITE_FAIL" ] && ! echo "$OUT" | grep -qE "Failure|failed|error"; then
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

# los-tv add-on: YouTube TV из пользовательского APK (arm64 идёт через
# NDK translation). Блок живёт здесь, а не дописывается add-on'ом: так база
# и add-on не расходятся, а после перепрошивки скрипт сам видит ghost-пакет
# (`pm path` пуст) и ставит base+split заново. Сплит обязателен: в манифесте
# YouTube есть requiredSplitTypes, одиночный base.apk даёт
# INSTALL_FAILED_MISSING_SPLIT.
if [ -f "$DIR/YouTubeTV.apk" ]; then
    YTSPLIT="$DIR/YouTubeTV-split_config.arm64_v8a.apk"
    if [ ! -f "$YTSPLIT" ]; then
        # Старый add-on/recovery умел копировать только base. Не оставляем
        # YouTube ghost'ом: сплит лежит рядом с пользовательскими APK на
        # /data/media/0, откуда его можно поставить напрямую.
        for d in /data/media/0/los-tv-proprietary \
                 /data/media/0/Download \
                 /data/local/tmp/los-tv-proprietary; do
            if [ -f "$d/YouTubeTV-split_config.arm64_v8a.apk" ]; then
                YTSPLIT="$d/YouTubeTV-split_config.arm64_v8a.apk"
                break
            fi
        done
    fi
    if [ -f "$YTSPLIT" ]; then
        install_app YouTubeTV com.google.android.youtube.tv \
            YouTubeTV.apk "$YTSPLIT"
    else
        log_preinstall "ВНИМАНИЕ: YouTubeTV.apk без split_config.arm64_v8a.apk — установка, скорее всего, упрётся в MISSING_SPLIT"
        install_app YouTubeTV com.google.android.youtube.tv YouTubeTV.apk
    fi
fi

log_preinstall "готово; неудачных: $(ls $FLAGDIR/*.failed 2>/dev/null | wc -l)"
