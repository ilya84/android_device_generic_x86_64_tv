#
# Copyright (C) 2014 The Android-x86 Open Source Project
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

#todays real target - tv build. setting this permanently
USE_TV_BUILD := true
PRODUCT_RECOVERY_DENSITY := xhdpi
PRODUCT_RECOVERY_DPI := 213

# Inherit from those products. Most specific first.
$(call inherit-product,$(SRC_TARGET_DIR)/product/core_64_bit_only.mk)
# 2026-10-11: full_base.mk убран — возвращал мобильные приложения (Trebuchet/Contacts/DeskClock/Telecom)

# TV config
ifeq ($(USE_TV_BUILD), true)
$(call inherit-product, device/google/atv/products/atv_base.mk)

TARGET_ATV_FORCE_1080_SCALING := false
$(call inherit-product, vendor/lineage/config/common_tv.mk)
$(call inherit-product, device/generic/x86_64_tv/device.mk)


endif

# Inherit lowram TV config for Go build
ifeq ($(USE_TV_LOWRAM), true)

BOARD_IS_GO_BUILD := true
$(call inherit-product, device/google/atv/products/atv_lowram_defaults.mk)
PRODUCT_PACKAGES += \
    TvLowRamOverlay

endif

# Inherit some common Lineage stuff.
$(call inherit-product, vendor/lineage/config/common_full_tv.mk)

# Include from Android-x86 device
BOARD_IS_ZENITH_BUILD :=true
# --- NDK translation Google: ARM64 -> x86_64 (2026-10-13) ---
# Здесь, а не в device.mk: в начале device.mk include ломает LOCAL_PATH
# (падает release_config), в конце — PRODUCT_COPY_FILES уже только для
# чтения. Здесь фаза записи PRODUCT_* ещё открыта.
# los-tv 2026-10-30: NDK translation убран из базового образа (add-on).
# include vendor/google/proprietary/ndk_translation-prebuilt/native_bridge_arm_on_x86.mk

$(call inherit-product,$(LOCAL_PATH)/device.mk)

# Overrides
PRODUCT_NAME := lineage_x86_64_tv
PRODUCT_BRAND := Android-x86_TV
PRODUCT_DEVICE := x86_64_tv
PRODUCT_MODEL := Generic Android-x86_64 TV

PRODUCT_PACKAGES := $(filter-out \
    Recorder \
    Dialer \
    SubsystemTelephony \
    TelephonyProvider \
    Contacts \
    CellBroadcastReceiver \
    CellBroadcastServiceModule \
    NfcNci \
    ContactsProviderPicker \
    MmsService \
    CellBroadcastService \
    Stk \
    Telecom \
    Aperture \
    DeviceAsWebcam \
    EmergencyInfo \
    Messaging \
    Launcher3 \
    Launcher3QuickStep \
    Settings \
    SettingsIntelligence \
    TeleService \
    Contacts \
    DeskClock,$(PRODUCT_PACKAGES))
