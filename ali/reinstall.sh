#!/bin/sh
# shellcheck shell=ash
# SPDX-License-Identifier: GPL-3.0-or-later
# Alibaba Cloud ECS: Alpine -> Alpine, x86_64, BIOS, one IPv4 DHCP NIC.
set -eu
set -o pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C
umask 077

RELEASE=3.24.1
BRANCH=v3.24
ISO_SHA256=e73a6241bd5f3c5c2d4d38c02cc52c378c0415a7c888bd292066bf36e0f41a39
SCRIPT_SHA256=52b78c791a05c919c54a37c4ea777e90f743e0465586e6841a18a1ef7ead8c82
INSTALLER_SHA256=e7763999ba907450cd15a665e118f728272c7e0724b1388e53e2b200a1a3f81e
STAGE=/boot/alpine-reinstall
LOCK=/run/alpine-reinstall.lock
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
script_file=$script_dir/${0##*/}
work=; pending=; lock_owned=no

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
verify_manifest() (
    cd "$1"
    names=$2
    [ -f SHA256SUMS ] && [ ! -L SHA256SUMS ] || die 'Missing SHA256SUMS.'
    awk -v names="$names" '
        BEGIN { count = split(names, files, " ") }
        NF != 2 || length($1) != 64 || $1 ~ /[^0-9a-f]/ || $2 != files[NR] { exit 1 }
        END { if (NR != count) exit 1 }
    ' SHA256SUMS || die 'Invalid or incomplete checksum manifest.'
    for name in $names; do
        [ -f "$name" ] && [ ! -L "$name" ] || die "Invalid checksummed file: $name"
    done
    sha256sum -c SHA256SUMS >/dev/null || die 'File integrity check failed.'
)
verify_installer() {
    printf '%s  %s\n' "$INSTALLER_SHA256" "$1" | sha256sum -c - >/dev/null || die 'Installer differs from the pinned release.'
}
verify_release() {
    [ "${0##*/}" = reinstall.sh ] && [ -f "$script_file" ] && [ ! -L "$script_file" ] || die 'Run the original reinstall.sh file, not a renamed file or symlink.'
    # Normalize only this digest field to avoid a self-referential checksum.
    # The external release digest remains necessary before the first execution.
    actual=$(sed 's/^SCRIPT_SHA256=[0-9a-f]*$/SCRIPT_SHA256=/' "$script_file" | sha256sum | cut -d ' ' -f 1)
    [ "$actual" = "$SCRIPT_SHA256" ] || die 'Script integrity check failed.'
    actual=$(emit_installer | sha256sum | cut -d ' ' -f 1)
    [ "$actual" = "$INSTALLER_SHA256" ] || die 'Installer differs from the pinned release.'
}
private_dir() {
    [ -d "$1" ] && [ ! -L "$1" ] && [ "$(stat -c '%u:%a' "$1")" = 0:700 ] || die "Directory must be owned by root with mode 0700: $1"
}
cleanup() {
    [ -z "$work" ] || rm -rf "$work"
    [ -z "$pending" ] || rm -rf "$pending"
    if [ "$lock_owned" = yes ]; then
        rm -f "$LOCK/pid"
        rmdir "$LOCK" || :
    fi
}
acquire_lock() {
    [ "$(id -u)" -eq 0 ] || die 'Run as root.'
    mkdir -m 700 "$LOCK" 2>/dev/null || die "Another operation holds $LOCK; do not run operations concurrently."
    lock_owned=yes
    trap cleanup EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    printf '%s\n' "$$" >"$LOCK/pid"
    private_dir "$LOCK"
}
verify_stage() {
    private_dir "$STAGE"
    verify_manifest "$STAGE" 'vmlinuz-virt initramfs disk device-path mbr-sha256 bootcfg previous-boot.cfg next-boot.cfg plan.txt'
}
physical_path() (
    path=$(readlink -f "$1")
    while [ "$path" != / ]; do
        if [ -L "$path/subsystem" ] && [ "$(readlink -f "$path/subsystem")" = /sys/bus/pci ]; then
            printf '%s\n' "$path"; return
        fi
        path=$(dirname "$path")
    done
    # Xen may expose a vbd without a PCI controller.
    readlink -f "$1" | sed 's,/block/[^/]*$,,'
)
usage() {
    cat <<'EOF'
Usage (run as root on the old Alpine system):
  # First verify reinstall.sh against the independently supplied release SHA-256.
  sh reinstall.sh check --disk /dev/vda
  sh reinstall.sh prepare --disk /dev/vda [--ssh-port 22] [--password-file FILE]
  sh reinstall.sh install --disk /dev/vda --erase-system-disk
  sh reinstall.sh cancel

This is a self-contained script; no companion installer or checksum file is required.
prepare prompts for a root password when --password-file is omitted.
prepare downloads a verified official ISO; it does not change the boot config.
install changes the next boot and reboots. ALL partitions on --disk are deleted.
No full-disk zeroing. No SSH or web server during installation.
Only the official Alpine CDN is allowed; there is no mirror override.
Optional: --bootloader extlinux|grub (required if both configurations exist)
EOF
}

preflight() {
    [ "$(uname -s)" = Linux ] && [ "$(uname -m)" = x86_64 ] || die 'Requires x86_64 Linux.'
    [ "$(id -u)" -eq 0 ] || die 'Run as root.'
    [ -f /etc/alpine-release ] || die 'The current system must be Alpine.'
    [ ! -d /sys/firmware/efi ] || die 'Only BIOS boot is supported.'
    grep -Eiq 'Alibaba Cloud|Aliyun' /sys/class/dmi/id/sys_vendor /sys/class/dmi/id/product_name || die 'Not recognized as Alibaba Cloud ECS.'
    [ -n "$disk" ] && [ -b "$disk" ] || die '--disk must name the whole system disk.'
    disk=$(readlink -f "$disk")
    diskname=${disk##*/}
    [ -d "/sys/block/$diskname" ] || die 'Pass a whole physical disk, not a partition/LVM/RAID device.'
    case "$diskname" in vd[a-z]|sd[a-z]|xvd[a-z]|nvme[0-9]n[0-9]) ;; *) die 'Unsupported disk type.' ;; esac
    root_mm=$(awk '$5 == "/" { print $3 }' /proc/self/mountinfo)
    root_node=$(readlink -f "/sys/dev/block/$root_mm")
    [ -f "$root_node/partition" ] || die 'Root must be on a plain disk partition.'
    [ "$(dirname "$root_node")" = "$(readlink -f "/sys/block/$diskname")" ] || die '--disk is not the current root disk.'
    [ "$(cat "/sys/block/$diskname/queue/logical_block_size")" = 512 ] || die 'Requires 512-byte logical sectors.'
    sectors=$(cat "/sys/block/$diskname/size")
    [ "$sectors" -ge 1757812 ] && [ "$sectors" -lt 4294967296 ] || die 'Disk must be at least 900 MB and below 2 TiB.'
    ram=$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo)
    [ "$ram" -ge 409600 ] || die 'At least 400 MiB usable RAM is required (512 MB instance).'
    # Refuse a topology that a minimal eth0/DHCP configuration cannot reproduce.
    nics=0; iface=
    for nic in /sys/class/net/*; do
        [ -e "$nic/device" ] || continue
        nics=$((nics + 1)); iface=${nic##*/}
    done
    [ "$nics" -eq 1 ] || die 'Requires exactly one physical network interface.'
    [ "$(ip -4 route show default | wc -l)" -eq 1 ] || die 'Requires one IPv4 default route.'
    ip -4 route show default | grep -q " dev $iface " || die 'Default route is not on the primary NIC.'
    [ "$(ip -o -4 addr show dev "$iface" scope global | wc -l)" -eq 1 ] || die 'Requires one primary IPv4 address.'
    [ -z "$(ip -o -6 addr show scope global)" ] || die 'This minimal installer supports IPv4-only ECS; active IPv6 is not migrated.'
    mac=$(cat "/sys/class/net/$iface/address")
    # Built-in Xen drivers have no driver/module symlink. Match the bus/driver.
    nic_bus=$(readlink -f "/sys/class/net/$iface/device/subsystem")
    nic_driver=$(basename "$(readlink -f "/sys/class/net/$iface/device/driver")")
    case "$nic_bus:$nic_driver" in
        /sys/bus/virtio:virtio_net|/sys/bus/xen:vif) ;; *) die 'Only virtio_net/xen_netfront ECS NICs are supported.' ;;
    esac
    [ ! -L /boot ] && [ ! -L "$STAGE" ] || die 'Unexpected /boot or stage symlink.'
    if [ -z "$bootloader" ]; then
        if [ -f /boot/extlinux.conf ] && [ -f /boot/grub/grub.cfg ]; then
            die 'Both boot configurations exist; specify --bootloader extlinux or grub.'
        elif [ -f /boot/extlinux.conf ]; then bootloader=extlinux
        elif [ -f /boot/grub/grub.cfg ]; then bootloader=grub
        else die 'Expected /boot/extlinux.conf or /boot/grub/grub.cfg.'; fi
    fi
    case "$bootloader" in
        extlinux) bootcfg=/boot/extlinux.conf ;;
        grub) bootcfg=/boot/grub/grub.cfg ;;
        *) die 'Invalid bootloader.' ;;
    esac
    [ -f "$bootcfg" ] && [ ! -L "$bootcfg" ] || die 'Boot config is missing or is a symlink.'
    boot_mm=$(awk '$5 == "/boot" { print $3 }' /proc/self/mountinfo)
    if [ -n "$boot_mm" ]; then
        boot_node=$(readlink -f "/sys/dev/block/$boot_mm")
        [ "$(dirname "$boot_node")" = "$(readlink -f "/sys/block/$diskname")" ] || die '/boot must be on the system disk.'
        boot_prefix=
        bootdev=/dev/${boot_node##*/}
    else
        boot_prefix=/boot
        bootdev=/dev/${root_node##*/}
    fi
    printf 'ECS BIOS x86_64 | %s MiB RAM | %s sectors | %s | %s (%s) | %s\n' \
        "$((ram / 1024))" "$sectors" "$disk" "$iface" "$mac" "$bootloader"
}

password_hash() (
    if [ -n "$password_file" ]; then
        [ -f "$password_file" ] || die 'Password file not found.'
        password=$(cat "$password_file")
    else
        [ -t 0 ] || die 'Use --password-file without an interactive terminal.'
        printf 'New root password: ' >&2
        stty -echo
        trap 'stty echo' EXIT HUP INT TERM
        IFS= read -r password
        printf '\nRepeat password: ' >&2
        IFS= read -r repeat
        stty echo
        trap - EXIT HUP INT TERM
        printf '\n' >&2
        [ "$password" = "$repeat" ] || die 'Passwords differ.'
        unset repeat
    fi
    [ -n "$password" ] || die 'Empty passwords are forbidden.'
    [ "$(printf '%s' "$password" | wc -l)" -eq 0 ] || die 'Password must be one line.'
    printf '%s\n' "$password" | busybox mkpasswd -m sha512 -P 0 >"$work/ram/payload/password-hash"
    unset password
    # shellcheck disable=SC2016
    grep -q '^\$6\$' "$work/ram/payload/password-hash" || die 'Failed to generate SHA-512 password hash.'
)

prepare() {
    for cmd in curl bsdtar busybox gzip sha256sum; do command -v "$cmd" >/dev/null || die "Missing $cmd; install curl libarchive-tools first."; done
    [ ! -e "$STAGE" ] || die 'A preparation already exists. Use cancel before preparing again.'
    mkdir -p /var/tmp
    case "$(stat -f -c '%T' /var/tmp)" in tmpfs|ramfs) die '/var/tmp must be on disk, not RAM.' ;; esac
    available=$(df -Pk /var/tmp | awk 'END { print $4 }')
    [ "$available" -ge 262144 ] || die '/var/tmp needs at least 256 MiB free for preparation.'
    available=$(df -Pk /boot | awk 'END { print $4 }')
    [ "$available" -ge 65536 ] || die '/boot needs at least 64 MiB free for boot files.'
    work=$(mktemp -d /var/tmp/alpine-reinstall.XXXXXX)
    private_dir "$work"
    iso=alpine-virt-$RELEASE-x86_64.iso
    echo "Downloading checksum-pinned Alpine $RELEASE installation media."
    curl --fail --location --proto '=https' --proto-redir '=https' --retry 3 --connect-timeout 20 \
        --max-time 1200 "$mirror/$BRANCH/releases/x86_64/$iso" -o "$work/alpine.iso"
    printf '%s  %s\n' "$ISO_SHA256" "$work/alpine.iso" | sha256sum -c -
    mkdir -p "$work/iso" "$work/ram"
    bsdtar -xf "$work/alpine.iso" -C "$work/iso" boot/vmlinuz-virt boot/initramfs-virt boot/modloop-virt \
        apks/x86_64/ca-certificates-bundle-20260611-r0.apk
    rm "$work/alpine.iso"
    gzip -dc "$work/iso/boot/initramfs-virt" >"$work/initramfs.cpio"
    (cd "$work/ram" && busybox cpio -idm <"$work/initramfs.cpio")
    rm "$work/initramfs.cpio"
    # Stock netboot has no CA bundle. Use the ISO's certificates, never the old OS's.
    bsdtar -xf "$work/iso/apks/x86_64/ca-certificates-bundle-20260611-r0.apk" -C "$work/ram" etc/ssl
    mkdir -p "$work/ram/payload"
    password_hash
    emit_installer >"$work/ram/payload/installer.sh"
    verify_installer "$work/ram/payload/installer.sh"
    cp "$work/ram/payload/installer.sh" "$work/ram/init"
    chmod 755 "$work/ram/init"
    mv "$work/iso/boot/modloop-virt" "$work/ram/modloop-virt"
    printf '%s\n' "$mac" >"$work/ram/payload/mac"
    printf '%s\n' "$sectors" >"$work/ram/payload/sectors"
    physical_path "/sys/block/$diskname" >"$work/ram/payload/device-path"
    dd if="$disk" bs=512 count=1 2>/dev/null | sha256sum | cut -d ' ' -f 1 >"$work/ram/payload/mbr-sha256"
    printf '%s\n' "$port" >"$work/ram/payload/ssh-port"
    printf '%s\n' "$mirror/$BRANCH/main" >"$work/ram/payload/repository"
    (cd "$work/ram/payload" && sha256sum installer.sh mac sectors device-path mbr-sha256 ssh-port repository password-hash >SHA256SUMS)
    mkdir "$work/output"
    # Store a reviewable plan, without password/hash outside the initramfs.
    cp "$work/ram/payload/mbr-sha256" "$work/output/mbr-sha256"
    cp "$work/ram/payload/device-path" "$work/output/device-path"
    printf '%s\n' "$disk" >"$work/output/disk"
    printf '%s\n' "$bootcfg" >"$work/output/bootcfg"
    cp "$bootcfg" "$work/output/previous-boot.cfg"
    mv "$work/iso/boot/vmlinuz-virt" "$work/output/vmlinuz-virt"
    # Separate commands catch archive errors even on shells without pipefail.
    (cd "$work/ram" && find . -print | busybox cpio -o -H newc >"$work/packed.cpio")
    gzip -1 <"$work/packed.cpio" >"$work/output/initramfs"
    cat >"$work/output/plan.txt" <<EOF
System disk: $disk (all partitions)
MAC: $mac; network: IPv4 DHCP
Alpine: $BRANCH (official signed packages current at install time)
SSH: root password login, TCP $port
Layout: BIOS / MBR / one ext4 root / no swap partition
No old files, agents, host keys, repositories or services are migrated.
EOF
    if [ "$bootloader" = extlinux ]; then
        cat >"$work/output/next-boot.cfg" <<EOF
# alpine-ecs-reinstall boot entry
SERIAL 0 115200
DEFAULT reinstall
PROMPT 0
TIMEOUT 30
LABEL reinstall
  LINUX $boot_prefix/alpine-reinstall/vmlinuz-virt
  INITRD $boot_prefix/alpine-reinstall/initramfs
  APPEND console=tty0 console=ttyS0,115200n8 net.ifnames=0
LABEL previous-system
  CONFIG $boot_prefix/alpine-reinstall/previous-boot.cfg $boot_prefix/
EOF
    else
        boot_uuid=$(blkid "$bootdev" | sed -n 's/.* UUID="\([^"]*\)".*/\1/p')
        [ -n "$boot_uuid" ] || die 'Cannot determine boot filesystem UUID.'
        case "$boot_uuid" in *[!a-fA-F0-9-]*) die 'Unexpected boot filesystem UUID.' ;; esac
        cat >"$work/output/next-boot.cfg" <<EOF
