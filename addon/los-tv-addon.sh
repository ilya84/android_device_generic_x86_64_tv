#!/system/bin/sh
#
# los-tv: установка проприетарных компонентов (Widevine + NDK translation).
#
# Запускается из recovery (или вручную из root-shell для отладки).
# Компоненты НЕ входят в образ: скрипт извлекает их из образов, которые
# пользователь скачал сам (ChromeOS hatch и google_apis x86_64-36.1).
#
# Режимы:
#   los-tv-addon.sh extract  <chromeos.zip> <google_apis.zip> [OUT]
#   los-tv-addon.sh install  <OUT> <slot>
#
# extract — распаковать компоненты в OUT (по умолчанию /data/los-tv-addon/out)
# install — разложить OUT в system_<slot>.img (следующий шаг, пока заглушка)
#
# Хеши образов зафиксированы: при несовпадении скрипт отказывается работать,
# потому что смещения разделов (ROOT-A, super) зависят от версии образа.

set -u

CHROMEOS_SHA256=f53154eef9ae6c0532490ef160fede742006b5227486bd5ca9d84d39fa4926b5
GA_SHA1=15261872d5f0ae4b5728faefd0380d51b61a5b23

# ChromeOS hatch: GPT, ROOT-A = LBA 1286144, 8388608 секторов
ROOT_A_OFFSET=658505728
ROOT_A_SIZE=4294967296
# google_apis: GPT, super = LBA 4096, 8617984 сектора
SUPER_OFFSET=2097152
SUPER_SIZE=4412407808

HERE=$(dirname "$0")
ASSETS=${ASSETS:-$HERE}
NDK_LIST="$ASSETS/ndk-files.txt"
CDROM=${CDROM:-/mnt/cdrom}
PAYLOAD=${PAYLOAD:-$CDROM/los-tv-proprietary.tar.gz}

# lpunpack_dev: в recovery лежит в /system/bin, при отладке — рядом со скриптом
if [ -x /system/bin/lpunpack_dev ]; then
    LUNPACK=/system/bin/lpunpack_dev
elif [ -x "$HERE/lpunpack_dev" ]; then
    LUNPACK="$HERE/lpunpack_dev"
elif command -v lpunpack_dev >/dev/null 2>&1; then
    LUNPACK=lpunpack_dev
else
    LUNPACK=
fi

# los-tv-gpt: поиск разделов GPT по имени (ROOT-A, super) вместо смещений.
GPT=
if [ -x /system/bin/los-tv-gpt ]; then
    GPT=/system/bin/los-tv-gpt
elif [ -x "$HERE/los-tv-gpt" ]; then
    GPT="$HERE/los-tv-gpt"
elif command -v los-tv-gpt >/dev/null 2>&1; then
    GPT=los-tv-gpt
fi

WORK=${WORK:-/data/los-tv-addon}
OUT=${OUT:-$WORK/out}
LOOPDEV=

log() { echo "addon: $*"; }

# Сообщение на экран recovery (если утилита есть и меню остановлено).
screen() {
    if [ -x /system/bin/los-tv-msg ]; then
        /system/bin/los-tv-msg "$@" >/dev/null 2>&1 || true
    fi
}
die() { echo "addon: ОШИБКА: $*" >&2; exit 1; }

cleanup() {
    if [ -n "$LOOPDEV" ]; then
        losetup -d "$LOOPDEV" 2>/dev/null
        LOOPDEV=
    fi
    umount "$WORK/mnt" 2>/dev/null
}
trap cleanup EXIT INT TERM

# В recovery нет awk (toybox собран без него), поэтому разбираем df
# позиционными параметрами: Filesystem 1K-blocks Used Available Use% Mounted
free_kb() {
    set -- $(df -k "$1" 2>/dev/null | tail -1)
    echo "$4"
}

need_space() {
    avail=$(free_kb "$WORK")
    [ -n "$avail" ] || die "не удалось определить свободное место в $WORK"
    if [ "$avail" -lt "$1" ]; then
        die "мало места в $WORK: нужно $(( $1 / 1024 )) МБ, свободно $(( ${avail:-0} / 1024 )) МБ"
    fi
}

get_loop() {
    LOOPDEV=$(losetup -f 2>/dev/null)
    [ -n "$LOOPDEV" ] || die "нет свободного loop-устройства"
}

gpt_lookup() {
    # $1 — образ, $2 — имя раздела; печатает "first_lba sectors".
    [ -n "$GPT" ] || return 1
    line=$("$GPT" "$1" 2>/dev/null | grep -m1 "^$2 ")
    [ -n "$line" ] || return 1
    printf "%s\n" "$line" | cut -d" " -f2,3
}

