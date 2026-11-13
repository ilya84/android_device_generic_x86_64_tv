#
# Copyright (C) 2024 BlissLabs
#
# License: GNU Public License v2 or later
#

function set_property()
{
	setprop "$1" "$2"
	[ -n "$DEBUG" ] && echo "$1"="$2" >> /dev/x86.prop
}

function set_prop_if_empty()
{
	[ -z "$(getprop $1)" ] && set_property "$1" "$2"
}

function init_graphics()
{
	# Loop with a timeout (e.g., 20 attempts, 0.5s each = 10 seconds max)
	for attempt in $(seq 1 20); do
		for i in $(seq 0 9); do
			if [ -c "/dev/dri/card$i" ]; then
				local driver_name=""
				
				if [ -L "/sys/class/drm/card$i/device/driver" ]; then
					driver_name=$(basename $(readlink /sys/class/drm/card$i/device/driver))
				elif [ -f "/sys/class/drm/card$i/device/uevent" ]; then
					driver_name=$(grep DRIVER= /sys/class/drm/card$i/device/uevent | cut -d= -f2)
				fi

				# Ignore simple framebuffers or unpopulated sysfs entries
				if [[ "$driver_name" == *simple* ]] || [ -z "$driver_name" ]; then
					if [ "$HWACCEL" != "0" ]; then
						continue
					fi
				fi

				break 2
			fi
		done
		sleep 0.5
	done

	if [ "$HWACCEL" == "0" ]; then
		set_property ro.minui.graphics_backend fbdev
	fi

	# Wait for Framebuffer device
	local fb_node="fb0"
	for attempt in $(seq 1 20); do
		for j in $(seq 0 9); do
			# Check if the driver symlink is populated
			if [ -L "/sys/class/graphics/fb$j/device/driver" ]; then
				local fb_driver_name=$(basename $(readlink /sys/class/graphics/fb$j/device/driver))

				# Ignore simple framebuffers or unpopulated sysfs entries
				if [[ "$fb_driver_name" == *simple* ]] || [ -z "$fb_driver_name" ]; then
					if [ "$HWACCEL" != "0" ]; then
						continue
					fi
				fi

				fb_node="fb$j"
				break 2
			fi
		done
		sleep 0.5
	done

	case "$(readlink /sys/class/graphics/$fb_node/device/driver)" in
		*i915)
			set_property ro.minui.pixel_format RGBX_8888
			;;
		*amdgpu)
			set_property ro.minui.pixel_format ARGB_8888
			;;
		*vmwgfx)
			set_property ro.minui.pixel_format BGRX_8888
			;;
		*)
			;;
	esac
}

function init_misc()
{
	# Tell vold to use ntfs3 driver instead of ntfs-3g
    if [ "$USE_NTFS3" -ge "1" ] || [ "$VOLD_USE_NTFS3" -ge 1 ]; then
        set_property ro.vold.use_ntfs3 true
    fi

    set_property service.adb.tcp.port ${DEBUG_NET_PORT:-5555}
    # los-tv step42: force adbd for network sideload. copy_userdata_files()
    # copies /data/misc/adb/adb_keys to /adb_keys and enables adb root.
    set_property recovery.adb.enabled 1
    set_property sys.recovery.copy_userdata true
}

function init_recovery_device_link()
{
	# Insert /data to recovery.fstab
	if grep -E '^[[:space:]]*[^#].+ /data ' "$(ls /fstab.*)" >> /etc/recovery.fstab; then
		set_property sys.recovery.data_is_part true
	fi

	# Insert /system into recovery.fstab
	if [ "$(getprop ro.boot.slot_suffix)" ]; then
		echo "/dev/block/by-name/system     /system   ext4    defaults        slotselect,first_stage_mount" >> /etc/recovery.fstab
	else
		echo "/dev/block/by-name/system     /system   ext4    defaults        defaults" >> /etc/recovery.fstab
	fi

	# Create /dev/block/bootdevice/by-name
	# because some scripts are dumb
	mkdir -p /dev/block/bootdevice
	ln -s /dev/block/by-name /dev/block/bootdevice/by-name
}

function do_netconsole()
{
	modprobe netconsole netconsole="@/,@$(getprop dhcp.eth0.gateway)/"
}

function init_recovery_eth()
{
	# los-tv step41: ignore_first_eth skips the lowest-numbered eth*
	# interface and selects the next one (for systems with two NICs).
	[ -n "$IGNORE_FIRST_ETH" ] || return 0

	# USB NICs may enumerate slightly after post-fs; wait briefly.
	local tries=0 count n
	while [ "$tries" -lt 5 ]; do
		count=0
		n=0
		while [ "$n" -le 31 ]; do
			[ -e "/sys/class/net/eth$n" ] && count=$((count + 1))
			n=$((n + 1))
		done
		[ "$count" -ge 2 ] && break
		sleep 1
		tries=$((tries + 1))
	done

	local first=1 iface=
	n=0
	while [ "$n" -le 31 ]; do
		if [ -e "/sys/class/net/eth$n" ]; then
			if [ "$first" -eq 1 ]; then
				first=0
			else
				iface="eth$n"
				break
			fi
		fi
		n=$((n + 1))
	done

	if [ -n "$iface" ]; then
		set_property vendor.recovery.ethernet.dhcp.iface "$iface"
		[ -n "$DEBUG" ] && echo "ignore_first_eth: using $iface" >> /dev/x86.prop
		[ -e /dev/kmsg ] && echo "ignore_first_eth: using $iface" > /dev/kmsg
	else
		set_property vendor.recovery.ethernet.dhcp.iface none
		[ -n "$DEBUG" ] && echo "ignore_first_eth: no second eth interface" >> /dev/x86.prop
		[ -e /dev/kmsg ] && echo "ignore_first_eth: no second eth interface" > /dev/kmsg
	fi
}

