#!/bin/sh

# Prepare a Debian userland environment suitable for running Electron and other Linux applications
# Based on https://github.com/mrclksr/linux-browser-installer/blob/main/linux-browser-installer
# TODO: poke holes for /usr/share/icons, /usr/share/fonts, and similar directories?
# TODO: Get D-Bus working?

. /etc/rc.subr

prefix=/usr/local
chroot_path=/compat/debian
debian_version=bullseye
ld_version=2.31

bindir="${prefix}/bin"
appsdir="${prefix}/share/applications"
chroot_bindir="${chroot_path}/bin"

apt_packages="gnupg pulseaudio libnss3 libgl1 curl unzip wget binutils libglib2.0-dev libgbm-dev libgtk-3-0 libgtk2.0-0 libxss1 libsecret-1-0 libxkbfile1"
# libsecret-1-0 libxkbfile1 needed by e.g., Arduino IDE 2.0
pkg_list="debootstrap" # pulseaudio would beed to be installed on the target machine, not on the build machine

chroot_mount_points="
/proc
/sys
/dev
/dev/fd
/dev/shm
/tmp
"

unmounted()
{
	[ `stat -f "%d" "$1"` == `stat -f "%d" "$1/.."` -a \
	  `stat -f "%i" "$1"` != `stat -f "%i" "$1/.."` ]
}

debian_start()
{
	local _emul_path _tmpdir

	load_kld -e 'linux(aout|elf)' linux
	case `sysctl -n hw.machine_arch` in
	amd64)
		load_kld -e 'linux64elf' linux64
		;;
	esac
	if [ -x /compat/debian/sbin/ldconfigDisabled ]; then
		_tmpdir=`mktemp -d -t linux-ldconfig`
		/compat/debian/sbin/ldconfig -C ${_tmpdir}/ld.so.cache
		if ! cmp -s ${_tmpdir}/ld.so.cache /compat/debian/etc/ld.so.cache; then
			cat ${_tmpdir}/ld.so.cache > /compat/debian/etc/ld.so.cache
		fi
		rm -rf ${_tmpdir}
	fi

	# Linux uses the pre-pts(4) tty naming scheme.
	load_kld pty

	# Handle unbranded ELF executables by defaulting to ELFOSABI_LINUX.
	if [ `sysctl -ni kern.elf64.fallback_brand` -eq "-1" ]; then
		sysctl kern.elf64.fallback_brand=3 > /dev/null
	fi

	if [ `sysctl -ni kern.elf32.fallback_brand` -eq "-1" ]; then
		sysctl kern.elf32.fallback_brand=3 > /dev/null
	fi
	sysctl compat.linux.emul_path="${chroot_path}"

	_emul_path="${chroot_path}"
	unmounted "${_emul_path}/proc" && (mount -t linprocfs linprocfs "${_emul_path}/proc" || exit 1)
	unmounted "${_emul_path}/sys" && (mount -t linsysfs linsysfs "${_emul_path}/sys" || exit 1)
	unmounted "${_emul_path}/dev" && (mount -t devfs devfs "${_emul_path}/dev" || exit 1)
	unmounted "${_emul_path}/dev/fd" && (mount -o linrdlnk -t fdescfs fdescfs "${_emul_path}/dev/fd" || exit 1)
	unmounted "${_emul_path}/dev/shm" && (mount -o mode=1777 -t tmpfs tmpfs "${_emul_path}/dev/shm" || exit 1)
	unmounted "${_emul_path}/tmp" && (mount -t nullfs /tmp "${_emul_path}/tmp" || exit 1)
	unmounted /dev/fd && (mount -t fdescfs null /dev/fd || exit 1)
	unmounted /proc && (mount -t procfs procfs /proc || exit 1)
	true
}