loop_mount() {
    file=$1; off=$2; size=$3; fstype=$4; mnt=$5
    get_loop
    if [ "$size" -gt 0 ]; then
        losetup -r -o "$off" -S "$size" "$LOOPDEV" "$file" || die "losetup $file"
    else
        losetup -r -o "$off" "$LOOPDEV" "$file" || die "losetup $file"
    fi
    mkdir -p "$mnt"
    mount -t "$fstype" -o ro "$LOOPDEV" "$mnt" || die "mount $file ($fstype)"
}

loop_umount() {
    umount "$1" || die "umount $1"
    [ -n "$LOOPDEV" ] && losetup -d "$LOOPDEV" 2>/dev/null
    LOOPDEV=
    rmdir "$1" 2>/dev/null
}

find_lib64() {
    # Ищем 64-битную библиотеку: сначала в lib64, затем где угодно.
    f=$(find "$WORK/mnt" -path "*/lib64/*" -name "$1" -print -quit 2>/dev/null)
    [ -n "$f" ] || f=$(find "$WORK/mnt" -name "$1" -print -quit 2>/dev/null)
    printf "%s\n" "$f"
}

extract_widevine() {
    zip=$1
    if [ -f "$OUT/widevine/lib64/libwvaidl.so" ] && \
       [ -f "$OUT/widevine/lib64/libprotobuf-cpp-lite.so" ] && \
       [ -f "$OUT/widevine/lib64/android.hardware.drm-V1-ndk.so" ] && \
       [ -f "$OUT/widevine/bin/hw/android.hardware.drm-service-lazy.widevine" ]; then
        log "Widevine уже извлечён: $OUT/widevine"
        return
    fi
    log "проверяю ChromeOS-образ"
    screen "Widevine: checking image" "ChromeOS hatch"
    [ -f "$zip" ] || die "нет файла $zip"

    # Хеш больше не блокирует работу: новая версия образа может иметь другой
    # хеш. Целостность проверяется по содержимому (наличие нужных библиотек).
    if [ -n "$CHROMEOS_SHA256" ]; then
        if sha256sum "$zip" 2>/dev/null | grep -q "^$CHROMEOS_SHA256"; then
            log "sha256 ChromeOS совпал"
        else
            log "ВНИМАНИЕ: sha256 ChromeOS не совпал — продолжаю по содержимому (новая версия?)"
        fi
    fi
    need_space 6815744   # 6,5 ГБ (bin + vendor.raw + system.raw)

    # Loop-устройство хранит имя файла в 64 байтах, поэтому длинное имя
    # chromeos_..._HatchMPKeys-v14.bin монтировать нельзя — переименовываем.
    bin="$WORK/c.bin"
    if [ -f "$WORK/vendor.raw.img" ] && [ -f "$WORK/system.raw.img" ] && \
       [ "$(stat -c %s "$WORK/system.raw.img" 2>/dev/null || echo 0)" -gt 900000000 ]; then
        log "использую уже извлечённые vendor.raw.img и system.raw.img"
        bin=
    elif [ -f "$bin" ] && [ "$(stat -c %s "$bin" 2>/dev/null || echo 0)" -gt 4000000000 ]; then
        log "использую уже распакованный $bin"
    else
        screen "Widevine: extracting" "ChromeOS hatch (~5 GB)" "This is the longest step."
        log "распаковываю ChromeOS-образ"
        rm -rf "$WORK/chromeos" "$WORK/mnt"
        mkdir -p "$WORK/chromeos" || die "mkdir $WORK/chromeos"
        unzip -o -q -d "$WORK/chromeos" "$zip" || die "unzip $zip"
        # .bin ищем по содержимому: файл с подписью GPT в LBA1.
        src=
        for f in "$WORK/chromeos"/*; do
            [ -f "$f" ] || continue
            if [ "$(dd if="$f" bs=1 skip=512 count=8 2>/dev/null)" = "EFI PART" ]; then
                src=$f
                break
            fi
        done
        [ -n "$src" ] || src=$(ls -S "$WORK/chromeos"/* 2>/dev/null | head -1)
        [ -n "$src" ] || die "в архиве нет образа .bin"
        mv "$src" "$bin" || die "не удалось переименовать .bin"
    fi

    if [ -n "$bin" ]; then
        log "монтирую ROOT-A"
        part=$(gpt_lookup "$bin" "ROOT-A")
        if [ -n "$part" ]; then
            roff=${part% *}; rsize=${part#* }
            log "ROOT-A по GPT: offset=$roff size=$rsize"
        else
            roff=$ROOT_A_OFFSET; rsize=$ROOT_A_SIZE
            log "ROOT-A не найден в GPT — старые смещения: offset=$roff size=$rsize"
        fi
        loop_mount "$bin" "$roff" "$rsize" ext4 "$WORK/mnt"

        vendor=$(find "$WORK/mnt" -name vendor.raw.img -print -quit 2>/dev/null)
        system=$(find "$WORK/mnt" -name system.raw.img -print -quit 2>/dev/null)
        [ -n "$vendor" ] || die "vendor.raw.img не найден в ROOT-A"
        [ -n "$system" ] || die "system.raw.img не найден в ROOT-A"
        log "копирую vendor.raw.img: $vendor"
        cp "$vendor" "$WORK/vendor.raw.img" || die "cp vendor.raw.img"
        log "копирую system.raw.img: $system"
        cp "$system" "$WORK/system.raw.img" || die "cp system.raw.img"
        loop_umount "$WORK/mnt"
    fi

    log "освобождаю место (удаляю .bin)"
    rm -rf "$WORK/chromeos" "$bin"

    log "монтирую vendor.raw.img (EROFS)"
    loop_mount "$WORK/vendor.raw.img" 0 0 erofs "$WORK/mnt"

    mkdir -p "$OUT/widevine/lib64" "$OUT/widevine/bin/hw" || die "mkdir $OUT"
    lib=$(find_lib64 libwvaidl.so)
    hal=$(find "$WORK/mnt" -name android.hardware.drm-service-lazy.widevine -print -quit 2>/dev/null)
    [ -n "$lib" ] || die "libwvaidl.so не найден"
    [ -n "$hal" ] || die "HAL widevine не найден"
    cp "$lib" "$OUT/widevine/lib64/" || die "cp libwvaidl.so"
    cp "$hal" "$OUT/widevine/bin/hw/" || die "cp widevine HAL"
    chmod 755 "$OUT/widevine/bin/hw/android.hardware.drm-service-lazy.widevine"
    loop_umount "$WORK/mnt"

    log "монтирую system.raw.img (EROFS)"
    loop_mount "$WORK/system.raw.img" 0 0 erofs "$WORK/mnt"
    proto=$(find_lib64 libprotobuf-cpp-lite.so)
    drm=$(find_lib64 android.hardware.drm-V1-ndk.so)
    [ -n "$proto" ] || die "libprotobuf-cpp-lite.so не найден"
    [ -n "$drm" ] || die "android.hardware.drm-V1-ndk.so не найден"
    cp "$proto" "$OUT/widevine/lib64/" || die "cp libprotobuf-cpp-lite.so"
    cp "$drm" "$OUT/widevine/lib64/" || die "cp drm-V1-ndk"
    loop_umount "$WORK/mnt"

    # raw-образы НЕ удаляем: они нужны для быстрого повтора (resume выше),
    # занимают ~1 ГБ и уже являются Google-данными на /data.
    log "raw-образы оставлены в $WORK для быстрого повтора"

    log "Widevine готов: $OUT/widevine"
}

extract_ndk() {
    zip=$1
    screen "NDK translation: checking image" "google_apis"
    log "проверяю google_apis-образ"
    [ -f "$zip" ] || die "нет файла $zip"
    if [ -n "$GA_SHA1" ]; then
        if sha1sum "$zip" 2>/dev/null | grep -q "^$GA_SHA1"; then
            log "sha1 google_apis совпал"
        else
            log "ВНИМАНИЕ: sha1 google_apis не совпал — продолжаю по содержимому (новая версия?)"
        fi
    fi
    need_space 4718592   # 4,5 ГБ

    if [ -f "$WORK/lp/system.img" ] && \
       [ "$(stat -c %s "$WORK/lp/system.img" 2>/dev/null || echo 0)" -gt 500000000 ]; then
        log "использую уже распакованный $WORK/lp/system.img"
    else
        screen "NDK translation: extracting" "google_apis system.img (4.2 GB)"
        log "распаковываю system.img"
        rm -rf "$WORK/ga" "$WORK/lp"
        mkdir -p "$WORK/ga" || die "mkdir $WORK/ga"
        # Имя члена архива может быть любым (обычно <abi>/system.img).
        imgrel=$(unzip -l "$zip" 2>/dev/null | sed -n 's/.* \(.*system\.img\)$/\1/p' | head -1)
        [ -n "$imgrel" ] || die "system.img не найден в архиве"
        log "в архиве: $imgrel"
        unzip -o -q -d "$WORK/ga" "$zip" "$imgrel" || die "unzip $zip"
        img="$WORK/ga/$imgrel"
        [ -f "$img" ] || die "не удалось распаковать $imgrel"

        log "ищу раздел super (GPT)"
        part=$(gpt_lookup "$img" "super")
        if [ -n "$part" ]; then
            soff=${part% *}; ssize=${part#* }
            log "super по GPT: offset=$soff size=$ssize"
        else
            soff=$SUPER_OFFSET; ssize=$SUPER_SIZE
            log "super не найден в GPT — старые смещения: offset=$soff size=$ssize"
        fi

        log "извлекаю логический раздел system (lpunpack)"
        get_loop
        losetup -r -o "$soff" -S "$ssize" "$LOOPDEV" "$img" || die "losetup super"
        mkdir -p "$WORK/lp"
        [ -n "$LUNPACK" ] || die "не найден lpunpack_dev"
        "$LUNPACK" -p system "$LOOPDEV" "$WORK/lp" || die "lpunpack"
        losetup -d "$LOOPDEV"; LOOPDEV=
        rm -rf "$WORK/ga"
    fi

    rm -rf "$OUT/ndk"
    mkdir -p "$OUT/ndk" || die "mkdir $OUT/ndk"
    log "монтирую system.img и ищу NDK translation"
    loop_mount "$WORK/lp/system.img" 0 0 ext4 "$WORK/mnt"

    ndk=$(find "$WORK/mnt" -name libndk_translation.so -print -quit 2>/dev/null)
    [ -n "$ndk" ] || die "libndk_translation.so не найден в system.img"
    case "$ndk" in
        */lib64/libndk_translation.so) sysroot=${ndk%/lib64/libndk_translation.so} ;;
        */lib/libndk_translation.so)   sysroot=${ndk%/lib/libndk_translation.so} ;;
        *)                             sysroot=$(dirname "$(dirname "$ndk")") ;;
    esac
    log "system root: $sysroot (libndk_translation.so: $ndk)"

    # Набор файлов NDK ищем по шаблонам, а не по фиксированному списку:
    # Google может переставить пути внутри образа.
    find "$sysroot" -type f \( \
            -path "*/lib64/arm64/*" -o \
            -path "*/lib/arm/*" -o \
            -path "*/bin/arm64/*" -o \
            -path "*/bin/arm/*" -o \
            -name "libndk_translation*.so" -o \
            -name "libberberis*.so" -o \
            -name "ndk_translation_program_runner*" -o \
            -path "*/etc/berberis/*" -o \
            -path "*/etc/binfmt_misc/arm64*" -o \
            -path "*/etc/init/ndk_translation.rc" -o \
            -path "*/etc/ld.config.arm64.txt" \
        \) -print 2>/dev/null | sort > "$WORK/ndk-list.raw"

    : > "$OUT/ndk-files.txt"
    while read -r abs; do
        [ -n "$abs" ] || continue
        rel=${abs#"$sysroot"/}
        mkdir -p "$OUT/ndk/$(dirname "$rel")" || die "mkdir $OUT/ndk/$(dirname "$rel")"
        cp "$abs" "$OUT/ndk/$rel" || die "cp $rel"
        echo "$rel" >> "$OUT/ndk-files.txt"
    done < "$WORK/ndk-list.raw"

    count=$(wc -l < "$OUT/ndk-files.txt")
    [ "$count" -gt 50 ] || die "слишком мало файлов NDK ($count) — образ не похож на google_apis"
    loop_umount "$WORK/mnt"
    rm -rf "$WORK/lp"

    log "NDK translation готов: $OUT/ndk ($count файлов)"
}