function init_recovery_rndis()
{
	# los-tv step45: RNDIS (USB-tethering) support for recovery networking.
	# Use case: no Ethernet on site — update the box via a phone with
	# USB-tethering enabled (plug the phone in BEFORE rebooting to recovery;
	# Android phones expose an RNDIS interface in tethering mode).
	# usbnet and mii are built into this kernel (modules.builtin); only
	# cdc_ether and rndis_host are modules, shipped inside the recovery
	# rootfs at /system/lib/modules by the device tree overlay
	# (device/generic/x86_64_tv/recovery/root/system/lib/modules).
	# After loading, init brings up usb0 and starts dhcpclient on it via the
	# vendor.recovery.rndis.iface trigger in init.recovery.x86.rc.
	local k m loaded=""

	for m in cdc_ether rndis_host; do
		# insmod from the recovery ramdisk first, then from the real /system
		# as a fallback (it may be mounted on top of the ramdisk copy).
		loaded=""
		for k in /system/lib/modules/$m.ko \
		         /system/lib/modules/$(uname -r)/kernel/drivers/net/usb/$m.ko; do
			if [ -f "$k" ]; then
				if insmod "$k" >/dev/null 2>&1; then
					loaded="$k"
					[ -e /dev/kmsg ] && echo "rndis: insmod $k ok" >> /dev/kmsg
					break
				fi
				# insmod may fail if the module is already loaded; keep trying.
			fi
		done
		if [ -z "$loaded" ]; then
			[ -e /dev/kmsg ] && echo "rndis: failed to load $m" >> /dev/kmsg
		fi
	done

	# RNDIS interfaces appear only when a tethering phone is connected.
	# Root hubs (usbN) don't count; a phone shows up as 1-1, 2-1.1 etc.
	if ls /sys/bus/usb/devices 2>/dev/null | grep -qE '^[0-9]'; then
		local n=0
		while [ "$n" -lt 6 ]; do
			if [ -e /sys/class/net/usb0 ]; then
				[ -e /dev/kmsg ] && echo "rndis: found usb0, starting DHCP on it" >> /dev/kmsg
				set_property vendor.recovery.rndis.iface usb0
				return 0
			fi
			sleep 1
			n=$((n + 1))
		done
		[ -e /dev/kmsg ] && echo "rndis: usb0 not found (phone tethering absent?)" >> /dev/kmsg
	else
		[ -e /dev/kmsg ] && echo "rndis: no USB devices connected, skipping" >> /dev/kmsg
	fi

	return 0
}

function do_init()
{
	init_graphics
	init_recovery_eth
    init_misc
	init_recovery_device_link
	init_recovery_rndis
}

# import cmdline variables
for c in `cat /proc/cmdline`; do
	case $c in
		BOOT_IMAGE=*|iso-scan/*|*.*=*)
			;;
		nomodeset)
			HWACCEL=0
			;;
		ignore_first_eth)
			IGNORE_FIRST_ETH=1
			;;
		*=*)
			eval $c
			;;
	esac
done

if [ -n "$DEBUG" ]; then
    exec > /tmp/recovery_init.log 2>&1
	set -x
fi


# los-tv: the requested boot mode is consumed by this recovery boot; reset it
# so a plain reboot does not fall back into recovery (MODE is also set for
# CLI reboots by los-tv-boot-mode.sh on shutdown).
function reset_boot_mode()
{
	local cfg
	mkdir -p /mnt/cdrom
	mount -t ext4 /dev/block/by-name/cdrom /mnt/cdrom 2>/dev/null
	for cfg in /mnt/cdrom/boot/grub/android.cfg /boot/grub/android.cfg; do
		[ -f "$cfg" ] || continue
		sed -i "s/^MODE=.*/MODE=normal/" "$cfg" 2>/dev/null
	done
	sync
}

case "$1" in
	netconsole)
		[ -n "$DEBUG" ] && do_netconsole
		;;
	init|"")
		do_init
		reset_boot_mode
		# los-tv: драйвер запускается по флагу GRUB или по запросу из
		# приложения-плитки в Android (.install-request на data-разделе).
		LOSTV_ADDON_RUN=0
		if [ "$(getprop ro.boot.los_tv_addon)" = "1" ]; then
			LOSTV_ADDON_RUN=1
		else
			mkdir -p /mnt/cdrom
			mount -t ext4 /dev/block/by-name/cdrom /mnt/cdrom 2>/dev/null
			if [ -f /mnt/cdrom/data/media/0/los-tv-proprietary/.install-request ]; then
				LOSTV_ADDON_RUN=1
			fi
		fi
		if [ "$LOSTV_ADDON_RUN" = "1" ]; then
			# Пункт GRUB «Установить проприетарные компоненты»: драйвер
			# извлекает компоненты из образов, ставит их в неактивный слот
			# и сам перезагружает устройство.
			# setsid обязателен: фоновый процесс, запущенный из init через
			# exec, иначе умирает вместе с родительской оболочкой (проверено
			# 2026-10-31: скрипт не запускался вовсе).
			echo "los-tv-addon: flag detected, starting driver" > /dev/kmsg
			# Запускаем в foreground: фоновый процесс из init не выживает
			# (проверено 2026-10-31: setsid тоже не помог). init при этом
			# блокируется до конца установки — это нормально, меню recovery
			# всё равно останавливается, а в конце драйвер делает reboot.
			/system/bin/sh /system/bin/los-tv-addon-boot.sh
			echo "los-tv-addon: driver exited rc=$?" > /dev/kmsg
		fi
		;;
esac

return 0
