
PRODUCT_DIR := $(dir $(lastword $(filter-out device/common/%,$(filter device/%,$(ALL_PRODUCTS)))))


# TV config
ifeq ($(USE_TV_BUILD), true)

# ATV
PRODUCT_IS_ATV := true

endif

# No Compressed APEXes
OVERRIDE_PRODUCT_COMPRESSED_APEX := false

# A/B
PRODUCT_BUILD_GENERIC_OTA_PACKAGE := true
AB_OTA_POSTINSTALL_CONFIG += \
    RUN_POSTINSTALL_system=true \
    POSTINSTALL_PATH_system=system/bin/otapreopt_script \
    FILESYSTEM_TYPE_system=ext4 \
    POSTINSTALL_OPTIONAL_system=true

PRODUCT_PACKAGES += \
    otapreopt_script

# Boot control
PRODUCT_PACKAGES_DEBUG += \
    bootctl

# Смена uid для диагностики (только userdebug/eng), напр.:
#   su 2000,2000 cmd notification post -T -t "Тема" tag "текст"
PRODUCT_PACKAGES_DEBUG += \
    su

# Update engine
PRODUCT_PACKAGES += \
    update_engine \
    update_engine_sideload \
    update_verifier

PRODUCT_PACKAGES_DEBUG += \
    update_engine_client

PRODUCT_PROPERTY_OVERRIDES := \
    ro.lmk.kill_timeout_ms=100 \
    ro.arch=x86 \
    persist.rtc_local_time=0 \
    dalvik.vm.useautofastjni=true \
    ro.surface_flinger.max_frame_buffer_acquired_buffers=3 \
    audio.safemedia.bypass=true \
    persist.device_config.mglru_native.lru_gen_config=all \
    persist.sys.zram_enabled=1 \
    external_storage.casefold.enabled=1 \
    external_storage.projid.enabled=1


# Network OTA: optional custom Updater endpoint (lineage.updater.uri).
# Build with LOS_TV_OTA_URI=https://atv.kacnep.ru/x86_64_tv.json.
ifneq ($(LOS_TV_OTA_URI),)
PRODUCT_PROPERTY_OVERRIDES += lineage.updater.uri=$(LOS_TV_OTA_URI)
endif

PRODUCT_SYSTEM_EXT_PROPERTIES += ro.setupwizard.mode=DISABLED

PRODUCT_COPY_FILES := \
    $(if $(wildcard $(PRODUCT_DIR)init.rc),$(PRODUCT_DIR)init.rc:root/init.rc) \
    $(if $(wildcard $(PRODUCT_DIR)init.sh),$(PRODUCT_DIR),$(LOCAL_PATH)/)init.sh:system/etc/init.sh \
    $(if $(wildcard $(PRODUCT_DIR)init.fstab.sh),$(PRODUCT_DIR),$(LOCAL_PATH)/)init.fstab.sh:$(TARGET_COPY_OUT_VENDOR)/etc/init.fstab.sh \
    $(if $(wildcard $(PRODUCT_DIR)init.zram.sh),$(PRODUCT_DIR),$(LOCAL_PATH)/)init.zram.sh:$(TARGET_COPY_OUT_VENDOR)/etc/init.zram.sh \
    $(if $(wildcard $(PRODUCT_DIR)modules.blocklist),$(PRODUCT_DIR),$(LOCAL_PATH)/)modules.blocklist:system/etc/modules.blocklist \
    $(if $(wildcard $(PRODUCT_DIR)modules.options),$(PRODUCT_DIR),$(LOCAL_PATH)/)modules.options:system/etc/modules.options \
    $(if $(wildcard $(PRODUCT_DIR)fstab.$(TARGET_PRODUCT)),$(PRODUCT_DIR)fstab.$(TARGET_PRODUCT),$(LOCAL_PATH)/fstab.x86):root/fstab.$(TARGET_PRODUCT) \
    $(if $(wildcard $(PRODUCT_DIR)wpa_supplicant.conf),$(PRODUCT_DIR),$(LOCAL_PATH)/)wpa_supplicant.conf:$(TARGET_COPY_OUT_VENDOR)/etc/wifi/wpa_supplicant.conf \
    $(if $(wildcard $(PRODUCT_DIR)wpa_supplicant_overlay.conf),$(PRODUCT_DIR),$(LOCAL_PATH)/)wpa_supplicant_overlay.conf:$(TARGET_COPY_OUT_VENDOR)/etc/wifi/wpa_supplicant_overlay.conf \
    $(if $(wildcard $(PRODUCT_DIR)excluded-input-devices.xml),$(PRODUCT_DIR),$(LOCAL_PATH)/)excluded-input-devices.xml:system/etc/excluded-input-devices.xml \
    $(if $(wildcard $(PRODUCT_DIR)init.$(TARGET_PRODUCT).rc),$(PRODUCT_DIR)init.$(TARGET_PRODUCT).rc,$(LOCAL_PATH)/init.x86.rc):root/init.$(TARGET_PRODUCT).rc \
    $(if $(wildcard $(PRODUCT_DIR)ueventd.$(TARGET_PRODUCT).rc),$(PRODUCT_DIR)ueventd.$(TARGET_PRODUCT).rc,$(LOCAL_PATH)/ueventd.x86.rc):$(TARGET_COPY_OUT_VENDOR)/etc/ueventd.rc \