# alpine-ecs-reinstall boot entry
set default=0
set timeout=3
menuentry 'Reinstall Alpine (ERASE SYSTEM DISK)' {
  search --no-floppy --fs-uuid --set=root $boot_uuid
  linux $boot_prefix/alpine-reinstall/vmlinuz-virt console=tty0 console=ttyS0,115200n8 net.ifnames=0
  initrd $boot_prefix/alpine-reinstall/initramfs
}
menuentry 'Previous system' {
  search --no-floppy --fs-uuid --set=root $boot_uuid
  configfile $boot_prefix/alpine-reinstall/previous-boot.cfg
}
EOF
    fi
    (cd "$work/output" && sha256sum vmlinuz-virt initramfs disk device-path mbr-sha256 bootcfg previous-boot.cfg next-boot.cfg plan.txt >SHA256SUMS)
    pending=$(mktemp -d /boot/.alpine-reinstall-ready.XXXXXX)
    private_dir "$pending"
    cp -a "$work/output/." "$pending/"
    private_dir "$pending"
    [ ! -e "$STAGE" ] && [ ! -L "$STAGE" ] || die 'Stage path appeared during preparation.'
    mv "$pending" "$STAGE"
    pending=
    cat "$STAGE/plan.txt"
    echo "Prepared. To erase and reinstall: sh reinstall.sh install --disk $disk --erase-system-disk"
}