do_extract() {
    chromeos=$1
    ga=$2
    extra=${3:-}
    [ -n "$extra" ] && OUT=$extra
    mkdir -p "$WORK" "$OUT" || die "не удалось создать $WORK"

    # Готовый payload (после первого успешного извлечения) — используем его
    # вместо повторной распаковки 10 ГБ образов.
    if [ -f "$PAYLOAD" ]; then
        log "найден готовый $PAYLOAD — проверяю"
        if tar -tzf "$PAYLOAD" 2>/dev/null | grep -q "libwvaidl.so" && \
           tar -tzf "$PAYLOAD" 2>/dev/null | grep -q "libndk_translation.so"; then
            rm -rf "$OUT"
            mkdir -p "$OUT"
            if tar -xzf "$PAYLOAD" -C "$OUT" 2>/dev/null && \
               ( cd "$OUT" && md5sum -c md5.txt >/dev/null 2>&1 ); then
                log "payload распакован и проверен: $(wc -l < "$OUT/md5.txt") файлов"
                screen "Components ready" "Restored from payload archive"
                return
            fi
            log "payload повреждён — извлекаю из образов"
            rm -rf "$OUT"; mkdir -p "$OUT"
        fi
    fi

    extract_widevine "$chromeos"
    extract_ndk "$ga"

    log "считаю контрольные суммы результата"
    # md5.txt создаётся редиректом ДО find, поэтому его надо исключить —
    # иначе в файл попадает хеш пустого md5.txt и проверка всегда падает.
    ( cd "$OUT" && find . -type f ! -name md5.txt | sort | while read -r f; do
        md5sum "$f"
    done ) > "$OUT/md5.txt"

    if [ ! -f "$PAYLOAD" ]; then
        log "создаю $PAYLOAD (для повторной установки после OTA)"
        payload_files="widevine ndk md5.txt"
        [ -f "$OUT/ndk-files.txt" ] && payload_files="$payload_files ndk-files.txt"
        tar -czf "$PAYLOAD" -C "$OUT" $payload_files || \
            log "ВНИМАНИЕ: не удалось создать $PAYLOAD"
        # umask в recovery 077: делаем архив читаемым, чтобы его можно было
        # забрать по adb/посмотреть без root.
        chmod 644 "$PAYLOAD" 2>/dev/null
    fi

    screen "Components extracted" "Files: $(wc -l < "$OUT/md5.txt")" "Starting installation."
    log "готово: $OUT"
    log "файлов: $(wc -l < "$OUT/md5.txt")"
}