# Copy System Files
PRODUCT_COPY_FILES += \
    $(LOCAL_PATH)/ppp/ip-up:$(TARGET_COPY_OUT_SYSTEM)/etc/ppp/ip-up \
    $(LOCAL_PATH)/ppp/ip-down:$(TARGET_COPY_OUT_SYSTEM)/etc/ppp/ip-down \
    $(LOCAL_PATH)/ppp/peers/gprs:$(TARGET_COPY_OUT_SYSTEM)/etc/ppp/peers/gprs \
    $(LOCAL_PATH)/metadata.keep:root/metadata/.keep \
    frameworks/av/media/libstagefright/data/media_codecs_sw.xml:$(TARGET_COPY_OUT_VENDOR)/etc/media_codecs.xml \
    $(LOCAL_PATH)/media_profiles.xml:$(TARGET_COPY_OUT_VENDOR)/etc/media_profiles_V1_0.xml \
    $(LOCAL_PATH)/fstab.internal.x86:$(TARGET_COPY_OUT_SYSTEM)/vendor/etc/fstab.internal.x86 \
    frameworks/av/media/libstagefright/data/media_codecs_google_c2.xml:$(TARGET_COPY_OUT_VENDOR)/etc/media_codecs_google_c2.xml \
    frameworks/av/media/libstagefright/data/media_codecs_google_c2_audio.xml:$(TARGET_COPY_OUT_VENDOR)/etc/media_codecs_google_c2_audio.xml \
    frameworks/av/media/libstagefright/data/media_codecs_google_c2_video.xml:$(TARGET_COPY_OUT_VENDOR)/etc/media_codecs_google_c2_video.xml \
    $(LOCAL_PATH)/media_codecs_radeon.xml:$(TARGET_COPY_OUT_VENDOR)/etc/media_codecs_radeon.xml \
    $(LOCAL_PATH)/media_codecs_radeon_c2_video.xml:$(TARGET_COPY_OUT_VENDOR)/etc/media_codecs_radeon_c2_video.xml \
    $(LOCAL_PATH)/media_codecs_radeon_apex.xml:$(TARGET_COPY_OUT_VENDOR)/etc/media_codecs_radeon_apex.xml \
    external/mesa3d/src/util/00-mesa-defaults.conf:$(TARGET_COPY_OUT_VENDOR)/etc/drirc