install() {
    [ "$erase" = yes ] || die 'install requires --erase-system-disk.'
    [ -d "$STAGE" ] || die 'Run prepare first.'
    verify_stage
    [ "$(cat "$STAGE/disk")" = "$disk" ] || die 'Prepared disk differs.'
    [ "$(cat "$STAGE/device-path")" = "$(physical_path "/sys/block/$diskname")" ] || die 'Device identity changed.'
    fingerprint=$(dd if="$disk" bs=512 count=1 2>/dev/null | sha256sum | cut -d ' ' -f 1)
    [ "$fingerprint" = "$(cat "$STAGE/mbr-sha256")" ] || die 'Partition table changed since preparation.'
    [ "$(cat "$STAGE/bootcfg")" = "$bootcfg" ] || die 'Bootloader differs from preparation.'
    cmp -s "$bootcfg" "$STAGE/previous-boot.cfg" || die 'Boot config changed since preparation.'
    cat "$STAGE/plan.txt"
    cp "$STAGE/next-boot.cfg" "$bootcfg.reinstall-new"
    mv "$bootcfg.reinstall-new" "$bootcfg"
    sync
    echo 'Rebooting into the installer. SSH will disconnect until installation completes.'
    reboot
}

cancel() {
    [ "$(id -u)" -eq 0 ] || die 'Run as root.'
    [ -d "$STAGE" ] && [ ! -L "$STAGE" ] || die 'No preparation exists.'
    verify_stage
    bootcfg=$(cat "$STAGE/bootcfg")
    case "$bootcfg" in /boot/extlinux.conf|/boot/grub/grub.cfg) ;; *) die 'Invalid saved boot path.' ;; esac
    if cmp -s "$bootcfg" "$STAGE/next-boot.cfg"; then
        cp "$STAGE/previous-boot.cfg" "$bootcfg.reinstall-new"
        mv "$bootcfg.reinstall-new" "$bootcfg"
    else
        cmp -s "$bootcfg" "$STAGE/previous-boot.cfg" || die 'Boot config changed; refusing to overwrite it.'
    fi
    rm -rf "$STAGE"
    sync
    echo 'Preparation cancelled; original boot configuration retained.'
}