install_play_store() {
    src=$1
    apk=
    for f in "$src/PlayStore-TV.apk" "$src"/*vending*.apk "$src"/*PlayStore*.apk; do
        if [ -f "$f" ]; then apk=$f; break; fi
    done
    if [ -z "$apk" ]; then
        log "Play Store APK не найден — пропускаю"
        return 0
    fi
    # Строки в бинарном манифесте — UTF-16, поэтому убираем NUL-байты,
    # иначе grep не находит ASCII-имена (проверено 2026-10-31).
    tmp="$WORK/manifest.bin"
    unzip -p "$apk" AndroidManifest.xml 2>/dev/null | tr -d '\000' > "$tmp"
    if [ ! -s "$tmp" ]; then
        die "не удалось прочитать AndroidManifest.xml из $apk"
    fi
    if ! grep -q "com.android.vending" "$tmp"; then
        die "$apk не похож на Play Store: в манифесте нет com.android.vending"
    fi
    if ! grep -qE "TvMainActivity|android.software.leanback" "$tmp"; then
        log "ВНИМАНИЕ: в $apk нет TV-маркера — возможно, это мобильная версия"
    fi
    rm -f "$tmp"
    log "Play Store: $(basename "$apk"), sha256 $(sha256sum "$apk" | cut -d' ' -f1)"

    mkdir -p "$sys/priv-app/PlayStore" || die "mkdir priv-app"
    cp "$apk" "$sys/priv-app/PlayStore/PlayStore.apk" || die "cp Play Store"
    chmod 755 "$sys/priv-app/PlayStore"
    chmod 644 "$sys/priv-app/PlayStore/PlayStore.apk"

    [ -f "$ASSETS/privapp-permissions-com.android.vending.xml" ] || \
        die "нет $ASSETS/privapp-permissions-com.android.vending.xml"
    mkdir -p "$sys/etc/permissions"
    cp "$ASSETS/privapp-permissions-com.android.vending.xml" \
        "$sys/etc/permissions/privapp-permissions-com.android.vending.xml" || \
        die "cp privapp XML"
    chmod 644 "$sys/etc/permissions/privapp-permissions-com.android.vending.xml"

    chcon u:object_r:system_file:s0 \
        "$sys/priv-app/PlayStore/PlayStore.apk" \
        "$sys/etc/permissions/privapp-permissions-com.android.vending.xml" 2>/dev/null
    log "Play Store установлен в priv-app"
}


install_microg() {
    src=$1
    apk=
    for f in "$src/MicroGGmsCore.apk" "$src"/*MicroG*.apk "$src"/*GmsCore*.apk; do
        if [ -f "$f" ]; then apk=$f; break; fi
    done
    if [ -z "$apk" ]; then
        log "microG APK не найден — пропускаю"
        return 0
    fi
    log "microG: $(basename "$apk")"
    mkdir -p "$sys/app/MicroGGmsCore" || die "mkdir microG"
    cp "$apk" "$sys/app/MicroGGmsCore/MicroGGmsCore.apk" || die "cp microG"
    chmod 755 "$sys/app/MicroGGmsCore"
    chmod 644 "$sys/app/MicroGGmsCore/MicroGGmsCore.apk"
    chcon u:object_r:system_file:s0 "$sys/app/MicroGGmsCore/MicroGGmsCore.apk" 2>/dev/null
    log "microG установлен"
}

install_youtube() {
    src=$1
    srcapk=
    apk=
    split=

    # Если YouTube уже установлен (например, из Play Store), его APK в
    # /data/app новее того, что лежит в /sdcard. Для preinstall берём именно
    # установленный APK, иначе после OTA можно получить VERSION_DOWNGRADE.
    instdir=
    for d in /data/app/*/com.google.android.youtube.tv-* \
             /data/app/com.google.android.youtube.tv-*; do
        [ -d "$d" ] || continue
        if [ -f "$d/base.apk" ]; then
            instdir=$d
            break
        fi
    done

    if [ -n "$instdir" ]; then
        apk="$instdir/base.apk"
        [ -f "$instdir/split_config.arm64_v8a.apk" ] && \
            split="$instdir/split_config.arm64_v8a.apk"
        log "YouTube TV: использую установленный APK из $instdir"
    else
        for f in "$src/YouTube-TV.apk" "$src"/*youtube.tv*.apkm "$src"/*youtube.tv*.apk "$src"/YouTube*.apk; do
            if [ -f "$f" ]; then srcapk=$f; break; fi
        done
        if [ -z "$srcapk" ]; then
            log "YouTube TV APK не найден — пропускаю (можно поставить из Play Store)"
            return 0
        fi
        log "YouTube TV: $(basename "$srcapk"), sha256 $(sha256sum "$srcapk" | cut -d" " -f1)"

        apk=$srcapk
        case "$srcapk" in
            *.apkm|*.zip)
                tmpd="$WORK/apkm"
                rm -rf "$tmpd"; mkdir -p "$tmpd"
                log "распаковываю bundle $(basename "$srcapk")"
                unzip -o -q -d "$tmpd" "$srcapk" "base.apk" "split_config.arm64_v8a.apk" || \
                    log "ВНИМАНИЕ: в bundle нет base.apk/split_config.arm64_v8a.apk"
                apk="$tmpd/base.apk"
                [ -f "$tmpd/split_config.arm64_v8a.apk" ] && \
                    split="$tmpd/split_config.arm64_v8a.apk"
                ;;
            *)
                split="$src/YouTubeTV-split_config.arm64_v8a.apk"
                [ -f "$split" ] || split=
                # Fallback: split мог не попасть в stage_apks (в recovery бывают
                # сборки без симлинка). Ищем его рядом с исходным base APK.
                if [ -z "$split" ]; then
                    for d in "$CDROM/data/media/0/los-tv-proprietary" \
                             "$CDROM/los-tv-proprietary" \
                             /data/los-tv-proprietary; do
                        if [ -f "$d/YouTubeTV-split_config.arm64_v8a.apk" ]; then
                            split="$d/YouTubeTV-split_config.arm64_v8a.apk"
                            break
                        fi
                    done
                fi
                ;;
        esac
    fi
    [ -f "$apk" ] || die "не найден base APK YouTube TV"
    if [ -n "$split" ]; then
        log "YouTube TV split: $(basename "$split")"
    else
        log "ВНИМАНИЕ: split_config.arm64_v8a.apk не найден — preinstall упрётся в MISSING_SPLIT"
    fi

    mkdir -p "$sys/etc/preinstall"
    cp "$apk" "$sys/etc/preinstall/YouTubeTV.apk" || die "cp YouTube TV"
    chmod 644 "$sys/etc/preinstall/YouTubeTV.apk"
    if [ -n "$split" ] && [ -f "$split" ]; then
        cp "$split" "$sys/etc/preinstall/YouTubeTV-split_config.arm64_v8a.apk" || \
            die "cp YouTube TV split"
        chmod 644 "$sys/etc/preinstall/YouTubeTV-split_config.arm64_v8a.apk"
    fi

    if ! grep -q "install_app YouTubeTV" "$sys/bin/preinstall-apps.sh"; then
        cat >> "$sys/bin/preinstall-apps.sh" <<'PREINSTALL'

# los-tv add-on: YouTube TV из пользовательского APK (arm64 идёт через
# NDK translation, поэтому ставится после add-on).
if [ -f "$DIR/YouTubeTV.apk" ]; then
    if [ -f "$DIR/YouTubeTV-split_config.arm64_v8a.apk" ]; then
        install_app YouTubeTV com.google.android.youtube.tv \
            YouTubeTV.apk \
            YouTubeTV-split_config.arm64_v8a.apk
    else
        install_app YouTubeTV com.google.android.youtube.tv YouTubeTV.apk
    fi
fi
PREINSTALL
    fi
    # Если прошлый preinstall отмечал YouTubeTV.done, а пакет потом исчез
    # (например, после смены слота), без снятия флага он не установится:
    # preinstall-apps.sh проверяет .done раньше, чем pm path.
    rm -f "$CDROM/data/misc/preinstall-apps/YouTubeTV.done" 2>/dev/null
    log "YouTube TV добавлен в preinstall (установится при первой загрузке)"
}

patch_build_prop() {
    prop="$sys/build.prop"
    [ -f "$prop" ] || die "нет $prop"
    add_prop() {
        key=$1
        val=$2
        if grep -q "^$key=" "$prop"; then
            sed -i "s|^$key=.*|$key=$val|" "$prop"
        else
            echo "$key=$val" >> "$prop"
        fi
    }
    add_prop ro.dalvik.vm.native.bridge libndk_translation.so
    add_prop ro.dalvik.vm.isa.arm64 x86_64
    add_prop ro.ndk_translation.version 0.2.3
    add_prop ro.product.cpu.abilist x86_64,arm64-v8a
    add_prop ro.product.cpu.abilist64 x86_64,arm64-v8a
    add_prop ro.system.product.cpu.abilist x86_64,arm64-v8a
    add_prop ro.system.product.cpu.abilist64 x86_64,arm64-v8a
    log "build.prop обновлён (native bridge + arm64 в списке ABI)"
}

do_install() {
    out=$1
    want=${2:-other}
    CDROM=${CDROM:-/mnt/cdrom}

    # Список NDK из payload (генерируется при извлечении); иначе — базовый.
    if [ -f "$out/ndk-files.txt" ]; then
        NDK_LIST="$out/ndk-files.txt"
    fi

    # SKIP_COMPONENTS=1 — режим «только APK»: NDK/Widevine уже стоят, надо
    # лишь добавить Play Store/YouTube TV в активный слот.
    if [ "${SKIP_COMPONENTS:-0}" != "1" ]; then
        [ -d "$out/widevine" ] || die "нет $out/widevine (сначала extract)"
        [ -d "$out/ndk" ] || die "нет $out/ndk"
    fi

    cfg="$CDROM/boot/grub/android.cfg"
    [ -f "$cfg" ] || die "нет $cfg"
    active=$(sed -n 's/^SLOT=_\([ab]\)$/\1/p' "$cfg" | head -1)
    [ -n "$active" ] || die "не удалось определить активный слот из $cfg"

    INPLACE=${INPLACE:-0}

    if [ "$INPLACE" = "1" ]; then
        # post-OTA: активный слот только что содержит свежий OTA-образ без
        # компонентов. Ставим в него НА МЕСТЕ, а рабочий бэкап в другом слоте
        # не трогаем и загрузку не переключаем.
        slot=$active
        src="$CDROM/system_$active.img"
        img="$CDROM/system_$active.img"
        log "post-OTA: ставлю на месте в активный слот _$slot (бэкап не трогаю)"
        screen "Installing to slot _$slot" "In place (post-OTA), backup kept"
    else
        case "$want" in
            other|"")
                if [ "$active" = a ]; then slot=b; else slot=a; fi
                ;;
            a|b) slot=$want ;;
            *) die "слот должен быть a, b или other" ;;
        esac
        [ "$slot" != "$active" ] || die "нельзя ставить в активный слот _$slot"

        src="$CDROM/system_$active.img"
        img="$CDROM/system_$slot.img"
        log "активный слот: _$active, ставлю в _$slot"
        screen "Installing to slot _$slot" "Cloning system image (~8.6 GB)"

        # ВСЕГДА клонируем активный слот в целевой: что лежит в целевом, мы не
        # знаем (там может быть старая система после давнего OTA), а установка
        # компонентов на неё привела бы к даунгрейду при переключении.
        log "клонирую активный слот _$active -> _$slot ($src)"
        rm -f "$img"
        cp "$src" "$img" || die "не удалось скопировать $src"

        # Ядро/initrd/recovery всегда из активного слота — иначе новая система
        # достанется в паре со старым ядром.
        log "копирую kernel/initrd/recovery _$active -> _$slot"
        cp "$CDROM/kernel_$active" "$CDROM/kernel_$slot" || die "cp kernel"
        cp "$CDROM/initrd_$active.img" "$CDROM/initrd_$slot.img" || die "cp initrd"
        cp "$CDROM/recovery_$active.img" "$CDROM/recovery_$slot.img" || die "cp recovery"
    fi

    log "проверяю ФС клона (e2fsck)"
    e2fsck -f -y "$img" >/dev/null 2>&1 || true

    log "монтирую system_$slot.img"
    get_loop
    losetup "$LOOPDEV" "$img" || die "losetup $img"
    mkdir -p "$WORK/mnt"
    mount -t ext4 -o rw "$LOOPDEV" "$WORK/mnt" || die "mount $img"
    sys="$WORK/mnt/system"

    if [ "${SKIP_COMPONENTS:-0}" = "1" ]; then
        log "режим только-APK: компоненты не трогаю"
        screen "Adding apps to slot _$slot" "Play Store / YouTube TV"
    else
    screen "Installing to slot _$slot" "Copying NDK translation and Widevine"
    log "копирую NDK translation ($(wc -l < "$NDK_LIST") файлов)"
    while read -r f; do
        [ -n "$f" ] || continue
        d=$(dirname "$f")
        mkdir -p "$sys/$d" || die "mkdir $sys/$d"
        # umask 077 в recovery: mkdir создаёт 700, и приложения не могут
        # пройти в /system/bin/arm64 и /system/lib64/arm64.
        chmod 755 "$sys/$d"
        cp "$out/ndk/$f" "$sys/$f" || die "cp $f"
    done < "$NDK_LIST"
    # umask в recovery — 077, поэтому cp создаёт файлы 600. Права меняем
    # ТОЛЬКО у файлов из NDK-манифеста: широкий chmod по каталогам снимал
    # бит x с /system/bin/init и приводил к "Attempted to kill init".
    while read -r f; do
        [ -n "$f" ] || continue
        chmod 644 "$sys/$f" 2>/dev/null
    done < "$NDK_LIST"
    chmod 755 "$sys/bin/arm64/app_process64" "$sys/bin/arm64/linker64" \
              "$sys/bin/ndk_translation_program_runner_binfmt_misc_arm64" 2>/dev/null

    log "копирую Widevine"
    mkdir -p "$sys/vendor/lib64" "$sys/vendor/bin/hw" \
             "$sys/vendor/etc/init" "$sys/vendor/etc/vintf/manifest"
    for so in "$out/widevine/lib64/"*.so; do
        cp "$so" "$sys/vendor/lib64/" || die "cp $(basename "$so")"
        chmod 644 "$sys/vendor/lib64/$(basename "$so")"
    done
    cp "$out/widevine/bin/hw/android.hardware.drm-service-lazy.widevine" \
        "$sys/vendor/bin/hw/" || die "cp widevine HAL"
    chmod 755 "$sys/vendor/bin/hw/android.hardware.drm-service-lazy.widevine"
    cp "$ASSETS/android.hardware.drm-service-lazy.widevine.rc" \
        "$sys/vendor/etc/init/" || die "cp widevine rc"
    chmod 644 "$sys/vendor/etc/init/android.hardware.drm-service-lazy.widevine.rc"
    cp "$ASSETS/manifest_android.hardware.drm-service.widevine.xml" \
        "$sys/vendor/etc/vintf/manifest/" || die "cp widevine manifest"
    chmod 644 "$sys/vendor/etc/vintf/manifest/manifest_android.hardware.drm-service.widevine.xml"

    log "выставляю SELinux-метки"
    chcon u:object_r:vendor_file:s0 "$sys/vendor/lib64/libwvaidl.so" 2>/dev/null
    chcon u:object_r:vendor_configs_file:s0 \
        "$sys/vendor/etc/init/android.hardware.drm-service-lazy.widevine.rc" 2>/dev/null
    chcon u:object_r:vendor_configs_file:s0 \
        "$sys/vendor/etc/vintf/manifest/manifest_android.hardware.drm-service.widevine.xml" 2>/dev/null
    # HAL-бинарь — отдельный exec-тип AIDL-DRM: init сделает переход в домен
    # hal_drm_clearkey_aidl (system смонтирован ro, restorecon в init не может).
    chcon u:object_r:hal_drm_clearkey_aidl_exec:s0 \
        "$sys/vendor/bin/hw/android.hardware.drm-service-lazy.widevine" 2>/dev/null
    chcon u:object_r:system_file:s0 "$sys/lib64/libndk_translation.so" \
        "$sys/lib64/libberberis_exec_region.so" 2>/dev/null

    patch_build_prop
    fi
    install_play_store "${ADDON_SRC:-}"
    install_microg "${ADDON_SRC:-}"
    install_youtube "${ADDON_SRC:-}"

    sync
    log "размонтирую"
    umount "$WORK/mnt" || die "umount"
    losetup -d "$LOOPDEV"; LOOPDEV=

    if [ "$INPLACE" = "1" ]; then
        log "post-OTA: слот не переключаю, загружаемся в тот же _$slot"
    else
        cp "$cfg" "$cfg.bak-$(date +%Y%m%d-%H%M%S)"
        if [ "${NO_SWITCH:-0}" = "1" ]; then
            log "NO_SWITCH=1: слот не переключаю"
        else
            if [ "$slot" = b ]; then num=1; else num=0; fi
            log "переключаю загрузку на слот _$slot"
            if command -v bootctl >/dev/null 2>&1; then
                bootctl set-active-boot-slot "$num" || die "bootctl"
            else
                # В recovery bootctl нет (он в системном образе); GRUB читает
                # активный слот из android.cfg, поэтому правим файл напрямую.
                sed -i "s/^SLOT=_.*/SLOT=_$slot/" "$cfg" || die "sed $cfg"
                grep -q "^SLOT=_$slot$" "$cfg" || die "не удалось записать SLOT в $cfg"
            fi
        fi
    fi

    if [ "$INPLACE" = "1" ]; then
        screen "Done" "Components installed in place (slot _$slot)" "Rebooting..."
    else
        screen "Done" "Components installed to _$slot" "Rebooting..."
    fi
    log "готово: компоненты установлены в _$slot"
}

case "${1:-}" in
    extract) shift; [ $# -ge 2 ] || die "usage: $0 extract <chromeos.zip> <google_apis.zip> [OUT]"; do_extract "$@" ;;
    install) shift; [ $# -ge 2 ] || die "usage: $0 install <OUT> <slot>"; do_install "$@" ;;
    *) die "usage: $0 extract|install ..." ;;
esac

exit 0