# Copy Vendor Files
PRODUCT_COPY_FILES += \
    $(LOCAL_PATH)/external_camera_config.xml:$(TARGET_COPY_OUT_VENDOR)/etc/external_camera_config.xml \
    frameworks/native/data/etc/android.hardware.audio.low_latency.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.audio.low_latency.xml \
    frameworks/native/data/etc/android.hardware.bluetooth.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.bluetooth.xml \
    frameworks/native/data/etc/android.hardware.bluetooth_le.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.bluetooth_le.xml \
    frameworks/native/data/etc/android.hardware.ethernet.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.ethernet.xml \
    frameworks/native/data/etc/android.hardware.gamepad.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.gamepad.xml \
    frameworks/native/data/etc/android.software.ipsec_tunnels.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.software.ipsec_tunnels.xml \
    frameworks/native/data/etc/android.hardware.location.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.location.xml \
    frameworks/native/data/etc/android.hardware.location.gps.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.location.gps.xml \
    frameworks/native/data/etc/android.hardware.opengles.aep.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.opengles.aep.xml \
    frameworks/native/data/etc/android.hardware.sensor.accelerometer.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.sensor.accelerometer.xml \
    frameworks/native/data/etc/android.hardware.sensor.barometer.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.sensor.barometer.xml \
    frameworks/native/data/etc/android.hardware.sensor.compass.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.sensor.compass.xml \
    frameworks/native/data/etc/android.hardware.sensor.gyroscope.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.sensor.gyroscope.xml \
    frameworks/native/data/etc/android.hardware.sensor.light.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.sensor.light.xml \
    frameworks/native/data/etc/android.hardware.sensor.proximity.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.sensor.proximity.xml \
    frameworks/native/data/etc/android.hardware.usb.accessory.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.usb.accessory.xml \
    frameworks/native/data/etc/android.hardware.usb.host.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.usb.host.xml \
    frameworks/native/data/etc/android.hardware.wifi.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.wifi.xml \
    frameworks/native/data/etc/android.hardware.wifi.direct.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.wifi.direct.xml \
    frameworks/native/data/etc/android.software.activities_on_secondary_displays.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.software.activities_on_secondary_displays.xml \
    frameworks/native/data/etc/android.software.app_widgets.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.software.app_widgets.xml \
    frameworks/native/data/etc/android.software.connectionservice.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.software.connectionservice.xml \
    frameworks/native/data/etc/android.software.controls.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.software.controls.xml \
    frameworks/native/data/etc/android.software.device_admin.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.software.device_admin.xml \
    frameworks/native/data/etc/android.software.freeform_window_management.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.software.freeform_window_management.xml \
    frameworks/native/data/etc/android.software.midi.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.software.midi.xml \
    frameworks/native/data/etc/android.software.picture_in_picture.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.software.picture_in_picture.xml \
    frameworks/native/data/etc/android.software.print.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.software.print.xml \
    frameworks/native/data/etc/android.software.sip.voip.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.software.sip.voip.xml \
    frameworks/native/data/etc/android.software.autofill.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.software.autofill.xml \
    frameworks/native/data/etc/android.software.sip.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.software.sip.xml \
    frameworks/native/data/etc/android.software.voice_recognizers.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.software.voice_recognizers.xml \
    frameworks/native/data/etc/android.software.webview.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.software.webview.xml \
    frameworks/native/data/etc/android.hardware.keystore.app_attest_key.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.keystore.app_attest_key.xml \
    $(LOCAL_PATH)/OEMBlackList:$(TARGET_COPY_OUT_VENDOR)/etc/misc/.OEMBlackList \
    $(LOCAL_PATH)/OEMWhiteList:$(TARGET_COPY_OUT_VENDOR)/etc/misc/.OEMWhiteList \
    $(LOCAL_PATH)/ThirdPartySO:$(TARGET_COPY_OUT_VENDOR)/etc/misc/.ThirdPartySO \
    $(LOCAL_PATH)/seccomp/mediaswcodec.policy:$(TARGET_COPY_OUT_VENDOR)/etc/seccomp_policy/mediaswcodec.policy

