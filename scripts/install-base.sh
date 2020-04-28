#!/usr/bin/env bash

# stop on errors
set -eu

DISK='/dev/vda'
FQDN='amnesiac'
KEYMAP='us'
LANGUAGE='en_US.UTF-8'
PASSWORD=$(/usr/bin/openssl passwd -crypt 'arch')
TIMEZONE='UTC'

CONFIG_SCRIPT='/usr/local/bin/arch-config.sh'
BOOT_PARTITION="${DISK}1"
ROOT_PARTITION="${DISK}2"
BOOT_DIR='/mnt/boot'
TARGET_DIR='/mnt'
COUNTRY=${COUNTRY:-CH}
MIRRORLIST="https://www.archlinux.org/mirrorlist/?country=${COUNTRY}&protocol=http&protocol=https&ip_version=4&use_mirror_status=on"

echo "==> Setting local mirror"
curl -s "$MIRRORLIST" |  sed 's/^#Server/Server/' > /etc/pacman.d/mirrorlist

echo "==> Clearing partition table on ${DISK}"
/usr/bin/sgdisk --zap ${DISK}

echo "==> Destroying magic strings and signatures on ${DISK}"
/usr/bin/dd if=/dev/zero of=${DISK} bs=512 count=2048
/usr/bin/wipefs --all ${DISK}

echo "==> Creating /boot partition on ${DISK}"
/usr/bin/sgdisk --new=1:2M:128M ${DISK} -t 0:EF00

echo "==> Creating /root partition on ${DISK}"
/usr/bin/sgdisk --new=2:0:0 ${DISK} -t 0:8300

echo '==> Creating /boot filesystem (FAT32)'
/usr/bin/mkfs.vfat -F32 -n EFI ${BOOT_PARTITION}

echo '==> Creating /root filesystem (ext4)'
/usr/bin/mkfs.ext4 -O ^64bit -F -m 0 -q -L root ${ROOT_PARTITION}

echo "==> Creating ${BOOT_DIR}"
/usr/bin/mkdir ${BOOT_DIR}

echo "==> Mounting ${BOOT_PARTITION} to ${BOOT_DIR}"
/usr/bin/mount ${BOOT_PARTITION} ${BOOT_DIR}

echo "==> Mounting ${ROOT_PARTITION} to ${TARGET_DIR}"
/usr/bin/mount -o noatime,errors=remount-ro ${ROOT_PARTITION} ${TARGET_DIR}

echo '==> Bootstrapping the base installation'
/usr/bin/pacstrap ${TARGET_DIR} base base-devel
/usr/bin/arch-chroot ${TARGET_DIR} pacman -S --noconfirm linux openssh cloud-utils
echo '==> Installing boot loader'
/usr/bin/arch-chroot ${TARGET_DIR} /usr/bin/bootctl --path=/boot install

echo '==> Creating boot loader entry'
/usr/bin/mkdir -p ${BOOT_DIR}/loader/entries/
cat <<-EOF > "${BOOT_DIR}/loader/entries/arch.conf
title   Arch Linux
linux   /vmlinuz-linux
initrd  /initramfs-linux.img
options root=/dev/vda2 rw
EOF

echo '==> Generating the filesystem table'
/usr/bin/genfstab -p ${TARGET_DIR} >> "${TARGET_DIR}/etc/fstab"

echo '==> Generating the system configuration script'
/usr/bin/install --mode=0755 /dev/null "${TARGET_DIR}${CONFIG_SCRIPT}"

cat <<-EOF > "${TARGET_DIR}${CONFIG_SCRIPT}"
	echo '${FQDN}' > /etc/hostname
	/usr/bin/ln -s /usr/share/zoneinfo/${TIMEZONE} /etc/localtime
	echo 'KEYMAP=${KEYMAP}' > /etc/vconsole.conf
	/usr/bin/sed -i 's/#${LANGUAGE}/${LANGUAGE}/' /etc/locale.gen
	/usr/bin/locale-gen
	/usr/bin/mkinitcpio -p linux
	/usr/bin/usermod --password ${PASSWORD} root
	# https://wiki.archlinux.org/index.php/Network_Configuration#Device_names
	/usr/bin/ln -s /dev/null /etc/udev/rules.d/80-net-setup-link.rules
	/usr/bin/ln -s '/usr/lib/systemd/system/dhcpcd@.service' '/etc/systemd/system/multi-user.target.wants/dhcpcd@eth0.service'
	/usr/bin/sed -i 's/#UseDNS yes/UseDNS no/' /etc/ssh/sshd_config
	/usr/bin/systemctl enable sshd.service
        /usr/bin/systemctl enable systemd-timesyncd.service

	# Workaround for https://bugs.archlinux.org/task/58355 which prevents sshd to accept connections after reboot
	/usr/bin/pacman -S --noconfirm rng-tools
	/usr/bin/systemctl enable rngd

EOF

echo '==> Entering chroot and configuring system'
/usr/bin/arch-chroot ${TARGET_DIR} ${CONFIG_SCRIPT}
rm "${TARGET_DIR}${CONFIG_SCRIPT}"

# http://comments.gmane.org/gmane.linux.arch.general/48739
echo '==> Adding workaround for shutdown race condition'
/usr/bin/install --mode=0644 /root/poweroff.timer "${TARGET_DIR}/etc/systemd/system/poweroff.timer"

echo '==> Installation complete!'
/usr/bin/sleep 3
/usr/bin/umount ${BOOT_DIR}
/usr/bin/umount ${TARGET_DIR}
# Turning network interfaces down to make sure SSH session was dropped on host.
# More info at: https://www.packer.io/docs/provisioners/shell.html, section - Handling reboots
echo '==> Turning down network interfaces and rebooting'
for i in $(/usr/bin/netstat -i | /usr/bin/tail +3 | /usr/bin/awk '{print $1}'); do /usr/bin/ip link set ${i} down; done
echo '==> Pacman cleanup'
/usr/bin/yes | /usr/bin/pacman -Scc
/usr/bin/systemctl shutdown
