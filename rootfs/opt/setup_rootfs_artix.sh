#!/bin/bash

#setup the artix linux rootfs
#this is meant to be run within the chroot created by build_rootfs.sh
#artix is arch-based and systemd-free; this script configures it to use openrc,
#following the same general shape as setup_rootfs_alpine.sh

DEBUG="$1"
set -e
if [ "$DEBUG" ]; then
  set -x
fi

release_name="$2" #unused for artix, which is rolling-release, kept for arg compat
packages="$3"
hostname="$4"
root_passwd="$5"
username="$6"
user_passwd="$7"
enable_root="$8"
disable_base_pkgs="$9"
arch="${10}"

export PACMAN="pacman --noconfirm --needed"

#set hostname
echo "$hostname" > /etc/hostname
cat >> /etc/hosts << END
127.0.0.1 localhost
127.0.1.1 ${hostname}
::1       localhost ip6-localhost ip6-loopback
END

#refresh package databases; the repos/keyring setup was already done by build_rootfs.sh
$PACMAN -Syy || true

#translate the generic "task-$desktop-desktop" convention used elsewhere in shimboot
#into real artix/arch package names, since there's no setup-desktop style helper here
install_desktop() {
  local desktop="$1"
  case "$desktop" in
    xfce)            $PACMAN -S xfce4 xfce4-goodies lightdm lightdm-gtk-greeter ;;
    gnome)            $PACMAN -S gnome gnome-extra lightdm lightdm-gtk-greeter ;;
    gnome-flashback)  $PACMAN -S gnome-flashback gnome-session lightdm lightdm-gtk-greeter ;;
    kde|plasma)       $PACMAN -S plasma kde-applications sddm ;;
    lxde)             $PACMAN -S lxde lightdm lightdm-gtk-greeter ;;
    lxqt)             $PACMAN -S lxqt sddm ;;
    cinnamon)         $PACMAN -S cinnamon lightdm lightdm-gtk-greeter ;;
    mate)             $PACMAN -S mate mate-extra lightdm lightdm-gtk-greeter ;;
    *)
      print_error_fallback="1"
      ;;
  esac
  if [ "$print_error_fallback" ]; then
    echo "unrecognized desktop '$desktop', installing the packages literally instead"
    $PACMAN -S $desktop
  fi
}

if echo "$packages" | grep "task-" >/dev/null; then
  desktop="$(echo $packages | cut -d'-' -f2)"
  install_desktop "$desktop"
  display_manager_installed="1"
else
  $PACMAN -S $packages
fi

#enable the display manager if we installed one above
for dm in lightdm sddm; do
  if pacman -Qq "$dm" >/dev/null 2>&1; then
    rc-update add "$dm" default
    break
  fi
done

#enable core openrc services. artix uses eudev (not mdev/busybox like alpine), so the
#service names differ slightly from setup_rootfs_alpine.sh
rc-update add acpid default
rc-update add bootmisc boot
rc-update add cronie default
rc-update add devfs sysinit
rc-update add dmesg sysinit
rc-update add hostname boot
rc-update add hwclock boot
rc-update add killprocs shutdown
rc-update add udev sysinit
rc-update add udev-trigger sysinit
rc-update add udev-settle sysinit
rc-update add udev-postmount default
rc-update add mount-ro shutdown
rc-update add swap boot
rc-update add syslog-ng default 2>/dev/null || rc-update add syslog default 2>/dev/null || true

#kill frecon, same as the other distros' setup scripts
echo "#!/sbin/openrc-run

command=\"/usr/bin/pkill\"
command_args=\"frecon-lite\"
command_background=\"no\"
" > /etc/init.d/kill-frecon
chmod +x /etc/init.d/kill-frecon
rc-update add kill-frecon boot

#openrc doesn't read /etc/modules-load.d, so port those over to /etc/conf.d/modules
if [ -d /etc/modules-load.d ]; then
  module_files="$(ls /etc/modules-load.d 2>/dev/null)"
  modules_list=""
  for mod_file in $module_files; do
    modules_list="$modules_list $(grep -v '^#' "/etc/modules-load.d/$mod_file")"
  done
  if [ "$modules_list" ]; then
    echo "modules=\"$modules_list\"" >> /etc/conf.d/modules
    rc-update add modules boot
  fi
fi

#install base packages
if [ -z "$disable_base_pkgs" ]; then
  $PACMAN -S elogind networkmanager network-manager-applet wpa_supplicant \
    polkit sudo zram-generator cloud-utils-growpart nano mousepad \
    dhcpcd base-devel

  rc-update add NetworkManager default
  rc-update add elogind boot
  rc-update add dbus default

  #basic zram swap config, roughly matching the other distros' setup
  mkdir -p /etc/systemd/zram-generator.conf.d
  echo -e "[zram0]\nzram-size = ram / 2\ncompression-algorithm = lzo" \
    > /etc/zram-generator.conf

  mkdir -p /etc/NetworkManager/conf.d
  echo -e "[main]\nauth-polkit=false" > /etc/NetworkManager/conf.d/any-user.conf
fi

#set up the unprivileged user
if [ ! "$username" ]; then
  read -p "Enter the username for the user account: " username
fi
useradd -m -s /bin/bash "$username"
usermod -a -G wheel,network,storage,power "$username" 2>/dev/null || true
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
if ! grep -q "^%wheel ALL=(ALL:ALL) ALL" /etc/sudoers; then
  echo "%wheel ALL=(ALL:ALL) ALL" >> /etc/sudoers
fi

set_password() {
  local user="$1"
  local password="$2"
  if [ ! "$password" ]; then
    while ! passwd "$user"; do
      echo "Failed to set password for $user, please try again."
    done
  else
    yes "$password" | passwd "$user"
  fi
}

if [ "$enable_root" ]; then
  echo "Enter a root password:"
  set_password root "$root_passwd"
fi

echo "Enter a user password:"
set_password "$username" "$user_passwd"

#clean pacman cache
pacman -Scc --noconfirm || true

#enable bash greeter, same as the other distros
echo "/usr/local/bin/shimboot_greeter" >> "/home/$username/.bashrc"