bail()
{
	if [ $# -gt 0 ]; then
		echo "${0##*/}: Error: $*" >&2
	fi
	exit 1
}

mk_mount_dirs()
{
	local dir p
	for p in ${chroot_mount_points}; do
		dir="${chroot_path}/$p"
		[ ! -d "${dir}" ] && mkdir -p "${dir}"
	done
}

umount_chroot()
{
	local mntpts _chroot_path p _p

	_chroot_path=$(realpath "${chroot_path}")
	[ $? -ne 0 -o -z "${_chroot_path}" ] && exit 1
	mntpts=$(mount -p | awk -F'[ \t]+' -v chroot=${_chroot_path} '
		$2 ~ sprintf("^%s/", chroot) {
			mp[n++] = $2
		}
		END {
			while (--n >= 0) print mp[n]
		}
	')
	for p in ${mntpts}; do
		_p=$(realpath "$p")
		[ $? -ne 0 -o -z "${_p}" ] && exit 1
		umount "${_p}" || exit 1
		if (mount -p | grep -q "${_p}/"); then
			bail "Couldn't unmount ${_p}"
		fi
	done
}

install_steam_utils()
{
	pkg info --exists linux-steam-utils && return
	pkg fetch -y -o /tmp linux-steam-utils || exit 1

	pkgpath=/tmp/All/linux-steam-utils-*.pkg
	[ ! -f ${pkgpath} ] && pkgpath=/tmp/All/linux-steam-utils-*.txz
	[ ! -f ${pkgpath} ] && exit 1
	(cd / && tar -xf ${pkgpath} \
		--exclude '^+COMPACT_MANIFEST' \
		--exclude '^+MANIFEST')
}

install_packages()
{
	for p in ${pkg_list}; do
		pkg info --exists $p && continue
		pkg install -y $p || bail "'pkg install -y $p' failed"
	done
}

fix_ld_path()
{
	(cd ${chroot_path}/lib64 && \
		(unlink ./ld-linux-x86-64.so.2; \
			ln -s ../lib/x86_64-linux-gnu/ld-${ld_version}.so \
			ld-linux-x86-64.so.2))
}

install_apt_packages()
{
	chroot ${chroot_path} /bin/bash -c 'apt update'
	chroot ${chroot_path} /bin/bash -c 'apt remove -y rsyslog'
	for p in ${apt_packages}; do
		chroot ${chroot_path} /bin/bash -c "apt install -y $p" || \
			bail "'apt install -y $p' failed"
	done
}

symlink_icons()
{
	local name i
	[ ! -d ${chroot_path}/usr/share/icons ] && \
		mkdir -p ${chroot_path}/usr/share/icons
	for i in ${prefix}/share/icons/*; do
		[ ! -d $i ] && continue
		name=$(basename $i)
		[ -e ${chroot_path}/usr/share/icons/${name} ] && continue
		ln -s $i ${chroot_path}/usr/share/icons
	done
}

symlink_themes()
{
	local name i
	[ ! -d ${chroot_path}/usr/share/themes ] && \
		mkdir -p ${chroot_path}/usr/share/themes
	for i in ${prefix}/share/themes/*; do
		[ ! -d $i ] && continue
		name=$(basename $i)
		[ -e ${chroot_path}/usr/share/themes/${name} ] && continue
		ln -s $i ${chroot_path}/usr/share/themes
	done
}

set_timezone()
{
	printf "0.0 0 0.0\n0\nUTC\n" > ${chroot_path}/etc/adjtime
	rm -rf "${chroot_path}/etc/localtime"
	if [ ! -d "${chroot_path}/etc/localtime" ]; then
		mkdir -p "${chroot_path}/etc/localtime"
	fi
	ln -s "/usr/share/zoneinfo/$(cat /var/db/zoneinfo)" \
		${chroot_path}/etc/localtime
	chroot ${chroot_path} /bin/bash -c \
		"dpkg-reconfigure --frontend noninteractive tzdata"
}

install_chroot_base()
{
	[ -f ${chroot_path}/etc/os-release ] && return
	mk_mount_dirs
	sysrc linux_enable=NO
	sysrc debian_enable=YES
	debian_start || bail "Failed to start debian service"
	install_steam_utils
	install_packages
	/usr/local/sbin/debootstrap --arch=amd64 --no-check-gpg ${debian_version} ${chroot_path} || \
		bail "debootstrap failed"
	echo "APT::Cache-Start 251658240;" > \
		${chroot_path}/etc/apt/apt.conf.d/00aptitude
	echo "deb http://deb.debian.org/debian ${debian_version} main" > \
		${chroot_path}/etc/apt/sources.list
	fix_ld_path
	set_timezone
	debian_start
	install_apt_packages
	rm "${chroot_path}"/etc/resolv.conf # Will this be sufficient?
	# symlink_icons
	# symlink_themes
}

deinstall_chroot_base()
{
	local path
	path=$(realpath ${chroot_path})
	[ $? -ne 0 ] && exit 1

	if [ "${path}" = "/" ]; then
		echo "chroot_path must not be '/'" >&2
		exit 1
	fi
	umount_chroot
	rm -rf "${path}"
}

upgrade_chroot()
{
	local flags="-q -y --allow-downgrades"
	flags="${flags} --allow-remove-essential --allow-change-held-packages"
	chroot ${chroot_path} /bin/bash -c "apt-get update && apt upgrade ${flags}"
}

cleanup()
{
	rm -f bin/chrome bin/brave chroot/bin/chrome chroot/bin/brave rc.d/debian
}

image()
{
	makefs -o 'label=debian' /tmp/debian.ufs "${chroot_path}"
	mkuzip -A zstd -C 15 -d -s 262144 -o /tmp/debian.img /tmp/debian.ufs
	readlink -f /tmp/debian.img
	ls -lh /tmp/debian.img
}

usage()
{
	echo "Usage: $0 chroot <create|upgrade|delete>"
	echo "       $0 symlink <icons|themes>"
	echo "       $0 clean"
	exit 1
}

if [ $(id -u) -ne 0 ]; then
	echo "This script must be run as root" 1>&2
	exit 1
fi

[ $# -eq 0 ] && usage

while [ $# -gt 0 ]; do
	case "$1" in
	chroot|jail)
		case $2 in
		create)
			install_chroot_base
			exit 0
			;;
		delete)
			deinstall_chroot_base
			exit 0
			;;
		upgrade)
			upgrade_chroot
			exit 0
			;;
		*)
			usage
			;;
		esac
		shift
		;;
	symlink)
		case $2 in
		icons|themes)
			eval symlink_$2
			exit 0
			;;
		*)
			usage
			;;
		esac
		shift
		;;
	*)
		usage
		;;
	esac
	shift
done
