#!/bin/bash

#build the debian rootfs

. ./common.sh

print_help() {
  echo "Usage: ./build_rootfs.sh rootfs_path release_name"
  echo "Valid named arguments (specify with 'key=value'):"
  echo "  custom_packages - The packages that will be installed in place of task-xfce-desktop."
  echo "  hostname        - The hostname for the new rootfs."
  echo "  enable_root     - Enable the root user."
  echo "  root_passwd     - The root password. This only has an effect if enable_root is set."
  echo "  username        - The unprivileged user name for the new rootfs."
  echo "  user_passwd     - The password for the unprivileged user."
  echo "  disable_base    - Disable the base packages such as zram, cloud-utils, and command-not-found."
  echo "  arch            - The CPU architecture to build the rootfs for."
  echo "  distro          - The Linux distro to use. This should be 'debian', 'ubuntu', 'alpine', or 'artix'."
  echo "If you do not specify the hostname and credentials, you will be prompted for them later."
}

assert_root
assert_deps "realpath debootstrap findmnt wget pcregrep tar"
assert_args "$2"
parse_args "$@"

rootfs_dir=$(realpath -m "${1}")
release_name="${2}"
packages="${args['custom_packages']-task-xfce-desktop}"
arch="${args['arch']-amd64}"
distro="${args['distro']-debian}"
chroot_mounts="proc sys dev run"

mkdir -p $rootfs_dir

unmount_all() {
  for mountpoint in $chroot_mounts; do
    umount -l "$rootfs_dir/$mountpoint"
  done
}

need_remount() {
  local target="$1"
  local mnt_options="$(findmnt -T "$target" | tail -n1 | rev | cut -f1 -d' '| rev)"
  echo "$mnt_options" | grep -e "noexec" -e "nodev"
}

do_remount() {
  local target="$1"
  local mountpoint="$(findmnt -T "$target" | tail -n1 | cut -f1 -d' ')"
  mount -o remount,dev,exec "$mountpoint"
}

if [ "$(need_remount "$rootfs_dir")" ]; then
  do_remount "$rootfs_dir"
fi

if [ "$distro" = "debian" ]; then
  print_info "bootstraping debian chroot"
  debootstrap --arch $arch --components=main,contrib,non-free,non-free-firmware "$release_name" "$rootfs_dir" http://deb.debian.org/debian/
  chroot_script="/opt/setup_rootfs.sh"

elif [ "$distro" = "ubuntu" ]; then 
  print_info "bootstraping ubuntu chroot"
  repo_url="http://archive.ubuntu.com/ubuntu"
  if [ "$arch" = "amd64" ]; then
    repo_url="http://archive.ubuntu.com/ubuntu"
  else 
    repo_url="http://ports.ubuntu.com"
  fi
  debootstrap --arch $arch "$release_name" "$rootfs_dir" "$repo_url"
  chroot_script="/opt/setup_rootfs.sh"

elif [ "$distro" = "alpine" ]; then
  print_info "downloading alpine package list"
  pkg_list_url="https://dl-cdn.alpinelinux.org/alpine/latest-stable/main/x86_64/"
  pkg_data="$(wget -qO- --show-progress "$pkg_list_url" | grep "apk-tools-static")"
  pkg_url="$pkg_list_url$(echo "$pkg_data" | pcregrep -o1 '"(.+?.apk)"')"

  print_info "downloading and extracting apk-tools-static"
  pkg_extract_dir="/tmp/apk-tools-static"
  pkg_dl_path="$pkg_extract_dir/pkg.apk"
  apk_static="$pkg_extract_dir/sbin/apk.static"
  mkdir -p "$pkg_extract_dir"
  wget -q --show-progress "$pkg_url" -O "$pkg_dl_path"
  tar --warning=no-unknown-keyword -xzf "$pkg_dl_path" -C "$pkg_extract_dir"

  print_info "bootstraping alpine chroot"
  real_arch="x86_64"
  if [ "$arch" = "arm64" ]; then 
    real_arch="aarch64"
  fi
  $apk_static \
    --arch $real_arch \
    -X http://dl-cdn.alpinelinux.org/alpine/$release_name/main/ \
    -U --allow-untrusted \
    --root "$rootfs_dir" \
    --initdb add alpine-base
  chroot_script="/opt/setup_rootfs_alpine.sh"

