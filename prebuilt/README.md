# Предустановленные APK (2026-10-11; сплиты и версии — 2026-10-28)

| Файл(ы) | Пакет | Версия | Источник | Лицензия |
|---|---|---|---|---|
| F-Droid.apk | org.fdroid.fdroid | стабильная | https://f-droid.org/F-Droid.apk | GPL-3.0-or-later |
| JellyfinTV.apk | org.jellyfin.androidtv | 0.19.10 (191099) | https://f-droid.org/repo/org.jellyfin.androidtv_191099.apk, sha256 `8510a517c99927076082917f41bf306dd7a2546c59d492dd11bde18d6e2e4628` | GPL-2.0-or-later |
| VLC-x86_64.apk | org.videolan.vlc | 3.7.1 (13070108) | https://download.videolan.org/pub/videolan/vlc-android/last/, sha256 `4646633ede40c4784c5584087cffc5c60cc45b16966ae0b36cedd784d7c4a11e` | GPL-3.0 |
| microG-GmsCore.apk | com.google.android.gms | 0.3.17.252432 (252432034) | https://github.com/microg/GmsCore/releases, sha256 `e5e6cba078bdec812b5450599350e5c1a12c8b7438da5bf77123af170f8c1a35` | Apache-2.0 |

Подписи не перевыпускаются (`presigned: true`).

NewPipe удалён из сборки 2026-10-28: мобильный интерфейс, на TV не работает.
На уже установленных устройствах он остаётся и не затрагивается обновлением.

2026-10-29: YouTube TV, Wink и Кинопоиск убраны из базового образа. YouTube TV
без NDK translation не запускается (arm64-only), а Wink/Кинопоиску нужен
Widevine. Они ставятся из Play Store после установки add-on с проприетарными
компонентами; в базе остаются только открытые приложения (Jellyfin, VLC,
F-Droid). Удаление из ISO не удаляет приложения с уже установленных устройств.

## Почему приложения в /data, а не в /system

Системное приложение нельзя нормально удалить, оно не обновляется из внешнего
источника, а APK со сжатыми `.so` в `/system/app` не запускается. Поэтому
`preinstall-apps.sh` при первом старте ставит их обычными приложениями в
`/data/app`, сохраняя подписи издателей.

## Почему несколькими файлами (base + split)

Play Store отдаёт бандлы: базовая часть и сплиты ABI/плотности/языка.
В манифестах есть `requiredSplitTypes` (`base__abi`, `base__density`), поэтому
одиночный `base.apk` даёт `INSTALL_FAILED_MISSING_SPLIT`. Скрипт ставит весь
набор одним `pm install`.

- Jellyfin и VLC ставятся одиночными APK (F-Droid и VideoLAN публикуют готовые
  сборки); VLC берётся в варианте x86_64, без универсального ARM-хвоста.

## Обновление

F-Droid обновляется на месте из своего репозитория — для этого подпись и
должна оставаться оригинальной.

YouTube TV, Wink и Кинопоиск обновляются из Play Store на устройстве.
Чтобы ISO нёс актуальные версии, APK снимаются с рабочего устройства:

```
adb shell pm path <package>
adb pull <path> ...
```

и заменяются файлы в `user/` + имена модулей в `Android.bp` (если меняется
набор сплитов).

## APK не хранятся в git

Проприетарные и крупные APK исключены из репозитория (см. `.gitignore`).
Скачайте их по ссылкам выше и положите в `prebuilt/` (F-Droid, microG,
Jellyfin, VLC). Play Store в базовый образ не входит — его ставит add-on
из APK пользователя.