# Kept as literal text so it runs only after extraction into the new initramfs.
# Do not source the installer in the old system.
emit_installer() {
    cat <<'ALPINE_ECS_INSTALLER_EOF'
#!/bin/sh
# shellcheck shell=ash
# SPDX-License-Identifier: GPL-3.0-or-later
# Runs only under the new, official Alpine kernel. Never source old configuration.
set -eu
set -o pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C
umask 077

fail() { echo "INSTALL FAILED: $*" >&2; exit 1; }
[ "$$" -eq 1 ] || fail 'This file is an initramfs entry point, not a command to run on an installed system.'
verify_payload() (
    cd "$1"
    names='installer.sh mac sectors device-path mbr-sha256 ssh-port repository password-hash'
    [ -f SHA256SUMS ] && [ ! -L SHA256SUMS ] || fail 'Missing payload manifest.'
    awk -v names="$names" '
        BEGIN { count = split(names, files, " ") }
        NF != 2 || length($1) != 64 || $1 ~ /[^0-9a-f]/ || $2 != files[NR] { exit 1 }
        END { if (NR != count) exit 1 }
    ' SHA256SUMS || fail 'Invalid or incomplete payload manifest.'
    for name in $names; do
        [ -f "$name" ] && [ ! -L "$name" ] || fail "Invalid payload file: $name"
    done
    sha256sum -c SHA256SUMS >/dev/null || fail 'Payload integrity check failed.'
    [ "$(cat repository)" = https://dl-cdn.alpinelinux.org/alpine/v3.24/main ] || fail 'Only the official Alpine v3.24 main repository is allowed.'
)
stopped() {
    trap - EXIT
    echo 'Installation stopped. See the ECS serial/VNC output. No automatic retry.' >&2
    while :; do sleep 3600; done
}

bootstrap() {
    /bin/busybox --install -s
    mount -t proc proc /proc
    mount -t sysfs sysfs /sys
    mount -t devtmpfs devtmpfs /dev
    mkdir -p /run /tmp /.modloop /live
    mount -t tmpfs -o mode=0755 tmpfs /run
    exec </dev/console >/dev/console 2>&1
    trap stopped EXIT
    echo 'Starting a fresh Alpine installation environment.'
    verify_payload /payload
    cmp -s /init /payload/installer.sh || fail 'Installer copies differ.'
    hwclock -s -u || true
    modprobe loop
    modprobe squashfs
    mount -t squashfs -o loop,ro /modloop-virt /.modloop
    rm -rf /lib/modules
    ln -s /.modloop/modules /lib/modules
    # These are upstream Linux drivers, not cloud agent software.
    for module in virtio_pci virtio_blk virtio_scsi nvme xen_blkfront xen_netfront virtio_net button; do
        modprobe "$module" 2>/dev/null || true
    done
    mdev -s
    expected_mac=$(cat /payload/mac)
    iface=
    for nic in /sys/class/net/*; do
        [ "$(cat "$nic/address")" = "$expected_mac" ] || continue
        [ -z "$iface" ] || fail 'More than one matching NIC.'
        iface=${nic##*/}
    done
    [ -n "$iface" ] || fail 'The expected network adapter is missing.'
    ip link set "$iface" up
    # Use only the official initramfs DHCP hook. No old lease, DNS, or IP config.
    udhcpc -i "$iface" -n -t 8 -T 3 -p /run/udhcpc.pid
    [ -s /etc/resolv.conf ] || fail 'DHCP did not provide DNS.'
    repo=$(cat /payload/repository)
    mount -t tmpfs -o size=224m,mode=0755 tmpfs /live
    mkdir -p /live/etc/apk/keys /live/dev /live/proc /live/sys /live/run
    cp /etc/apk/keys/* /live/etc/apk/keys/
    cp /etc/resolv.conf /live/etc/resolv.conf
    printf '%s\n' "$repo" >/live/etc/apk/repositories
    mount --bind /dev /live/dev
    # apk and its signing keys come from the checksum-pinned official ISO.
    apk --root /live --initdb --no-cache add alpine-base e2fsprogs sfdisk wipefs syslinux
    mount --bind /proc /live/proc
    mount --bind /sys /live/sys
    mkdir -p /live/lib/modules /live/run/reinstall
    mount --bind /.modloop/modules /live/lib/modules
    cp /payload/* /live/run/reinstall/
    printf '%s\n' "$iface" >/live/run/reinstall/interface
    trap - EXIT
    exec chroot /live /bin/sh /run/reinstall/installer.sh install
}

physical_path() (
    path=$(readlink -f "$1")
    while [ "$path" != / ]; do
        if [ -L "$path/subsystem" ] && [ "$(readlink -f "$path/subsystem")" = /sys/bus/pci ]; then
            printf '%s\n' "$path"; return
        fi
        path=$(dirname "$path")
    done
    readlink -f "$1" | sed 's,/block/[^/]*$,,'
)

identify_disk() {
    disk=
    for node in /sys/block/*; do
        [ "$(cat "$node/size")" = "$(cat "$cfg/sectors")" ] || continue
        [ "$(physical_path "$node")" = "$(cat "$cfg/device-path")" ] || continue
        candidate=/dev/${node##*/}
        fingerprint=$(dd if="$candidate" bs=512 count=1 2>/dev/null | sha256sum | cut -d ' ' -f 1)
        [ "$fingerprint" = "$(cat "$cfg/mbr-sha256")" ] || continue
        [ -z "$disk" ] || fail 'Ambiguous disk identity.'
        disk=$candidate
    done
    [ -n "$disk" ] || fail 'System disk identity changed; refusing to partition.'
    [ "$(cat /sys/block/"${disk##*/}"/queue/logical_block_size)" = 512 ] || fail 'Requires 512-byte logical sectors.'
    # The installer never mounts or reads files from an old filesystem.
    for entry in /sys/block/"${disk##*/}" /sys/block/"${disk##*/}"/*; do
        [ -f "$entry/dev" ] || continue
        devnum=$(cat "$entry/dev")
        ! awk -v n="$devnum" '$3 == n { found=1 } END { exit !found }' /proc/self/mountinfo || fail 'Target is mounted.'
        [ -z "$(ls -A "$entry/holders" 2>/dev/null)" ] || fail 'Target has active holders.'
    done
    [ "$(wc -l </proc/swaps)" -eq 1 ] || fail 'Unexpected active swap.'
}

install_system() {
    exec </dev/console >/dev/console 2>&1
    trap stopped EXIT
    cfg=/run/reinstall
    [ "$(stat -f -c '%T' /)" = tmpfs ] || fail 'The installer must run from its private RAM filesystem.'
    [ "$(stat -c '%u:%a' "$cfg")" = 0:700 ] || fail 'Payload directory is not root-private.'
    verify_payload "$cfg"
    identify_disk
    iface=$(cat "$cfg/interface")
    [ "$iface" = eth0 ] || fail 'Only a single standard eth0 NIC is supported.'
    port=$(cat "$cfg/ssh-port")
    repo=$(cat "$cfg/repository")
    packages='alpine-base linux-virt openssh-server openssh-server-common-openrc syslinux e2fsprogs ca-certificates-bundle'
    mkdir -p "$cfg/packages"
    echo 'Downloading and verifying official packages in the fresh RAM environment.'
    # Download before partitioning, but only after leaving the old kernel.
    # shellcheck disable=SC2086
    apk --no-cache fetch --recursive --output "$cfg/packages" $packages
    apk verify "$cfg"/packages/*.apk
    modprobe ext4
    verify_payload "$cfg"
    identify_disk
    echo "Recreating the partition table and filesystems on $disk (no full-disk zeroing)."
    # Remove signatures, including a stale backup GPT; do not overwrite file data.
    wipefs --all --force "$disk"
    # Clear the reserved BIOS boot area, including an old GRUB core.img.
    # The new root partition starts at 1 MiB; this is not full-disk zeroing.
    dd if=/dev/zero of="$disk" bs=1M count=1 conv=notrunc,fsync
    printf 'label: dos\nunit: sectors\n\nstart=2048, type=83, bootable\n' | sfdisk --wipe always "$disk"
    mdev -s
    case "$disk" in *[0-9]) part=${disk}p1 ;; *) part=${disk}1 ;; esac
    n=0
    until [ -b "$part" ]; do
        n=$((n + 1)); [ "$n" -lt 20 ] || fail 'New partition did not appear.'
        sleep 1; mdev -s
    done
    # Syslinux BIOS needs a compatible ext4 layout. Keep the journal and 1% reserve.
    mkfs.ext4 -F -m 1 -L alpine -O ^64bit,^metadata_csum "$part"
    # Normal system directories must remain traversable by unprivileged services.
    # /run/reinstall was already created privately, and holds the password hash.
    umask 022
    mkdir -p /target
    mount -t ext4 "$part" /target
    mkdir -p /target/etc/apk/keys /target/dev /target/proc /target/sys
    cp /etc/apk/keys/* /target/etc/apk/keys/
    mount --bind /dev /target/dev
    # Populate an empty filesystem; never clone the live environment's /etc.
    apk --root /target --initdb --no-network --no-cache --repositories-file /dev/null add "$cfg"/packages/*.apk
    printf '%s\n' "$packages" | tr ' ' '\n' >/target/etc/apk/world
    printf '%s\n' "$repo" >/target/etc/apk/repositories
    mount --bind /proc /target/proc
    mount --bind /sys /target/sys
    uuid=$(blkid -s UUID -o value "$part")
    [ -n "$uuid" ] || fail 'Missing filesystem UUID.'
    printf 'UUID=%s / ext4 defaults,noatime 0 1\n' "$uuid" >/target/etc/fstab
    printf 'alpine\n' >/target/etc/hostname
    printf '127.0.0.1 localhost localhost.localdomain\n127.0.1.1 alpine\n::1 localhost localhost.localdomain\n' >/target/etc/hosts
    cat >/target/etc/network/interfaces <<'EOF'
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
EOF
    cat >/target/etc/ssh/sshd_config <<EOF
Port $port
AddressFamily inet
PermitRootLogin yes
PasswordAuthentication yes
KbdInteractiveAuthentication no
PubkeyAuthentication no
AuthenticationMethods password
PermitEmptyPasswords no
AllowUsers root
DisableForwarding yes
X11Forwarding no
PermitTunnel no
PermitUserEnvironment no
PermitUserRC no
LoginGraceTime 30
MaxAuthTries 3
MaxSessions 2
MaxStartups 3:30:10
UseDNS no
EOF
    printf 'root:%s\n' "$(cat "$cfg/password-hash")" | chroot /target chpasswd -e
    printf 'features="ata base scsi virtio nvme ext4"\n' >/target/etc/mkinitfs/mkinitfs.conf
    kernel=$(basename /target/lib/modules/*-virt)
    chroot /target mkinitfs "$kernel"
    cat >/target/etc/update-extlinux.conf <<EOF
overwrite=1
vesa_menu=0
default_kernel_opts="console=tty0 console=ttyS0,115200n8 net.ifnames=0"
modules=sd-mod,ext4
root=UUID=$uuid
verbose=0
hidden=1
timeout=2
default=virt
serial_port=0
serial_baud=115200
EOF
    # Explicitly install both the volume bootloader and its MBR bootstrap.
    extlinux --install /target/boot
    chroot /target update-extlinux
    rm -f /target/boot/extlinux.conf.old /target/boot/extlinux.conf.new
    dd if=/usr/share/syslinux/mbr.bin of="$disk" bs=440 count=1 conv=notrunc
    for svc in devfs dmesg mdev hwdrivers; do chroot /target rc-update add "$svc" sysinit; done
    for svc in modules sysctl hostname bootmisc syslog networking seedrng hwclock; do
        chroot /target rc-update add "$svc" boot
    done
    for svc in sshd crond ntpd; do chroot /target rc-update add "$svc" default; done
    # Minimal initramfs mdev lacks the installed system's /dev/input layout.
    # Detect the kernel power-button device; the official BusyBox handler is installed.
    if grep -qx 'Power Button' /sys/class/input/input*/name 2>/dev/null; then
        chroot /target rc-update add acpid default
    fi
    for svc in killprocs mount-ro; do chroot /target rc-update add "$svc" shutdown; done
    # Official BusyBox client, using Alibaba's IPv4 VPC time sources; no NTP server.
    printf 'NTPD_OPTS="-N -p ntp.cloud.aliyuncs.com -p ntp7.cloud.aliyuncs.com -p ntp8.cloud.aliyuncs.com"\n' >/target/etc/conf.d/ntpd
    # The official hwclock configuration uses UTC.
    sed -i 's/^#ttyS0:/ttyS0:/' /target/etc/inittab
    # Host keys are generated only on the new system's first boot.
    chroot /target ssh-keygen -q -t ed25519 -N '' -f /run/verify-host-key
    chroot /target sshd -t -h /run/verify-host-key
    rm -f /target/run/verify-host-key /target/run/verify-host-key.pub
    [ ! -e /target/root/.ssh ] || fail 'Unexpected inherited SSH directory.'
    [ ! -e /target/etc/local.d/reinstall.start ] || fail 'Unexpected installation hook.'
    echo "Installed Alpine. Root password SSH will listen on port $port after reboot."
    df -h /target
    sync
    umount /target/sys /target/proc /target/dev
    umount /target
    e2fsck -f -n "$part"
    sync
    trap - EXIT
    reboot -f
    fail 'Reboot failed.'
}

case "${1:-bootstrap}" in
    bootstrap) bootstrap ;;
    install) install_system ;;
    *) fail 'Invalid installer mode.' ;;