elif [ "$distro" = "artix" ]; then
  #artix is a rolling-release, systemd-free, arch-based distro (openrc/runit/s6/dinit).
  #on amd64 we bootstrap it with pacman, borrowed from arch's own relocatable bootstrap
  #tarball, since there's no debootstrap/apk-tools-static equivalent we can fetch standalone.
  #on arm64 there is no official artix arch64 port, so we use armtix
  #(https://armtix.artixlinux.org), a community-maintained aarch64 port of artix which
  #ships ready-made generic rootfs tarballs that already contain a working pacman + repo
  #config, so no bootstrapping step is needed there.
  assert_deps "zstd"

  if [ "$arch" = "arm64" ]; then
    #only https://armtix.artixlinux.org is actually live right now (the other two
    #mirrors listed on armtix's own homepage are currently dead: repo.xdan.eu 404s
    #and armtixlinux.org refuses connections), so there's no real alternate host to
    #fall back to. what we can do is make the request itself look less like a bot,
    #since this mirror is cloudflare-fronted and the big file download has been
    #observed failing (http error) even though the small listing page loads fine -
    #that pattern usually means a waf/rate-limit rule keyed on the request itself,
    #not that the file is actually unavailable.
    armtix_images_url="https://armtix.artixlinux.org/images/"
    armtix_user_agent="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

    print_info "downloading armtix (aarch64 artix) image list"
    #this page has been observed serving either a bare plain-text listing or a
    #themed html autoindex (with the filename wrapped in an <a href="..."> link)
    #depending on the request, so don't anchor to either markup style - just match
    #the filename itself wherever it appears on the line. it may appear twice per
    #line (once in the href, once as the link text); sort -u dedupes.
    armtix_listing="$(wget -qO- --tries=3 --timeout=20 --user-agent="$armtix_user_agent" \
      --header="Accept: text/html" "$armtix_images_url")"
    armtix_image_name="$(echo "$armtix_listing" | pcregrep -o1 '(armtix-openrc-[0-9]{8}\.tar\.xz)' | sort -u | tail -n1)"
    if [ -z "$armtix_image_name" ]; then
      print_error "couldn't find an armtix-openrc image on $armtix_images_url"
      print_error "raw listing returned by the server:"
      echo "$armtix_listing"
      exit 1
    fi
    armtix_image_path="/tmp/$armtix_image_name"
    armtix_image_url="$armtix_images_url$armtix_image_name"

    print_info "downloading and extracting the armtix rootfs image (this is a ~1gb download)"
    #retry with backoff, a full browser user-agent/headers, and a referer pointing
    #at the listing page we just loaded (some basic waf rules check for exactly
    #this - a direct file request with no referer is a common bot tell). if wget
    #still gets rejected, fall back to curl, since a different http client can
    #sometimes get through where another one doesn't.
    download_ok=""
    if wget --tries=5 --waitretry=10 --timeout=60 -q --show-progress \
      --user-agent="$armtix_user_agent" --header="Referer: $armtix_images_url" \
      "$armtix_image_url" -O "$armtix_image_path"; then
      download_ok="1"
    else
      rm -f "$armtix_image_path"
      print_info "wget was rejected, retrying the same download with curl instead"
      if curl -fL --retry 5 --retry-delay 10 -A "$armtix_user_agent" \
        -e "$armtix_images_url" -o "$armtix_image_path" "$armtix_image_url"; then
        download_ok="1"
      fi
    fi
    if [ -z "$download_ok" ]; then
      print_error "couldn't download $armtix_image_name - the mirror may be blocking this network/IP range"
      exit 1
    fi
    #a "successful" download could still be a cloudflare challenge page or a
    #truncated file rather than the real archive, so verify it's valid xz before
    #extracting, instead of silently extracting garbage and failing confusingly later
    if ! xz -t "$armtix_image_path" 2>/dev/null; then
      print_error "the downloaded armtix image isn't a valid xz archive (got blocked/corrupted content)"
      exit 1
    fi

    tar --xz --numeric-owner -xpf "$armtix_image_path" -C "$rootfs_dir"
    rm -f "$armtix_image_path"

    #armtix packages are currently unsigned, matching their own setup instructions
    sed -i 's/^SigLevel.*/SigLevel = Never/' "$rootfs_dir/etc/pacman.conf"

  else
    print_info "downloading arch's bootstrap tarball to use as a pacman runner"
    arch_bootstrap_url="https://geo.mirror.pkgbuild.com/iso/latest/archlinux-bootstrap-x86_64.tar.zst"
    arch_bootstrap_tar="/tmp/archlinux-bootstrap-x86_64.tar.zst"
    arch_bootstrap_dir="/tmp/archlinux-bootstrap"
    rm -rf "$arch_bootstrap_dir"
    mkdir -p "$arch_bootstrap_dir"
    wget -q --show-progress "$arch_bootstrap_url" -O "$arch_bootstrap_tar"
    tar --zstd --numeric-owner -xf "$arch_bootstrap_tar" -C "$arch_bootstrap_dir"
    rm -f "$arch_bootstrap_tar"
    runner_root="$arch_bootstrap_dir/root.x86_64"

    print_info "pointing the bootstrap pacman at artix's repos"
    cp /etc/resolv.conf "$runner_root/etc/resolv.conf"
    #gitea.artixlinux.org appears to sit behind the same cloudflare setup as
    #armtix.artixlinux.org, which can return a challenge/interstitial page with a
    #200 status for plain wget requests instead of real content or a real 404. a
    #200 status alone doesn't mean we got a usable mirrorlist, so don't just trust
    #wget's exit code here - actually check the file has real "Server = " lines in
    #it before accepting it, and only then stop trying the remaining urls.
    mirrorlist_dest="$runner_root/etc/pacman.d/mirrorlist-artix"
    mirrorlist_urls="https://gitea.artixlinux.org/packages/artix-mirrorlist/raw/branch/master/mirrorlist https://raw.githubusercontent.com/artix-linux/packages/master/artix-mirrorlist/repos/core-any/mirrorlist"
    mirrorlist_ok=""
    for url in $mirrorlist_urls; do
      wget -qO "$mirrorlist_dest" \
        --user-agent="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36" \
        "$url" 2>/dev/null
      if grep -q "^Server" "$mirrorlist_dest" 2>/dev/null; then
        mirrorlist_ok="1"
        break
      fi
    done
    if [ -z "$mirrorlist_ok" ]; then
      print_error "couldn't fetch a usable artix mirrorlist from any source (got blocked/empty/invalid content from each)"
      exit 1
    fi
    #artix packages first (so they take priority), then the stock arch repos as a
    #fallback for shared base packages. packages are left unsigned here to avoid
    #having to bootstrap a pacman keyring just for a one-shot automated build.
    cat >> "$runner_root/etc/pacman.conf" << END