# Copy Misc Config Files
PRODUCT_COPY_FILES += \
    $(foreach f,$(wildcard $(LOCAL_PATH)/idc/*.idc $(LOCAL_PATH)/keylayout/*.kl),$(f):$(subst $(LOCAL_PATH),system/usr,$(f)))

# Go init
ifeq ($(BOARD_IS_GO_BUILD),true)
PRODUCT_COPY_FILES += \
    $(if $(wildcard $(PRODUCT_DIR)init.low_performance.rc),$(PRODUCT_DIR)init.low_performance.rc,$(LOCAL_PATH)/init.low_performance.rc):$(TARGET_COPY_OUT_VENDOR)/etc/init/hw/init.low_performance.rc
endif

# Recovery
PRODUCT_COPY_FILES += \
    $(if $(wildcard $(PRODUCT_DIR)init.recovery.$(TARGET_PRODUCT).rc),$(PRODUCT_DIR)init.recovery.$(TARGET_PRODUCT).rc,$(LOCAL_PATH)/init.recovery.x86.rc):$(TARGET_COPY_OUT_RECOVERY)/root/init.recovery.$(TARGET_PRODUCT).rc \
    $(if $(wildcard $(PRODUCT_DIR)init.recovery.sh),$(PRODUCT_DIR),$(LOCAL_PATH)/)init.recovery.sh:$(TARGET_COPY_OUT_RECOVERY)/root/system/etc/init.recovery.sh \
    $(LOCAL_PATH)/addon/los-tv-addon.sh:$(TARGET_COPY_OUT_RECOVERY)/root/system/bin/los-tv-addon.sh \
    $(LOCAL_PATH)/addon/los-tv-addon-boot.sh:$(TARGET_COPY_OUT_RECOVERY)/root/system/bin/los-tv-addon-boot.sh \
    $(LOCAL_PATH)/addon/ndk-files.txt:$(TARGET_COPY_OUT_RECOVERY)/root/system/etc/los-tv-addon/ndk-files.txt \
    $(LOCAL_PATH)/addon/android.hardware.drm-service-lazy.widevine.rc:$(TARGET_COPY_OUT_RECOVERY)/root/system/etc/los-tv-addon/android.hardware.drm-service-lazy.widevine.rc \
    $(LOCAL_PATH)/addon/manifest_android.hardware.drm-service.widevine.xml:$(TARGET_COPY_OUT_RECOVERY)/root/system/etc/los-tv-addon/manifest_android.hardware.drm-service.widevine.xml \
    $(LOCAL_PATH)/addon/privapp-permissions-com.android.vending.xml:$(TARGET_COPY_OUT_RECOVERY)/root/system/etc/los-tv-addon/privapp-permissions-com.android.vending.xml \
    $(LOCAL_PATH)/addon/links.txt:$(TARGET_COPY_OUT_RECOVERY)/root/system/etc/los-tv-addon/links.txt \
    $(LOCAL_PATH)/addon/links.txt:$(TARGET_COPY_OUT_SYSTEM)/etc/los-tv-addon/links.txt \
    $(LOCAL_PATH)/addonapp/privapp-permissions-org.los.tv.addon.xml:$(TARGET_COPY_OUT_SYSTEM)/etc/permissions/privapp-permissions-org.los.tv.addon.xml \
    $(if $(wildcard $(PRODUCT_DIR)init.fstab.sh),$(PRODUCT_DIR),$(LOCAL_PATH)/)init.fstab.sh:$(TARGET_COPY_OUT_RECOVERY)/root/system/etc/init.fstab.sh \

PRODUCT_TAGS += dalvik.gc.type-precise

PRODUCT_OTA_ENFORCE_VINTF_KERNEL_REQUIREMENTS := false
PRODUCT_ENFORCE_VINTF_MANIFEST_OVERRIDE := true

# AAPT
ifeq ($(USE_TV_BUILD), true)
PRODUCT_CHARACTERISTICS := tv
PRODUCT_AAPT_PREF_CONFIG := tvdpi
else
PRODUCT_CHARACTERISTICS := tablet
PRODUCT_AAPT_CONFIG := normal large xlarge mdpi hdpi
PRODUCT_AAPT_PREF_CONFIG := mdpi
endif

DEVICE_PACKAGE_OVERLAYS := $(LOCAL_PATH)/overlay

ifeq ($(BOARD_IS_GO_BUILD),true)
DEVICE_PACKAGE_OVERLAYS += $(LOCAL_PATH)/overlay-go
endif

# Init
$(call soong_config_set,libinit,vendor_init_lib,//$(LOCAL_PATH):init_x86)

# Force sdcardfs to use esdfs instead
PRODUCT_SYSTEM_DEFAULT_PROPERTIES += \
    ro.sys.sdcardfs=false \
    persist.sys.sdcardfs=force_off

# Copy any Permissions files, overriding anything if needed
$(foreach f,$(wildcard $(LOCAL_PATH)/permissions/*.xml),\
    $(eval PRODUCT_COPY_FILES += $(f):$(TARGET_COPY_OUT_SYSTEM_EXT)/etc/permissions/$(notdir $f)))

# Get emulated storage settings
#$(call inherit-product, $(SRC_TARGET_DIR)/product/emulated_storage.mk)

# Get Android 8.0 HIDL HALs
$(call inherit-product,$(LOCAL_PATH)/treble.mk)

# Get the touchscreen calibration tool
$(call inherit-product-if-exists,external/tslib/tslib.mk)

# Get the alsa files
$(call inherit-product-if-exists,hardware/libaudio/alsa.mk)

# Get GPS configuration
$(call inherit-product-if-exists,device/common/gps/gps_as.mk)

# Get the hardware acceleration libraries
$(call inherit-product-if-exists,$(LOCAL_PATH)/gpu/gpu_mesa.mk)

# Get the sensors hals
$(call inherit-product-if-exists,hardware/libsensors/sensors.mk)

# Get GloDroid components
$(call inherit-product-if-exists,$(LOCAL_PATH)/glodroid/device_glodroid.mk)

ifeq ($(USE_LIBNDK_TRANSLATION_NB),true)
$(call inherit-product-if-exists, vendor/google/emu-x86/target/native_bridge_arm_on_x86.mk)
NDK_TRANSLATION_PREINSTALL := google
PRODUCT_SYSTEM_DEFAULT_PROPERTIES += persist.sys.nativebridge=1
endif

ifeq ($(USE_CROS_HOUDINI_NB),true)
$(call inherit-product-if-exists, vendor/google/chromeos-x86/target/houdini.mk)
$(call inherit-product-if-exists, vendor/google/chromeos-x86/target/native_bridge_arm_on_x86.mk)
PRODUCT_SYSTEM_DEFAULT_PROPERTIES += persist.sys.nativebridge=1
endif

ifeq ($(ANDROID_USE_NDK_TRANSLATION),true)
PRODUCT_SYSTEM_DEFAULT_PROPERTIES += persist.sys.nativebridge=1
endif

ifeq ($(ANDROID_USE_INTEL_HOUDINI),true)
$(call inherit-product-if-exists, vendor/intel/proprietary/houdini/houdini.mk)
$(call inherit-product-if-exists, vendor/intel/proprietary/houdini/native_bridge_arm_on_x86.mk)
PRODUCT_SYSTEM_DEFAULT_PROPERTIES += persist.sys.nativebridge=1
endif

$(call inherit-product,$(if $(wildcard $(PRODUCT_DIR)packages.mk),$(PRODUCT_DIR),$(LOCAL_PATH)/)packages.mk)

ifeq ($(BOARD_IS_GO_BUILD),true)
ifeq ($(BOARD_IS_SURFACE_BUILD),true)
$(error "Go build should not be mixed with Surface build")
endif
ifeq ($(BOARD_IS_ZENITH_BUILD),true)
$(error "Go build should not be mixed with Zenith build")
endif
# Inherit common Android Go configurations
$(call inherit-product, build/target/product/go_defaults.mk)
DONT_UNCOMPRESS_PRIV_APPS_DEXS := true
endif

# Surface specific
ifeq ($(BOARD_IS_SURFACE_BUILD),true)
ifeq ($(BOARD_IS_ZENITH_BUILD),true)
$(error "Surface build should not be mixed with Zenith build")
endif
BLISS_SPECIAL_VARIANT := -Surface
endif

# Zenith
ifeq ($(BOARD_IS_ZENITH_BUILD),true)
BLISS_SPECIAL_VARIANT := -Zenith
endif

ifeq ($(USE_WIDEVINE),true)
$(call inherit-product-if-exists, vendor/google/chromeos-x86/target/widevine.mk)
$(call inherit-product-if-exists, vendor/google/proprietary/widevine-prebuilt/widevine.mk)
endif

# Add agp-apps
$(call inherit-product-if-exists, vendor/agp-apps/agp-apps.mk)

ifneq ($(USE_TV_BUILD), true)
# Enable MultiWindow
PRODUCT_PROPERTY_OVERRIDES += \
    persist.sys.debug.multi_window=true \
    persist.sys.debug.desktop_mode=true
endif

# DRM service opt-in
PRODUCT_VENDOR_PROPERTIES += drm.service.enabled=true

PRODUCT_REQUIRES_INSECURE_EXECMEM_FOR_SWIFTSHADER := true

$(call inherit-product-if-exists, hardware/x86power/x86power.mk)

# - force memfd; default ashmem removed
# - speedup first start, otherwise it longs for some hours
# - disable bad bluetooth remotes searching and synchroning at first start. remote that connect at this screen need re-pairing in settings
PRODUCT_PROPERTY_OVERRIDES += \
    sys.use_memfd=true
    pm.dexopt.first-boot=verify \
    pm.dexopt.boot-after-ota=verify \
    pm.dexopt.bg-dexopt=speed-profile \
    ro.setupwizard.mode=DISABLED \
    ro.setupwizard.enterprise=0 \
    setupwizard.feature.baseline_setup=false

# Софтверные видеодекодеры. Без них MediaCodec не имеет ни одного видео-декодера
# (в образе отсутствуют c2.android.avc.decoder / c2.android.hevc.decoder).
PRODUCT_PACKAGES += \
    libcodec2_soft_avcdec \
    libcodec2_soft_hevcdec

# los-tv: native playback capture -> RTP L16 -> audiohub.
PRODUCT_PACKAGES += \
    audio-rtp-sender \
    audio-rtp-sender-rc

# 2026-10-11: HIDL DRM (android.hardware.drm@1.0-service) УДАЛЁН.
# Причина: не может получить passthrough от AIDL-версии, падает с
# "Error while registering drm service" и уходит в цикл перезапуска.
# HIDL и AIDL DRM в этой версии Android несовместимы.

# Первый запуск занимал ~25 мин. Часть свойств ниже конфликтует с
# build/make/target/product/runtime_libart.mk (там стоит =true), поэтому их
# задаём в vendor/build.prop: приоритет чтения system->vendor даст нужное
# значение, а дубликатов в одном файле не будет.
PRODUCT_SYSTEM_PROPERTIES += \
    pm.dexopt.bg-dexopt=verify

PRODUCT_VENDOR_PROPERTIES += \
    dalvik.vm.dexopt.secondary=false \
    dalvik.vm.dex2oat-minidebuginfo=false

# --- BT: «протухшие» бонды пультов после перезагрузки (шаг 34, сборка №23) ---
# Пульты шлют НАПРАВЛЕННУЮ рекламу (ADV_DIRECT_IND) на адрес хоста,
# выученный при спаривании. С включённой LE-privacy хост каждый запуск
# берёт НОВЫЙ случайный адрес (LE_Set_Random_Address) и подключается
# own_type=1 (RPA) → цель рекламы не совпадает с InitA → пульт игнорирует
# CONNECT_IND → 0x3e CONNECTION_FAILED_ESTABLISHMENT, ни одного PDU в ответ.
# Разбор: data/2026-10-18-bt-bonds-snoop-analysis.txt, разд. 8–9.
# false → btif_dm.cc:2356 BTM_BleConfigPrivacy(false) →
# main/shim/acl_api.cc:74 ACL_ConfigureLePrivacy(false) → USE_PUBLIC_ADDRESS:
# хост всегда предъявляет публичный BD_ADDR (08:8a:f1:51:dd:b3).
PRODUCT_VENDOR_PROPERTIES += \
    bluetooth.core.gap.le.privacy.enabled=false

# --- Предустановленные сторонние приложения (2026-10-11) ---
# Описаны в prebuilt/Android.bp через android_app_import с presigned,
# то есть с originalsными подписями издателей.
#
#   FDroid  - магазин FOSS-приложений вместо Google Play
#   YouTube TV / Wink / Кинопоиск - предустановка в /data (base + сплиты)
# NewPipe удалён из сборки 2026-10-28: мобильный UI, на TV не работает.
PRODUCT_PACKAGES += FDroid
PRODUCT_PACKAGES += MicroGGmsCore
# los-tv 2026-10-30: Play Store — только через add-on (priv-app),
# в базовом образе его нет.

# Сторонние APK из prebuilt/ объявляют опциональные uses-library,
# которых нет среди модулей дерева:
#   F-Droid -> androidx.window.extensions, androidx.window.sidecar
#   Wink            -> android.ext.adservices, android.extensions.appfunctions
# У android_app_import нет свойства optional_libs, поэтому сверить их
# нечем, и штатная проверка enforce-uses-libraries падает.
# Отключаем её для всего продукта - это штатный обходной путь AOSP.
PRODUCT_BROKEN_VERIFY_USES_LIBRARIES := true

# --- Widevine L3 DRM, x86_64 (2026-10-12) ---
# Модули описаны в prebuilt/widevine/Android.bp.
# Источники: vendor ChromeOS hatch (CDM, сервис AIDL) + system того же
# образа (libprotobuf-cpp-lite.so). Обоснование и сверка символов —
# в vendor/google/proprietary/widevine-prebuilt/Android.mk и STATE.md.
#
# ВНИМАНИЕ: ставит vendor-копию protobuf поверх системной.
# Проверено статически (361/361 символ), но вживую не проверено.
# los-tv 2026-10-30: Widevine убран из базового образа (add-on).
# $(eval $(call once,widevine-prebuilt-modules,\
#     $(LOCAL_PATH)/../../../vendor/google/proprietary/widevine-prebuilt/Android.mk))

PRODUCT_PACKAGES += \
    lpunpack_dev \
    los-tv-msg \
    los-tv-gpt \
    preinstall-JellyfinTV \
    preinstall-VLC \
    addon-autorestore.sh \
    addon-autorestore-rc \
    los-tv-addon-check.sh \
    los-tv-addon-notify.sh \
    los-tv-addon-state-rc \
    LosTvAddon \
    preinstall-apps.sh \
    preinstall-apps-rc \
    checkin-enabler.sh \
    checkin-enabler-rc \
    play-store-fixups.sh \
    play-store-fixups-rc \
    display-fixups.sh \
    display-fixups-rc \
    tvres-notify.sh \
    tvres-notify-rc

# los-tv: диагностический логгер /dev/kmsg (только для отладки)
PRODUCT_COPY_FILES += \
    $(LOCAL_PATH)/kmsglog/los-tv-kmsglog:$(TARGET_COPY_OUT_SYSTEM)/bin/los-tv-kmsglog \
    $(LOCAL_PATH)/kmsglog/los-tv-kmsglog.rc:$(TARGET_COPY_OUT_SYSTEM)/etc/init/los-tv-kmsglog.rc

# los-tv: перезапуск Bluetooth при переподключении USB HCI-адаптера
PRODUCT_COPY_FILES += \
    $(LOCAL_PATH)/bt_hotplug/bt_hotplug.sh:$(TARGET_COPY_OUT_SYSTEM)/bin/bt_hotplug.sh \
    $(LOCAL_PATH)/bt_hotplug/bt_hotplug.rc:$(TARGET_COPY_OUT_SYSTEM)/etc/init/bt_hotplug.rc

# los-tv: EGL под enforcing (init.sh не может запуститься: init+execute_no_trans запрещён)
PRODUCT_VENDOR_PROPERTIES += ro.hardware.egl=mesa

# los-tv: slow x86 TV hardware; allow PM/boot phases to exceed the
# default 60s watchdog window without killing system_server.
PRODUCT_PROPERTY_OVERRIDES += ro.hw_timeout_multiplier=3

# los-tv: boot animation is enabled (was disabled while debugging the
# enforcing bring-up). debug.sf.nobootanimation=1 must not be set.