esac
ALPINE_ECS_INSTALLER_EOF
}

action=${1:-help}; [ "$#" -eq 0 ] || shift
disk=; port=22; password_file=; erase=no; bootloader=
mirror=https://dl-cdn.alpinelinux.org/alpine
while [ "$#" -gt 0 ]; do
    case "$1" in
        --disk|--ssh-port|--password-file|--bootloader)
            [ "$#" -ge 2 ] || die "Missing value for $1."
            case "$1" in
                --disk) disk=$2 ;; --ssh-port) port=$2 ;; --password-file) password_file=$2 ;;
                --bootloader) bootloader=$2 ;;
            esac
            shift 2 ;;
        --erase-system-disk) erase=yes; shift ;;
        *) die "Unknown argument: $1" ;;
    esac
done
case "$port" in ''|0*|*[!0-9]*) die 'SSH port must be an integer from 1 to 65535.' ;; esac
[ "${#port}" -le 5 ] && [ "$port" -le 65535 ] || die 'SSH port must be 1..65535.'
case "$action" in
    check) verify_release; preflight ;;
    prepare) verify_release; acquire_lock; preflight; prepare ;;
    install) verify_release; acquire_lock; preflight; install ;;
    cancel) verify_release; acquire_lock; cancel ;;
    help|--help|-h) usage ;;
    *) usage; exit 1 ;;
esac