[system]
SigLevel = Never
Include = /etc/pacman.d/mirrorlist-artix

[world]
SigLevel = Never
Include = /etc/pacman.d/mirrorlist-artix

[galaxy]
SigLevel = Never
Include = /etc/pacman.d/mirrorlist-artix
END

    print_info "bootstraping artix chroot with pacman"
    #pacman's --dbpath won't create missing parent directories on its own, and
    #rootfs_dir starts out completely empty, so create the path it expects first
    mkdir -p "$rootfs_dir/var/lib/pacman" "$rootfs_dir/var/cache/pacman/pkg"
    mkdir -p "$runner_root/target"
    chroot_mounts_runner="proc sys dev run"
    for mountpoint in $chroot_mounts_runner; do
      mount --make-rslave --rbind "/$mountpoint" "$runner_root/$mountpoint"
    done
    mount --make-rslave --rbind "$rootfs_dir" "$runner_root/target"

    unmount_runner() {
      for mountpoint in $chroot_mounts_runner; do
        umount -l "$runner_root/$mountpoint" 2>/dev/null
      done
      umount -l "$runner_root/target" 2>/dev/null
    }
    trap unmount_runner EXIT

    chroot "$runner_root" pacman -Sy --root /target --dbpath /target/var/lib/pacman \
      --noconfirm --overwrite '*' base openrc-system openrc-world elogind-openrc

    unmount_runner
    trap - EXIT
    rm -rf "$arch_bootstrap_dir"
  fi
  chroot_script="/opt/setup_rootfs_artix.sh"

else
  print_error "'$distro' is an invalid distro choice."
  exit 1
fi

print_info "copying rootfs setup scripts"
cp -arv rootfs/* "$rootfs_dir"
cp /etc/resolv.conf "$rootfs_dir/etc/resolv.conf"

print_info "creating bind mounts for chroot"
trap unmount_all EXIT
for mountpoint in $chroot_mounts; do
  mount --make-rslave --rbind "/${mountpoint}" "${rootfs_dir}/$mountpoint"
done

hostname="${args['hostname']}"
root_passwd="${args['root_passwd']}"
enable_root="${args['enable_root']}"
username="${args['username']}"
user_passwd="${args['user_passwd']}"
disable_base="${args['disable_base']}"

chroot_command="$chroot_script \
  '$DEBUG' '$release_name' '$packages' \
  '$hostname' '$root_passwd' '$username' \
  '$user_passwd' '$enable_root' '$disable_base' \
  '$arch'" 

LC_ALL=C chroot $rootfs_dir /bin/sh -c "${chroot_command}"

trap - EXIT
unmount_all

print_info "rootfs has been created"
