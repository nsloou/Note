#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Debian-to-Debian unattended reinstall, clean single-file edition.
#
# Derived from the Debian path of bin456789/reinstall at audited commit:
#   6b3a341b4bb5c0b93f25cc0a0518e9bd5088504b
# This edition does not fetch project code at runtime. Debian artifacts and
# packages are accepted only after verification through a signed InRelease.

set -Eeuo pipefail
shopt -s inherit_errexit 2>/dev/null || true
umask 077

readonly PROGRAM=${0##*/}
readonly STATE_DIR=/boot/debian-reinstall
readonly GRUB_SCRIPT=/etc/grub.d/42_debian_reinstall
readonly GRUB_DEFAULT_DROPIN=/etc/default/grub.d/99-debian-reinstall-once.cfg
readonly KEXEC_DEFAULT=/etc/default/kexec
readonly KEXEC_BACKUP_NAME=source-kexec.default
readonly MIN_DISK_BYTES=4294967296

release=13
release_set=false
distro_seen=false
codename=trixie
mirror=https://deb.debian.org/debian
target_disk=
password_value=
ssh_port=22
new_hostname=debian
filesystem=ext4
low_memory=auto
keep_workdir=false
action=prepare
workdir=
apt_cache_dir=
initrd_dir=
release_file=
package_index_deb=
package_index_udeb=
arch=
kernel_image=
mirror_host=
mirror_directory=
source_codename=
linked_grub_dir=false
boot_transaction=false
boot_committed=false

display_heading() {
    local color=$1 text=$2
    if [[ -t 2 && ${TERM:-dumb} != dumb && -z ${NO_COLOR:-} ]]; then
        printf '\n\033[1;%sm%s\033[0m\n' "$color" "$text" >&2
    else
        printf '\n%s\n' "$text" >&2
    fi
}

log() { display_heading 36 "==> $*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

cleanup_apt_cache() {
    [ -n "${apt_cache_dir:-}" ] || return 0
    if ! rm -rf -- "$apt_cache_dir"; then
        warn "Could not remove preparation APT cache: $apt_cache_dir"
        return 1
    fi
    apt_cache_dir=
}

cleanup() {
    status=$?
    if $boot_transaction && ! $boot_committed; then
        if ! rollback_prepared_boot; then
            keep_workdir=true
            warn "Automatic boot rollback failed. Do not reboot; backup retained at $workdir. Run --reset and inspect GRUB."
        fi
    fi
    if ! cleanup_apt_cache; then
        [ "$status" -ne 0 ] || status=1
    fi
    if [ -n "${workdir:-}" ] && [ -d "$workdir" ] && ! $keep_workdir; then
        rm -rf -- "$workdir"
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

usage() {
    cat <<EOF
Usage:
  $PROGRAM debian 13 --password PASSWORD [--ssh-port PORT]
  $PROGRAM --reset

Prepare a one-shot boot into Debian Installer. The script never reboots by
itself. Rebooting starts an unattended install that deletes the old partition
layout, creates new filesystems, and erases the selected disk logically.

Options:
  debian 13                   Required target and release (source: Debian 12/13)
  --password PASSWORD         Password for the root account
  --ssh-port PORT             Installed system SSH port (default: 22)
  --reset                     Remove the prepared one-shot boot entry/files
  -h, --help                  Show this help

The account and hostname are fixed to root and debian. Disk, KVM networking,
IPv4/IPv6 and low-memory handling are detected automatically. The root
filesystem is ext4 and the Debian mirror is https://deb.debian.org/debian.

WARNING: a command-line password can be visible in shell history and /proc
during preparation. Only its salted yescrypt hash is embedded into the installer.
EOF
}

need_arg() {
    if [ $# -lt 2 ] || [ -z "$2" ]; then
        die "$1 requires a value"
    fi
}

while [ $# -gt 0 ]; do
    case "$1" in
        debian)
            $distro_seen && die "specify debian only once"
            distro_seen=true
            shift
            ;;
        13)
            $release_set && die "specify the Debian release only once"
            release=$1
            release_set=true
            shift
            ;;
        --password) need_arg "$@"; password_value=$2; shift 2 ;;
        --ssh-port) need_arg "$@"; ssh_port=$2; shift 2 ;;
        --reset) action=reset; shift ;;
        -h|--help) usage; exit 0 ;;
        --) shift; break ;;
        *) die "unknown option: $1" ;;
    esac
done
[ $# -eq 0 ] || die "unexpected positional arguments"

require_root_debian() {
    [ "$(id -u)" -eq 0 ] || die "run as root"
    [ -r /etc/os-release ] || die "cannot identify the source operating system"
    local source_id source_version
    source_id="$(sed -n 's/^ID=//p' /etc/os-release | tr -d '\"')"
    source_version="$(sed -n 's/^VERSION_ID=//p' /etc/os-release | tr -d '\"')"
    [ "$source_id" = debian ] || die "this reduced script supports Debian as the source OS only"
    case "$source_version" in
        12) source_codename=bookworm ;;
        13) source_codename=trixie ;;
        *) die "the source OS must be Debian 12 or Debian 13" ;;
    esac
    if command -v systemd-detect-virt >/dev/null 2>&1 &&
        systemd-detect-virt --container --quiet; then
        die "containers (LXC/OpenVZ/Docker) cannot replace their kernel or boot disk; use a KVM/VM instance"
    fi
}

secure_boot_enabled() {
    local variable value
    [ -d /sys/firmware/efi ] || return 1
    variable="$(find /sys/firmware/efi/efivars -maxdepth 1 \
        -name 'SecureBoot-*' -print -quit 2>/dev/null || true)"
    if [ -n "$variable" ]; then
        value="$(od -An -t u1 -j 4 -N 1 "$variable" 2>/dev/null | tr -d '[:space:]' || true)"
        [ "$value" = 1 ] && return 0
    fi
    if command -v mokutil >/dev/null 2>&1 &&
        mokutil --sb-state 2>&1 | grep -Fqi 'SecureBoot enabled'; then
        return 0
    fi
    dmesg 2>/dev/null | grep -Fqi 'Secure boot enabled'
}

preflight_source_system() {
    local root_fstype root_source stack
    root_fstype="$(findmnt -n -o FSTYPE / 2>/dev/null || true)"
    case "$root_fstype" in
        overlay|squashfs|tmpfs|ramfs|rootfs)
            die "live/overlay root filesystem $root_fstype is not a supported reinstall source"
            ;;
        '') die "could not determine the source root filesystem type" ;;
    esac

    root_source="$(findmnt -n -o SOURCE -e / 2>/dev/null || findmnt -n -o SOURCE /)"
    root_source=${root_source%%\[*}
    if [ -b "$root_source" ]; then
        stack="$(lsblk -s -n -o TYPE "$root_source" 2>/dev/null || true)"
        if grep -Eq '^(crypt|raid[0-9]+|md)$' <<<"$stack"; then
            die "encrypted or software-RAID source roots are not supported unattended; use the provider console/rescue environment"
        fi
    fi

}

require_secure_boot_disabled() {
    if secure_boot_enabled; then
        die "UEFI Secure Boot is enabled; disable it before using this unverified custom-initrd boot path"
    fi
}

find_grub_command() {
    local name
    for name in "$@"; do
        command -v "$name" 2>/dev/null && return 0
    done
    return 1
}

disarm_our_boot() {
    local grub_editenv current
    grub_editenv="$(find_grub_command grub-editenv grub2-editenv)" || return 1
    current="$("$grub_editenv" - list)" || return 1
    if grep -Fxq next_entry=debian-reinstall <<<"$current"; then
        "$grub_editenv" - unset next_entry || return 1
        current="$("$grub_editenv" - list)" || return 1
        ! grep -Fxq next_entry=debian-reinstall <<<"$current" || return 1
    fi
}

rollback_prepared_boot() {
    # Never delete boot assets while the destructive entry may remain armed.
    disarm_our_boot || return 1
    if [ -f "$workdir/grub.cfg.before" ]; then
        cp -p -- "$workdir/grub.cfg.before" /boot/grub/grub.cfg || return 1
    fi
    if [ -f "$STATE_DIR/$KEXEC_BACKUP_NAME" ]; then
        cp -p -- "$STATE_DIR/$KEXEC_BACKUP_NAME" "$KEXEC_DEFAULT" || return 1
    fi
    rm -f -- "$GRUB_SCRIPT" "$GRUB_DEFAULT_DROPIN" || return 1
    rm -rf -- "$STATE_DIR"
}

reset_prepared_boot() {
    require_root_debian
    local update_grub
    update_grub="$(find_grub_command update-grub || true)"
    disarm_our_boot || die "could not verify the reinstall entry is disarmed; files retained, do not reboot"

    if [ -f "$STATE_DIR/$KEXEC_BACKUP_NAME" ]; then
        cp -p -- "$STATE_DIR/$KEXEC_BACKUP_NAME" "$KEXEC_DEFAULT"
        log "Restored the source system kexec configuration"
    fi
    rm -f -- "$GRUB_SCRIPT" "$GRUB_DEFAULT_DROPIN"
    rm -rf -- "$STATE_DIR"
    if [ -n "$update_grub" ]; then
        "$update_grub"
    fi
    log "Prepared reinstall entry and files removed"
}

if [ "$action" = reset ]; then
    reset_prepared_boot
    exit 0
fi

validate_options() {
    $distro_seen || die "target must be specified as: debian 13"
    $release_set || die "target must be specified as: debian 13"
    case "$release" in
        13) codename=trixie ;;
        *) die "the target release must be 13" ;;
    esac
    if ! [[ "$ssh_port" =~ ^[0-9]+$ ]] || [ "$ssh_port" -lt 1 ] || [ "$ssh_port" -gt 65535 ]; then
        die "invalid SSH port"
    fi
    [ -n "$password_value" ] || die "--password is required"
    [[ "$password_value" != *$'\n'* ]] || die "password must not contain a newline"
    [ "${#password_value}" -ge 16 ] || die "password must contain at least 16 characters"
    mirror=${mirror%/}
    [[ "$mirror" =~ ^https://[A-Za-z0-9._:-]+(/[A-Za-z0-9._~/-]*)?$ ]] ||
        die "mirror must be a simple HTTPS URL without credentials, query or fragment"
    local authority_and_path=${mirror#https://}
    mirror_host=${authority_and_path%%/*}
    if [[ "$authority_and_path" = */* ]]; then
        mirror_directory=/${authority_and_path#*/}
    else
        mirror_directory=/
    fi
}

prepare_apt_cache() {
    local apt_uid
    [ -z "$apt_cache_dir" ] || die "preparation APT cache is already allocated"
    apt_uid="$(id -u _apt 2>/dev/null)" || die "Debian APT sandbox account _apt is missing"
    [[ "$apt_uid" =~ ^[0-9]+$ ]] && [ "$apt_uid" -ne 0 ] ||
        die "Debian APT sandbox account _apt must have a non-root UID"

    # Only public repository indexes/packages go here. Do not relax workdir:
    # it also holds credentials and the prepared installer. APT's downloader
    # needs searchable ancestors and its own private, writable partial dirs.
    apt_cache_dir="$(mktemp -d /var/tmp/debian-reinstall-apt.XXXXXXXX)"
    chmod 0711 "$apt_cache_dir"
    install -d -o 0 -g 0 -m 0755 "$apt_cache_dir/lists" "$apt_cache_dir/archives"
    install -d -o "$apt_uid" -g 0 -m 0700 \
        "$apt_cache_dir/lists/partial" "$apt_cache_dir/archives/partial"
}

install_dependencies() {
    local packages=(ca-certificates curl gpgv debian-archive-keyring xz-utils cpio binutils fdisk util-linux iproute2 grub-common grub2-common kmod whois mokutil)
    local apt_sources
    local -a apt_options
    local apt_root="$workdir/apt"
    mkdir -p "$apt_root"/{empty,home}
    prepare_apt_cache
    : >"$apt_root/empty.conf"
    apt_sources="$apt_root/sources.list"
    # APT_CONFIG is loaded BEFORE system apt.conf.d; command-line overrides
    # alone cannot prevent vendor hooks from loading.
    cat >"$apt_root/apt.conf" <<EOF
Dir::Etc::main "$apt_root/empty.conf";
Dir::Etc::parts "$apt_root/empty";
Dir::Etc::sourcelist "$apt_sources";
Dir::Etc::sourceparts "$apt_root/empty";
Dir::Etc::preferences "$apt_root/empty.conf";
Dir::Etc::preferencesparts "$apt_root/empty";
Dir::State::lists "$apt_cache_dir/lists";
Dir::Cache::archives "$apt_cache_dir/archives";
Dir::Cache::pkgcache "";
Dir::Cache::srcpkgcache "";
APT::Sandbox::User "_apt";
Acquire::https::Verify-Peer "true";
Acquire::https::Verify-Host "true";
EOF
    # dpkg also has independent configuration hooks. Hide its option files
    # only inside a private mount namespace; leave the source OS files intact.
    command -v unshare >/dev/null || die "util-linux unshare is required for isolated preparation"
    unshare --mount --propagation private true ||
        die "private mount namespaces are unavailable; use a trusted rescue environment"
    clean_apt() {
        env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME="$apt_root/home" \
            APT_CONFIG="$apt_root/apt.conf" DEBIAN_FRONTEND=noninteractive \
            unshare --mount --propagation private sh -eu -c '
                isolation=$1; shift
                if [ -f /etc/dpkg/dpkg.cfg ]; then
                    mount --bind "$isolation/empty.conf" /etc/dpkg/dpkg.cfg
                fi
                if [ -d /etc/dpkg/dpkg.cfg.d ]; then
                    mount --bind "$isolation/empty" /etc/dpkg/dpkg.cfg.d
                fi
                exec apt-get "$@"
            ' sh "$apt_root" "$@"
    }
    apt_options=(
        -o "Dir::Etc::sourcelist=$apt_sources"
        -o Dir::Etc::sourceparts=-
        -o Dir::Etc::main=/dev/null
        -o Dir::Etc::parts=-
        -o Acquire::Languages=none
        -o Acquire::Retries=3
        -o APT::Update::Error-Mode=any
        -o APT::Get::AllowUnauthenticated=false
        -o Acquire::AllowInsecureRepositories=false
        -o Acquire::AllowDowngradeToInsecureRepositories=false
    )

    write_dependency_sources() {
        local protocol=$1
        printf '%s\n' \
            "deb [signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] $protocol://deb.debian.org/debian $source_codename main" \
            "deb [signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] $protocol://deb.debian.org/debian $source_codename-updates main" \
            "deb [signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] $protocol://security.debian.org/debian-security $source_codename-security main" \
            >"$apt_sources"
    }

    log "Installing preparation tools from official Debian $source_codename repositories only"
    write_dependency_sources https
    if ! clean_apt "${apt_options[@]}" update; then
        warn "official HTTPS APT failed; bootstrapping CA/keyring through authenticated Debian HTTP"
        write_dependency_sources http
        if ! clean_apt "${apt_options[@]}" update ||
            ! clean_apt "${apt_options[@]}" install -y --reinstall --no-install-recommends \
                ca-certificates debian-archive-keyring gpgv; then
            rm -f -- "$apt_sources"
            die "could not bootstrap trusted HTTPS from authenticated Debian repositories"
        fi
        write_dependency_sources https
        if ! clean_apt "${apt_options[@]}" update; then
            rm -f -- "$apt_sources"
            die "official Debian HTTPS still failed after CA/keyring bootstrap"
        fi
    fi
    if ! clean_apt "${apt_options[@]}" install -y --reinstall --no-install-recommends "${packages[@]}"; then
        rm -f -- "$apt_sources"
        die "could not install preparation tools from official Debian repositories"
    fi
    rm -f -- "$apt_sources"
    cleanup_apt_cache || die "preparation APT cache cleanup failed"
}

detect_architecture() {
    arch="$(dpkg --print-architecture)"
    case "$arch" in
        amd64) kernel_image=linux-image-cloud-amd64 ;;
        arm64) kernel_image=linux-image-cloud-arm64 ;;
        *) die "only Debian amd64 and arm64 are supported (found $arch)" ;;
    esac
}

resolve_root_disks() {
    local source major_minor
    source="$(findmnt -n -o SOURCE -e / 2>/dev/null || findmnt -n -o SOURCE /)"
    # findmnt represents a Btrfs subvolume as /dev/xxx[/subvolume], whereas
    # lsblk expects only the backing block-device path.
    source=${source%%\[*}
    if [ ! -b "$source" ]; then
        major_minor="$(findmnt -n -o MAJ:MIN / 2>/dev/null || true)"
        if [ -n "$major_minor" ] && [ -e "/dev/block/$major_minor" ]; then
            source="$(readlink -f -- "/dev/block/$major_minor")"
        fi
    fi
    lsblk -s -n -o KNAME,TYPE "$source" 2>/dev/null |
        awk '$2=="disk" {print $1}' | sort -u
}

resolve_path_disks() {
    local path=$1 source major_minor
    source="$(findmnt -n -o SOURCE -T "$path" 2>/dev/null || true)"
    source=${source%%\[*}
    if [ ! -b "$source" ]; then
        major_minor="$(findmnt -n -o MAJ:MIN -T "$path" 2>/dev/null || true)"
        if [ -n "$major_minor" ] && [ -e "/dev/block/$major_minor" ]; then
            source="$(readlink -f -- "/dev/block/$major_minor")"
        fi
    fi
    [ -b "$source" ] || return 1
    lsblk -s -n -o KNAME,TYPE "$source" 2>/dev/null |
        awk '$2=="disk" {print $1}' | sort -u
}

require_path_on_target_disk() {
    local path=$1 label=$2 disks
    disks="$(resolve_path_disks "$path" || true)"
    [ -n "$disks" ] || die "could not resolve the disk backing $label ($path)"
    [ "$(printf '%s\n' "$disks" | sed '/^$/d' | wc -l)" -eq 1 ] ||
        die "$label spans multiple disks, which is not safe for unattended reinstall"
    [ "$disks" = "${target_disk##*/}" ] ||
        die "$label is on /dev/$disks but the root target is $target_disk; cross-disk boot layouts are not supported"
}

detect_boot_layout() {
    local boot_options esp_mount path fstype abstraction env_path
    esp_mount=
    require_path_on_target_disk /boot '/boot filesystem'
    boot_options="$(findmnt -n -o OPTIONS -T /boot 2>/dev/null || true)"
    [[ ",$boot_options," == *,rw,* ]] || die "/boot is not mounted read-write"
    [ -d /boot/grub ] || die "the source system does not have a standard Debian /boot/grub directory"
    [ -s /boot/grub/grub.cfg ] || die "the source system has no usable /boot/grub/grub.cfg"
    env_path=/boot/grub/grubenv
    [ -f "$env_path" ] || die "GRUB environment block is missing"
    require_path_on_target_disk "$env_path" 'GRUB environment block'
    fstype="$(findmnt -n -o FSTYPE -T "$env_path")"
    abstraction="$(grub-probe --target=abstraction "$env_path")" ||
        die "could not identify GRUB environment storage"
    # A grub-reboot value on LVM/Btrfs/RAID can remain selected forever.
    # Refuse it, even if writing grubenv from the running Linux OS succeeds.
    case "$fstype:$abstraction" in
        ext2:|ext3:|ext4:) ;;
        *) die "one-shot GRUB needs a plain ext2/3/4 boot filesystem (found $fstype/$abstraction); use a trusted rescue/ISO" ;;
    esac

    if [ -e /boot/grub2/grub.cfg ]; then
        if [ /boot/grub/grub.cfg -ef /boot/grub2/grub.cfg ]; then
            linked_grub_dir=true
        elif [ "$(tr -d '\r\n' </boot/grub2/grub.cfg)" = 'chainloader (hd0)+1' ]; then
            # Known CloudCone-style external GRUB layout: its grub2 config
            # chainloads the disk MBR, whose Debian GRUB uses /boot/grub.
            # Recreate grub2 as an alias after installation so repeat reinstalls
            # retain both conventional lookup paths without copying old code.
            linked_grub_dir=true
        else
            die "independent /boot/grub and /boot/grub2 configurations are ambiguous; refusing to guess the active loader"
        fi
    fi

    if [ -d /sys/firmware/efi ]; then
        for path in /boot/efi /efi /boot; do
            if findmnt -rn -M "$path" >/dev/null 2>&1; then
                fstype="$(findmnt -n -o FSTYPE -M "$path" 2>/dev/null || true)"
                case "$fstype" in
                    vfat|fat|msdos) esp_mount=$path; break ;;
                esac
            fi
        done
        [ -n "$esp_mount" ] || die "UEFI is active but no EFI System Partition is mounted at /boot/efi, /efi, or /boot"
        require_path_on_target_disk "$esp_mount" 'EFI System Partition'
    fi
}

select_target_disk() {
    local -a disks=()
    local resolved type
    if [ -z "$target_disk" ]; then
        mapfile -t disks < <(resolve_root_disks)
        [ "${#disks[@]}" -gt 0 ] || die "could not resolve the disk below the current root filesystem"
        if [ "${#disks[@]}" -ne 1 ]; then
            printf 'Root filesystem spans these disks:\n' >&2
            printf '  /dev/%s\n' "${disks[@]}" >&2
            die "a root filesystem spanning multiple disks is not supported"
        fi
        target_disk=/dev/${disks[0]}
    fi

    resolved="$(readlink -f -- "$target_disk")"
    [ -b "$resolved" ] || die "not a block device: $target_disk"
    type="$(lsblk -dn -o TYPE "$resolved")"
    [ "$type" = disk ] || die "target must be a whole disk (TYPE=disk), not a partition or mapper: $resolved"
    target_disk=$resolved

    local root_disks
    root_disks="$(resolve_root_disks || true)"
    if ! printf '%s\n' "$root_disks" | grep -Fxq "${target_disk##*/}"; then
        warn "the selected target is not a disk backing the current root filesystem"
    fi
}

disk_facts() {
    local disk=$1 part
    disk_ptuuid="$(blkid -s PTUUID -o value "$disk" 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)"
    disk_size="$(blockdev --getsize64 "$disk")"
    [ "$(lsblk -dn -o RO "$disk" | tr -d '[:space:]')" = 0 ] ||
        die "target disk is read-only: $disk"
    [ "$disk_size" -ge "$MIN_DISK_BYTES" ] ||
        die "target disk is smaller than the tested 4 GiB minimum: $disk_size bytes"
    part="$(lsblk -nrpo NAME,TYPE "$disk" | awk '$2=="part" && !found {print $1; found=1}')"
    disk_anchor_partuuid=
    if [ -n "$part" ]; then
        disk_anchor_partuuid="$(blkid -s PARTUUID -o value "$part" 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)"
    fi
    if [ -z "$disk_ptuuid" ]; then
        warn "target disk has no readable partition-table UUID; selection will rely on size and any partition anchor"
    fi
    if [ -z "$disk_anchor_partuuid" ]; then
        warn "target disk has no partition PARTUUID anchor; selection will require a unique size/UUID match"
    fi
}

validate_disk_fingerprint_unique() {
    local disk count=0 id size anchor part
    while read -r disk; do
        [ -n "$disk" ] || continue
        size="$(blockdev --getsize64 "$disk" 2>/dev/null || true)"
        [ "$size" = "$disk_size" ] || continue
        id="$(blkid -s PTUUID -o value "$disk" 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)"
        [ "$id" = "$disk_ptuuid" ] || continue
        if [ -z "$disk_anchor_partuuid" ]; then
            anchor=1
        else
            anchor=
            while read -r part; do
                [ -n "$part" ] || continue
                if [ "$(blkid -s PARTUUID -o value "$part" 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)" = "$disk_anchor_partuuid" ]; then
                    anchor=1
                    break
                fi
            done < <(lsblk -nrpo NAME,TYPE "$disk" | awk '$2=="part" {print $1}')
        fi
        [ -n "$anchor" ] && count=$((count + 1))
    done < <(lsblk -dnpo NAME,TYPE | awk '$2=="disk" {print $1}')
    [ "$count" -eq 1 ] || die "disk fingerprint is not unique ($count matches); refusing unsafe unattended selection"
}

prepare_credentials() {
    credential_kind=password
    password_hash="$(printf '%s\n' "$password_value" | mkpasswd --method=yescrypt --stdin)"
    unset password_value
    [[ $password_hash == \$y\$* ]] || die "could not create a Debian yescrypt password hash"
}

route_token() {
    local key=$1; shift
    awk -v key="$key" '{for (i=1;i<NF;i++) if ($i==key) {print $(i+1); exit}}' <<<"$*"
}

collect_one_network() {
    local family=$1 probe=$2 line dev src gateway addr mac all_addrs extras cfg id candidate
    dev=; gateway=
    # Select the underlying default NIC, not a probe-specific WARP/TUN route.
    # Each multipath nexthop continuation is considered separately.
    while IFS= read -r line; do
        candidate="$(route_token dev "$line")"
        [ -n "$candidate" ] && [ -e "/sys/class/net/$candidate/device" ] || continue
        gateway="$(route_token via "$line")"
        [ -n "$gateway" ] || continue
        dev=$candidate
        break
    done < <(ip -"$family" route show table main default)
    [ -n "$dev" ] || return 1
    line="$(ip -"$family" route get "$probe" oif "$dev" 2>/dev/null | head -n 1 || true)"
    src="$(route_token src "$line")"
    all_addrs="$(ip -"$family" -o addr show scope global dev "$dev" | awk '$0 !~ / temporary / {print $4}')"
    [ -n "$all_addrs" ] || return 1
    addr="$(printf '%s\n' "$all_addrs" | awk -F/ -v src="$src" '$1==src {print; exit}')"
    [ -n "$addr" ] || addr="$(printf '%s\n' "$all_addrs" | head -n 1)"
    mac="$(tr '[:upper:]' '[:lower:]' <"/sys/class/net/$dev/address")"
    [[ "$mac" =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]] || die "invalid MAC address for $dev"
    id=${mac//:/}
    cfg="$initrd_dir/configs/net/$id"
    mkdir -p "$cfg"
    printf '%s\n' "$mac" >"$cfg/mac"
    printf '%s\n' "$dev" >"$cfg/source_interface"
    if [ "$family" = 4 ]; then
        printf '%s\n' "$addr" >"$cfg/ipv4_addr"
        printf '%s\n' "$gateway" >"$cfg/ipv4_gateway"
    else
        printf '%s\n' "$addr" >"$cfg/ipv6_addr"
        printf '%s\n' "$gateway" >"$cfg/ipv6_gateway"
        extras="$(printf '%s\n' "$all_addrs" | grep -Fxv "$addr" | paste -sd, - || true)"
        printf '%s\n' "$extras" >"$cfg/ipv6_extra_addrs"
    fi
    log "Captured IPv$family: $dev $addr via $gateway ($mac)"
}

collect_network() {
    local found=false
    if collect_one_network 4 1.1.1.1; then found=true; fi
    if collect_one_network 6 2606:4700:4700::1111; then found=true; fi
    $found || die "could not capture a usable default IPv4 or IPv6 route"
}

secure_curl() {
    env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin curl -q --no-insecure \
        --fail --show-error --silent --location \
        --proto '=https' --proto-redir '=https' --tlsv1.2 \
        --connect-timeout 15 --retry 3 --retry-delay 1 "$@"
}

release_hash_line() {
    local relative=$1
    awk -v target="$relative" '
        $0 == "SHA256:" {inside=1; next}
        inside && /^[A-Za-z][A-Za-z0-9-]*:/ {inside=0}
        inside && $3 == target {hash=$1; size=$2; count++}
        END {
            if (count != 1 || length(hash) != 64 || hash ~ /[^0-9a-fA-F]/ || size !~ /^[0-9]+$/) exit 1
            print hash, size
        }
    ' "$release_file"
}

verify_size_hash() {
    local file=$1 expected_hash=$2 expected_size=$3 actual
    actual="$(stat -c %s "$file")"
    [ "$actual" = "$expected_size" ] || die "size mismatch for ${file##*/}: expected $expected_size, got $actual"
    printf '%s  %s\n' "$expected_hash" "$file" | sha256sum --check --status ||
        die "SHA-256 mismatch for ${file##*/}"
}

download_release_file() {
    local relative=$1 output=$2 line hash size
    line="$(release_hash_line "$relative")"
    [ -n "$line" ] || die "signed InRelease has no SHA256 entry for $relative"
    read -r hash size <<<"$line"
    secure_curl --output "$output" "$mirror/dists/$codename/$relative"
    verify_size_hash "$output" "$hash" "$size"
}

load_signed_release() {
    local keyring=/usr/share/keyrings/debian-archive-keyring.gpg valid_until now expiry
    local signed_file="$workdir/InRelease"
    release_file="$workdir/Release.verified"
    log "Downloading and verifying Debian $codename InRelease"
    secure_curl --output "$signed_file" "$mirror/dists/$codename/InRelease"
    [ -r "$keyring" ] || die "Debian archive keyring not found: $keyring"
    gpgv --keyring "$keyring" --output "$release_file" "$signed_file" >/dev/null 2>&1 ||
        die "Debian InRelease signature verification failed"
    [ "$(sed -n 's/^Codename: //p' "$release_file")" = "$codename" ] || die "signed release codename mismatch"
    valid_until="$(sed -n 's/^Valid-Until: //p' "$release_file" | head -n 1)"
    if [ -n "$valid_until" ]; then
        now="$(date +%s)"
        expiry="$(date -d "$valid_until" +%s)" || die "cannot parse InRelease Valid-Until"
        [ "$now" -le "$expiry" ] || die "Debian mirror metadata expired at $valid_until"
    fi
}

load_package_indexes() {
    package_index_deb="$workdir/Packages.deb.xz"
    package_index_udeb="$workdir/Packages.udeb.xz"
    log "Downloading package indexes through the signed Release hash chain"
    download_release_file "main/binary-$arch/Packages.xz" "$package_index_deb"
    download_release_file "main/debian-installer/binary-$arch/Packages.xz" "$package_index_udeb"
    xz -t "$package_index_deb"
    xz -t "$package_index_udeb"
}

package_fields() {
    local index=$1 package=$2
    xz -dc "$index" | awk -v wanted="$package" '
        BEGIN {RS=""; FS="\n"}
        {
            package=""; filename=""; size=""; sha=""
            for (i=1; i<=NF; i++) {
                if ($i ~ /^Package: /) package=substr($i,10)
                else if ($i ~ /^Filename: /) filename=substr($i,11)
                else if ($i ~ /^Size: /) size=substr($i,7)
                else if ($i ~ /^SHA256: /) sha=substr($i,9)
            }
            if (!found && package==wanted && filename!="" && size!="" && sha!="") {
                print filename "\t" size "\t" sha
                found=1
            }
        }
    '
}

download_package() {
    local type=$1 package=$2 output=$3 index fields filename size hash
    case "$type" in deb) index=$package_index_deb ;; udeb) index=$package_index_udeb ;; *) die "internal package type error" ;; esac
    fields="$(package_fields "$index" "$package")"
    [ -n "$fields" ] || die "package not found in signed $type index: $package"
    IFS=$'\t' read -r filename size hash <<<"$fields"
    secure_curl --output "$output" "$mirror/$filename"
    verify_size_hash "$output" "$hash" "$size"
}

download_installer_images() {
    local sums_rel sums kernel_rel initrd_rel hash
    sums_rel="main/installer-$arch/current/images/SHA256SUMS"
    sums="$workdir/SHA256SUMS"
    download_release_file "$sums_rel" "$sums"
    kernel_rel="./netboot/debian-installer/$arch/linux"
    initrd_rel="./netboot/debian-installer/$arch/initrd.gz"
    for item in "$kernel_rel" "$initrd_rel"; do
        awk -v f="$item" '$2==f && length($1)==64 && $1 !~ /[^0-9a-f]/ {found++} END {exit found==1 ? 0 : 1}' "$sums" ||
            die "installer checksum list has no unambiguous entry for $item"
    done
    log "Downloading Debian Installer kernel and initrd"
    secure_curl --output "$workdir/linux" "$mirror/dists/$codename/${sums_rel%/*}/${kernel_rel#./}"
    secure_curl --output "$workdir/initrd.gz" "$mirror/dists/$codename/${sums_rel%/*}/${initrd_rel#./}"
    hash="$(awk -v f="$kernel_rel" '$2==f {print $1}' "$sums")"
    verify_size_hash "$workdir/linux" "$hash" "$(stat -c %s "$workdir/linux")"
    hash="$(awk -v f="$initrd_rel" '$2==f {print $1}' "$sums")"
    verify_size_hash "$workdir/initrd.gz" "$hash" "$(stat -c %s "$workdir/initrd.gz")"
}

install_embedded_assets() {
    local asset_root=$1
    cat >"$asset_root/initrd-network.sh" <<'__DEBIAN_REINSTALL_ASSET_initrd_network_sh__'
#!/bin/sh
# shellcheck shell=dash
# Debian-installer network transition helper. This is the audited Debian-
# reachable logic from upstream commit 6b3a341b4bb5c0b93f25cc0a0518e9bd5088504b.

# accept_ra 接收 RA + 自动配置网关
# autoconf  自动配置地址，依赖 accept_ra

mac_addr=$1
ipv4_addr=$2
ipv4_gateway=$3
ipv6_addr=$4
ipv6_gateway=$5
ipv6_extra_addrs=$6

DHCP_TIMEOUT=15
TEST_TIMEOUT=10

# 检测是否有网络是通过检测这些 IP 的端口是否开放
# 因为 debian initrd 没有 nslookup
# 改成 generate_204？但检测网络时可能 resolv.conf 为空
# HTTP 80
# HTTPS/DOH 443
# DOT 853
ipv4_dns1='8.8.8.8'
ipv4_dns2='1.1.1.1'
ipv6_dns1='2001:4860:4860::8888'
ipv6_dns2='2606:4700:4700::1111'

# 找到主网卡。Debian Installer initrd 不一定包含 xargs。
get_ethx() {
    # 过滤 azure vf (带 master ethx)
    # 2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc mq state UP qlen 1000\    link/ether 60:45:bd:21:8a:51 brd ff:ff:ff:ff:ff:ff
    # 3: eth1: <BROADCAST,MULTICAST,UP,LOWER_UP800> mtu 1500 qdisc mq master eth0 state UP qlen 1000\    link/ether 60:45:bd:21:8a:51 brd ff:ff:ff
    ip -o link | awk -v mac="$mac_addr" '
        {
            matched=0; slave=0
            for (i=1;i<=NF;i++) {
                if ($i=="master") slave=1
                if ($i=="link/ether" && tolower($(i+1))==tolower(mac)) matched=1
            }
            if (matched && !slave) {
                name=$2; sub(/:$/, "", name); sub(/@.*/, "", name)
                count++; selected=name
            }
        }
        END {if (count==1) print selected; else exit 1}
    '
}

get_ipv4_gateway() {
    ip -4 route show default dev "$ethx" | head -1 | cut -d ' ' -f3
}

get_ipv6_gateway() {
    ip -6 route show default dev "$ethx" | head -1 | cut -d ' ' -f3
}

get_first_ipv4_addr() {
    ip -4 -o addr show scope global dev "$ethx" | head -1 | grep -o '[0-9\.]*/[0-9]*'
}

get_first_ipv4_gateway() {
    ip -4 route show default dev "$ethx" | head -1 | cut -d' ' -f3
}

remove_netmask() {
    cut -d/ -f1
}

get_first_ipv6_addr() {
    ip -6 -o addr show scope global dev "$ethx" | head -1 | grep -o '[0-9a-f\:]*/[0-9]*'
}

get_first_ipv6_gateway() {
    ip -6 route show default dev "$ethx" | head -1 | cut -d' ' -f3
}

is_have_ipv4_addr() {
    ip -4 addr show scope global dev "$ethx" | grep -q inet
}

is_have_ipv6_addr() {
    ip -6 addr show scope global dev "$ethx" | grep -q inet6
}

is_have_ipv4_gateway() {
    ip -4 route show default dev "$ethx" | grep -q .
}

is_have_ipv6_gateway() {
    ip -6 route show default dev "$ethx" | grep -q .
}

is_have_ipv4() {
    is_have_ipv4_addr && is_have_ipv4_gateway
}

is_have_ipv6() {
    is_have_ipv6_addr && is_have_ipv6_gateway
}

add_missing_ipv4_config() {
    if [ -n "$ipv4_addr" ] && [ -n "$ipv4_gateway" ]; then
        if ! is_have_ipv4_addr; then
            ip -4 addr add "$ipv4_addr" dev "$ethx"
        fi

        if ! is_have_ipv4_gateway; then
            # 如果 dhcp 无法设置onlink网关，那么在这里设置
            ip -4 route add "$ipv4_gateway" dev "$ethx"
            ip -4 route add default via "$ipv4_gateway" dev "$ethx"
        fi
    fi
}

add_missing_ipv6_config() {
    if [ -n "$ipv6_addr" ] && [ -n "$ipv6_gateway" ]; then
        if ! is_have_ipv6_addr; then
            ip -6 addr add "$ipv6_addr" dev "$ethx"
        fi

        if ! is_have_ipv6_gateway; then
            # 如果 dhcp 无法设置onlink网关，那么在这里设置
            ip -6 route add "$ipv6_gateway" dev "$ethx"
            ip -6 route add default via "$ipv6_gateway" dev "$ethx"
        fi

        # 添加额外的 IPv6 地址（逗号分隔）
        if [ -n "$ipv6_extra_addrs" ]; then
            printf '%s\n' "$ipv6_extra_addrs" | tr ',' '\n' | while IFS= read -r addr; do
                if [ -n "$addr" ]; then
                    ip -6 addr add "$addr" dev "$ethx" 2>/dev/null || true
                fi
            done
        fi
    fi
}

is_need_test_ipv4() {
    is_have_ipv4 && ! $ipv4_has_internet
}

is_need_test_ipv6() {
    is_have_ipv6 && ! $ipv6_has_internet
}

# 测试方法：
# ping   有的机器禁止
# nc     测试 dot doh 端口是否开启
# wget   测试下载

test_by_wget() {
    src=$1
    dst=$2

    # ipv6 需要添加 []
    if echo "$dst" | grep -q ':'; then
        url="https://[$dst]"
    else
        url="https://$dst"
    fi

    # tcp 443 通了就算成功，不管 http 是不是 404
    # grep -m1 快速返回
    wget -T "$TEST_TIMEOUT" \
        --bind-address="$src" \
        --max-redirect 0 \
        --tries 1 \
        -O /dev/null \
        "$url" 2>&1 | grep -iq -m1 connected
}

test_connect() {
    test_by_wget "$1" "$2"
}

test_internet() {
    for i in $(seq 2); do
        echo "Testing Internet Connection. Test $i... "
        if is_need_test_ipv4 &&
            current_ipv4_addr="$(get_first_ipv4_addr | remove_netmask)" &&
            { test_connect "$current_ipv4_addr" "$ipv4_dns1" ||
                test_connect "$current_ipv4_addr" "$ipv4_dns2"; } >/dev/null 2>&1; then
            echo "IPv4 has internet."
            ipv4_has_internet=true
        fi
        if is_need_test_ipv6 &&
            current_ipv6_addr="$(get_first_ipv6_addr | remove_netmask)" &&
            { test_connect "$current_ipv6_addr" "$ipv6_dns1" ||
                test_connect "$current_ipv6_addr" "$ipv6_dns2"; } >/dev/null 2>&1; then
            echo "IPv6 has internet."
            ipv6_has_internet=true
        fi
        if ! is_need_test_ipv4 && ! is_need_test_ipv6; then
            break
        fi
        sleep 1
    done
}

flush_ipv4_config() {
    ip -4 addr flush scope global dev "$ethx"
    ip -4 route flush dev "$ethx"
    # DHCP 获取的 IP 不是重装前的 IP 时，一并删除 DHCP 获取的 DNS，以防 DNS 无效
    sed -i "/\./d" /etc/resolv.conf
}

should_disable_dhcpv4=false
should_disable_accept_ra=false
should_disable_autoconf=false

flush_ipv6_config() {
    if $should_disable_accept_ra; then
        echo 0 >"/proc/sys/net/ipv6/conf/$ethx/accept_ra"
    fi
    if $should_disable_autoconf; then
        echo 0 >"/proc/sys/net/ipv6/conf/$ethx/autoconf"
    fi
    ip -6 addr flush scope global dev "$ethx"
    ip -6 route flush dev "$ethx"
    # DHCP 获取的 IP 不是重装前的 IP 时，一并删除 DHCP 获取的 DNS，以防 DNS 无效
    sed -i "/:/d" /etc/resolv.conf
}

for i in $(seq 20); do
    if ethx=$(get_ethx); then
        break
    fi
    sleep 1
done

if [ -z "$ethx" ]; then
    echo "Not found network card: $mac_addr"
    exit 1
fi

echo "Configuring $ethx ($mac_addr)..."

# Bring up loopback before the installer services start.
ip link set dev lo up

# 开启 ethx
ip link set dev "$ethx" up
sleep 1

# Debian Installer DHCPv4, SLAAC and DHCPv6 sequence.
[ -f /usr/share/debconf/confmodule ] || {
    echo "Debian Installer debconf module is missing." >&2
    exit 1
}
# shellcheck source=/dev/null
. /usr/share/debconf/confmodule

db_progress STEP 1
db_progress INFO netcfg/dhcp_progress
udhcpc -i "$ethx" -f -q -n || true
db_progress STEP 1

db_progress INFO netcfg/slaac_wait_title
# https://salsa.debian.org/installer-team/netcfg/-/blob/master/autoconfig.c#L148
cat <<EOF >/var/lib/netcfg/dhcp6c.conf
interface $ethx {
    send ia-na 0;
    request domain-name-servers;
    request domain-name;
    script "/lib/netcfg/print-dhcp6c-info";
};

id-assoc na 0 {
};
EOF
dhcp6c -c /var/lib/netcfg/dhcp6c.conf "$ethx" || true
sleep "$DHCP_TIMEOUT"
[ ! -s /var/run/dhcp6c.pid ] || kill -9 "$(cat /var/run/dhcp6c.pid)" || true
db_progress STEP 1

db_subst netcfg/link_detect_progress interface "$ethx"
db_progress INFO netcfg/link_detect_progress

# 等待slaac
# 有ipv6地址就跳过，不管是slaac或者dhcpv6
# 因为会在trans里判断
# 这里等待5秒就够了，因为之前尝试获取dhcp6也用了一段时间
for i in $(seq 5 -1 0); do
    is_have_ipv6 && break
    echo "waiting slaac for ${i}s"
    sleep 1
done

# 记录是否有动态地址
# 由于还没设置静态ip，所以有条目表示有动态地址
is_have_ipv4_addr && dhcpv4=true || dhcpv4=false
is_have_ipv6_addr && dhcpv6_or_slaac=true || dhcpv6_or_slaac=false
is_have_ipv6_gateway && ra_has_gateway=true || ra_has_gateway=false

# 如果自动获取的 IP 不是重装前的，则改成静态，使用之前的 IP
# 只比较 IP，不比较掩码/网关，因为
# 1. 假设掩码/网关导致无法上网，后面也会检测到并改成静态
# 2. 不同 VPS DHCPv6/SLAAC 实现可能返回不同的前缀长度
if $dhcpv4 && [ -n "$ipv4_addr" ] && [ -n "$ipv4_gateway" ] &&
    ! [ "$(echo "$ipv4_addr" | cut -d/ -f1)" = "$(get_first_ipv4_addr | cut -d/ -f1)" ]; then
    echo "IPv4 address obtained from DHCP is different from old system."
    should_disable_dhcpv4=true
    flush_ipv4_config
fi
if $dhcpv6_or_slaac && [ -n "$ipv6_addr" ] && [ -n "$ipv6_gateway" ] &&
    ! [ "$(echo "$ipv6_addr" | cut -d/ -f1)" = "$(get_first_ipv6_addr | cut -d/ -f1)" ]; then
    echo "IPv6 address obtained from SLAAC/DHCPv6 is different from old system."
    should_disable_accept_ra=true
    should_disable_autoconf=true
    flush_ipv6_config
fi

# 设置静态地址，或者补充 DHCP 客户端无法设置的 off-link 网关
add_missing_ipv4_config
add_missing_ipv6_config

# 检查 ipv4/ipv6 是否连接联网
ipv4_has_internet=false
ipv6_has_internet=false
test_internet

# 如果无法上网，并且自动获取的 掩码/网关 不是重装前的，则改成静态
# ip_addr 包括 IP/掩码，所以可以用来判断掩码是否不同
# IP 不同的情况在前面已经改成静态了
if ! $ipv4_has_internet &&
    $dhcpv4 && [ -n "$ipv4_addr" ] && [ -n "$ipv4_gateway" ] &&
    ! { [ "$ipv4_addr" = "$(get_first_ipv4_addr)" ] && [ "$ipv4_gateway" = "$(get_first_ipv4_gateway)" ]; }; then
    echo "IPv4 netmask/gateway obtained from DHCP is different from old system."
    should_disable_dhcpv4=true
    flush_ipv4_config
    add_missing_ipv4_config
    test_internet
fi
# 有可能是静态 IPv6 但能从 RA 获取到网关，因此加上 || $ra_has_gateway
if ! $ipv6_has_internet &&
    { $dhcpv6_or_slaac || $ra_has_gateway; } &&
    [ -n "$ipv6_addr" ] && [ -n "$ipv6_gateway" ] &&
    ! { [ "$ipv6_addr" = "$(get_first_ipv6_addr)" ] && [ "$ipv6_gateway" = "$(get_first_ipv6_gateway)" ]; }; then
    echo "IPv6 netmask/gateway obtained from SLAAC/DHCPv6 is different from old system."
    should_disable_accept_ra=true
    should_disable_autoconf=true
    flush_ipv6_config
    add_missing_ipv6_config
    test_internet
fi

# A blocked probe endpoint is NOT evidence that an address family is invalid.
# Preserve a complete address + default route, including captured static
# settings. Only remove partial auto-configuration with no usable gateway.
is_have_ipv4 && ipv4_configured=true || ipv4_configured=false
is_have_ipv6 && ipv6_configured=true || ipv6_configured=false
if ! $ipv4_configured; then
    if $dhcpv4; then
        should_disable_dhcpv4=true
    fi
    flush_ipv4_config
fi
if ! $ipv6_configured; then
    # 防止删除 IPv6 后再次通过 SLAAC 获得
    # 不用判断 || $ra_has_gateway ，因为没有 IPv6 地址但有 IPv6 网关时，不会出现下载问题
    if $dhcpv6_or_slaac; then
        should_disable_accept_ra=true
        should_disable_autoconf=true
    fi
    flush_ipv6_config
fi

# Save the probed network state for the installed Debian renderer.
netconf="/dev/netconf/$ethx"
mkdir -p "$netconf"
$dhcpv4 && echo 1 >"$netconf/dhcpv4" || echo 0 >"$netconf/dhcpv4"
$dhcpv6_or_slaac && echo 1 >"$netconf/dhcpv6_or_slaac" || echo 0 >"$netconf/dhcpv6_or_slaac"
$should_disable_dhcpv4 && echo 1 >"$netconf/should_disable_dhcpv4" || echo 0 >"$netconf/should_disable_dhcpv4"
$should_disable_accept_ra && echo 1 >"$netconf/should_disable_accept_ra" || echo 0 >"$netconf/should_disable_accept_ra"
$should_disable_autoconf && echo 1 >"$netconf/should_disable_autoconf" || echo 0 >"$netconf/should_disable_autoconf"
echo "$ethx" >"$netconf/ethx"
echo "$mac_addr" >"$netconf/mac_addr"
echo "$ipv4_addr" >"$netconf/ipv4_addr"
echo "$ipv4_gateway" >"$netconf/ipv4_gateway"
echo "$ipv6_addr" >"$netconf/ipv6_addr"
echo "$ipv6_gateway" >"$netconf/ipv6_gateway"
echo "$ipv6_extra_addrs" >"$netconf/ipv6_extra_addrs"
$ipv4_has_internet && echo 1 >"$netconf/ipv4_has_internet" || echo 0 >"$netconf/ipv4_has_internet"
$ipv6_has_internet && echo 1 >"$netconf/ipv6_has_internet" || echo 0 >"$netconf/ipv6_has_internet"
$ipv4_configured && echo 1 >"$netconf/ipv4_configured" || echo 0 >"$netconf/ipv4_configured"
$ipv6_configured && echo 1 >"$netconf/ipv6_configured" || echo 0 >"$netconf/ipv6_configured"
if { $ipv4_configured && ! $ipv4_has_internet; } || { $ipv6_configured && ! $ipv6_has_internet; }; then
    echo 'Probe inconclusive: preserving complete IP/gateway configuration.' >&2
fi

# Never retain DNS learned from the provider. Rebuild atomically from all NICs
# that have completed probing so an offline secondary NIC cannot erase the
# usable protocol family of an earlier NIC.
resolver_tmp="/tmp/resolv.conf.debian-reinstall.$$"
: >"$resolver_tmp"
has_online_ipv4=false
has_online_ipv6=false
for state in /dev/netconf/*; do
    [ -d "$state" ] || continue
    [ "$(cat "$state/ipv4_configured" 2>/dev/null)" = 1 ] && has_online_ipv4=true
    [ "$(cat "$state/ipv6_configured" 2>/dev/null)" = 1 ] && has_online_ipv6=true
done
if $has_online_ipv4; then
    printf 'nameserver %s\nnameserver %s\n' "$ipv4_dns1" "$ipv4_dns2" >>"$resolver_tmp"
fi
if $has_online_ipv6; then
    printf 'nameserver %s\nnameserver %s\n' "$ipv6_dns1" "$ipv6_dns2" >>"$resolver_tmp"
fi
mv "$resolver_tmp" /etc/resolv.conf
__DEBIAN_REINSTALL_ASSET_initrd_network_sh__
    cat >"$asset_root/debian-network-render.sh" <<'__DEBIAN_REINSTALL_ASSET_debian_network_render_sh__'
#!/bin/sh
# Debian-installer network renderer.
# Derived from bin456789/reinstall trans.sh at commit
# 6b3a341b4bb5c0b93f25cc0a0518e9bd5088504b, Debian-reachable path only.

set -e

TRUE=0
FALSE=1

info() {
    printf '%s\n' "***** $* *****" >&2
}

show_netconf() {
    grep -r . /dev/netconf/ 2>/dev/null || true
}

get_ra() {
    # File-backed per-NIC cache survives command-substitution subshells.
    ra_cache="/dev/netconf/$ethx/ra.txt"
    if [ ! -f "$ra_cache" ]; then
        info "Gathering IPv6 router-advertisement information"
        timeout 8 rdisc6 -1 "$ethx" >"$ra_cache" 2>/dev/null || true
    fi
    ra="$(cat "$ra_cache")"
}

get_netconf() {
    key=$1
    case "$key" in
        slaac)
            get_ra
            echo "$ra" | grep 'Autonomous address conf' | grep -q Yes && res=1 || res=0
            ;;
        dhcpv6)
            get_ra
            echo "$ra" | grep 'Stateful address conf' | grep -q Yes && res=1 || res=0
            ;;
        rdnss)
            get_ra
            res="$(echo "$ra" | grep 'Recursive DNS server' | cut -d: -f2- || true)"
            ;;
        other)
            get_ra
            echo "$ra" | grep 'Stateful other conf' | grep -q Yes && res=1 || res=0
            ;;
        *)
            res="$(cat "/dev/netconf/$ethx/$key" 2>/dev/null || true)"
            ;;
    esac
    printf '%s' "$res"
}

is_ipv4_online() { [ "$(get_netconf ipv4_configured)" = 1 ]; }
is_ipv6_online() { [ "$(get_netconf ipv6_configured)" = 1 ]; }
disable_dhcpv4() { [ "$(get_netconf should_disable_dhcpv4)" = 1 ]; }
disable_accept_ra() { [ "$(get_netconf should_disable_accept_ra)" = 1 ]; }
disable_autoconf() { [ "$(get_netconf should_disable_autoconf)" = 1 ]; }
has_dynamic_v6() { [ "$(get_netconf dhcpv6_or_slaac)" = 1 ]; }

is_dhcpv4() {
    is_ipv4_online && ! disable_dhcpv4 && [ "$(get_netconf dhcpv4)" = 1 ]
}

is_staticv4() {
    is_ipv4_online || return 1
    is_dhcpv4 && return 1
    [ -n "$(get_netconf ipv4_addr)" ] && [ -n "$(get_netconf ipv4_gateway)" ]
}

is_slaac() {
    is_ipv6_online || return 1
    has_dynamic_v6 || return 1
    disable_accept_ra && return 1
    disable_autoconf && return 1
    [ "$(get_netconf slaac)" = 1 ]
}

is_dhcpv6() {
    is_ipv6_online || return 1
    has_dynamic_v6 || return 1
    disable_accept_ra && return 1
    disable_autoconf && return 1
    [ "$(get_netconf dhcpv6)" = 1 ] || return 1
    ip -6 -o addr show scope global dev "$ethx" | grep -q .
}

is_staticv6() {
    is_ipv6_online || return 1
    is_slaac && return 1
    is_dhcpv6 && return 1
    [ -n "$(get_netconf ipv6_addr)" ] && [ -n "$(get_netconf ipv6_gateway)" ]
}

has_ipv6() {
    is_slaac || is_dhcpv6 || is_staticv6
}

has_rdnss() {
    [ -n "$(get_netconf rdnss)" ]
}

needs_manual_dnsv6() {
    has_ipv6 || return "$FALSE"
    is_dhcpv6 && return "$FALSE"
    is_staticv6 && return "$TRUE"
    if is_slaac && [ "$(get_netconf other)" != 1 ] && ! has_rdnss; then
        return "$TRUE"
    fi
    return "$FALSE"
}

current_dns() {
    case "$1" in
        4) printf '%s\n' 8.8.8.8 1.1.1.1 ;;
        6) printf '%s\n' 2001:4860:4860::8888 2606:4700:4700::1111 ;;
        *) return 1 ;;
    esac
}

get_eths() {
    for path in /dev/netconf/*; do
        [ -d "$path" ] && basename "$path"
    done
}

render_interfaces() {
    conf_file=$1
    rm -f "$conf_file"
    cat >>"$conf_file" <<'EOF'
source /etc/network/interfaces.d/*

auto lo
iface lo inet loopback
EOF

    for ethx in $(get_eths); do
        mac_addr="$(get_netconf mac_addr)"
        {
            echo
            # The first-boot repair service uses this marker if the installed
            # kernel assigns a different predictable interface name.
            echo "# mac $mac_addr"
            echo "auto $ethx"
        } >>"$conf_file"

        if is_dhcpv4; then
            echo "iface $ethx inet dhcp" >>"$conf_file"
            for dns in $(current_dns 4); do
                echo "    dns-nameservers $dns" >>"$conf_file"
            done
        elif is_staticv4; then
            ipv4_addr="$(get_netconf ipv4_addr)"
            ipv4_gateway="$(get_netconf ipv4_gateway)"
            cat >>"$conf_file" <<EOF
iface $ethx inet static
    address $ipv4_addr
    up ip -4 route replace $ipv4_gateway dev $ethx
    up ip -4 route replace default via $ipv4_gateway dev $ethx
EOF
            for dns in $(current_dns 4); do
                echo "    dns-nameservers $dns" >>"$conf_file"
            done
        fi

        has_ipv6_iface=false
        if is_slaac; then
            echo "iface $ethx inet6 auto" >>"$conf_file"
            has_ipv6_iface=true
        elif is_dhcpv6; then
            # Debian 13's dhcpcd/ifupdown combination loses DHCPv4 when both
            # stanzas say dhcp. "auto" preserves SLAAC/DHCPv6 behavior.
            echo "iface $ethx inet6 auto" >>"$conf_file"
            has_ipv6_iface=true
        elif is_staticv6; then
            ipv6_addr="$(get_netconf ipv6_addr)"
            ipv6_gateway="$(get_netconf ipv6_gateway)"
            cat >>"$conf_file" <<EOF
iface $ethx inet6 static
    address $ipv6_addr
    up ip -6 route replace $ipv6_gateway dev $ethx
    up ip -6 route replace default via $ipv6_gateway dev $ethx
EOF
            extra="$(get_netconf ipv6_extra_addrs)"
            if [ -n "$extra" ]; then
                old_ifs=$IFS
                IFS=,
                for addr in $extra; do
                    [ -n "$addr" ] && echo "    post-up ip -6 addr add $addr dev $ethx" >>"$conf_file"
                done
                IFS=$old_ifs
            fi
            has_ipv6_iface=true
        fi

        if ! $has_ipv6_iface && { disable_accept_ra || disable_autoconf; }; then
            echo "iface $ethx inet6 manual" >>"$conf_file"
        fi

        if needs_manual_dnsv6; then
            for dns in $(current_dns 6); do
                echo "    dns-nameservers $dns" >>"$conf_file"
            done
        fi

        disable_accept_ra && echo "    accept_ra 0" >>"$conf_file"
        disable_autoconf && echo "    autoconf 0" >>"$conf_file"
        # A false final condition above is normal and must not become the
        # function's return status under set -e.
        :
    done
}

render_interfaces "${1:-/etc/network/interfaces}"
__DEBIAN_REINSTALL_ASSET_debian_network_render_sh__
    cat >"$asset_root/debian-netcfg.sh" <<'__DEBIAN_REINSTALL_ASSET_debian_netcfg_sh__'
#!/bin/sh
# Configure the Debian installer network from facts captured on the old system.

set -eu

found=false
for cfg in /configs/net/*; do
    [ -d "$cfg" ] || continue
    found=true
    mac="$(cat "$cfg/mac")"
    ipv4_addr="$(cat "$cfg/ipv4_addr" 2>/dev/null || true)"
    ipv4_gateway="$(cat "$cfg/ipv4_gateway" 2>/dev/null || true)"
    ipv6_addr="$(cat "$cfg/ipv6_addr" 2>/dev/null || true)"
    ipv6_gateway="$(cat "$cfg/ipv6_gateway" 2>/dev/null || true)"
    ipv6_extra="$(cat "$cfg/ipv6_extra_addrs" 2>/dev/null || true)"
    /initrd-network.sh "$mac" "$ipv4_addr" "$ipv4_gateway" \
        "$ipv6_addr" "$ipv6_gateway" "$ipv6_extra"
done

if ! $found; then
    echo "No captured network configuration was embedded." >&2
    exit 1
fi

/debian-network-render.sh /etc/network/interfaces
chmod 0600 /etc/network/interfaces
__DEBIAN_REINSTALL_ASSET_debian_netcfg_sh__
    cat >"$asset_root/get-target-disk.sh" <<'__DEBIAN_REINSTALL_ASSET_get_target_disk_sh__'
#!/bin/sh
# Resolve the installation disk without trusting its /dev name. Refuse ambiguity.

set -eu

cfg=/configs/disk
expected_ptuuid="$(sed -e 'y/ABCDEF/abcdef/' -e 's/^0x//' "$cfg/ptuuid" 2>/dev/null || true)"
expected_partuuid="$(sed 'y/ABCDEF/abcdef/' "$cfg/anchor_partuuid" 2>/dev/null || true)"
expected_size="$(cat "$cfg/size_bytes")"

disk_size() {
    sectors="$(cat "/sys/block/$1/size" 2>/dev/null || echo 0)"
    echo "$((sectors * 512))"
}

disk_id() {
    value=""
    if command -v sfdisk >/dev/null 2>&1; then
        value="$(sfdisk --disk-id "/dev/$1" 2>/dev/null || true)"
    fi
    if [ -z "$value" ] && command -v fdisk >/dev/null 2>&1; then
        value="$(fdisk -l "/dev/$1" 2>/dev/null | sed -n \
            -e 's/^Disk identifier: *//p' \
            -e 's/^Disk identifier (GUID): *//p' | head -n 1)"
    fi
    printf '%s' "$value" | sed -e 'y/ABCDEF/abcdef/' -e 's/^0x//'
}

has_anchor_partuuid() {
    disk=$1
    [ -n "$expected_partuuid" ] || return 0
    for node in "/sys/block/$disk"/*; do
        [ -f "$node/partition" ] || continue
        part="$(basename "$node")"
        part_number="$(cat "$node/partition")"
        value=""
        # Debian Installer's compact BusyBox blkid does not reliably report
        # GPT PARTUUIDs.  fdisk-udeb is already added to the initrd, and its
        # sfdisk handles MBR, GPT, virtio, NVMe and MMC partition naming alike.
        if command -v sfdisk >/dev/null 2>&1; then
            value="$(sfdisk --part-uuid "/dev/$disk" "$part_number" 2>/dev/null |
                sed 'y/ABCDEF/abcdef/' || true)"
        fi
        if [ -z "$value" ] && command -v blkid >/dev/null 2>&1; then
            value="$(blkid -s PARTUUID -o value "/dev/$part" 2>/dev/null |
                sed 'y/ABCDEF/abcdef/' || true)"
        fi
        [ "$value" = "$expected_partuuid" ] && return 0
    done
    return 1
}

candidate_file=/tmp/debian-reinstall-disk-candidates
: >"$candidate_file"

for path in /sys/block/*; do
    disk="$(basename "$path")"
    case "$disk" in
        loop*|ram*|zram*|sr*|fd*|nbd*|dm-*|md*) continue ;;
    esac
    [ "$(disk_size "$disk")" = "$expected_size" ] || continue
    if [ -n "$expected_ptuuid" ]; then
        [ "$(disk_id "$disk")" = "$expected_ptuuid" ] || continue
    fi
    has_anchor_partuuid "$disk" || continue
    echo "$disk" >>"$candidate_file"
done

count="$(wc -l <"$candidate_file" | tr -d ' ')"
if [ "$count" != 1 ]; then
    echo "Refusing to select an installation disk: expected one match, found $count." >&2
    echo "Expected PTUUID=$expected_ptuuid PARTUUID=$expected_partuuid SIZE=$expected_size" >&2
    for path in /sys/block/*; do
        disk="$(basename "$path")"
        case "$disk" in
            loop*|ram*|zram*|sr*|fd*|nbd*|dm-*|md*) continue ;;
        esac
        echo "Observed /dev/$disk: PTUUID=$(disk_id "$disk") SIZE=$(disk_size "$disk")" >&2
    done
    sed 's/^/Candidate: \/dev\//' "$candidate_file" >&2 || true
    exit 1
fi

disk="$(cat "$candidate_file")"
case "$disk" in
    *[!A-Za-z0-9_.-]*) echo "Unsafe disk name: $disk" >&2; exit 1 ;;
esac
echo "/dev/$disk"
__DEBIAN_REINSTALL_ASSET_get_target_disk_sh__
    cat >"$asset_root/can-use-cloud-kernel.sh" <<'__DEBIAN_REINSTALL_ASSET_can_use_cloud_kernel_sh__'
#!/bin/sh
# Return success only when the current block/network devices use drivers present
# in Debian's cloud kernel. Unknown hardware deliberately falls back to generic.

set -eu

drivers_for_path() {
    path="$(readlink -f "$1")"
    while [ "$path" != / ]; do
        if [ -L "$path/driver/module" ]; then
            basename "$(readlink -f "$path/driver/module")"
        elif [ -L "$path/driver" ]; then
            basename "$(readlink -f "$path/driver")"
        fi
        path="$(dirname "$path")"
    done | sort -u
}

disk=${1#/dev/}
shift
block_ok='^(ata_generic|ata_piix|pata_legacy|nvme|virtio_blk|virtio_scsi|xen_blkfront|xen_scsifront|hv_storvsc|vmw_pvscsi)$'
net_ok='^(ena|gve|mana|virtio_net|xen_netfront|hv_netvsc|vmxnet3|mlx4_en|mlx4_core|mlx5_core|ixgbevf)$'

drivers="$(drivers_for_path "/sys/block/$disk")"
printf '%s\n' "$drivers" | grep -Eq "$block_ok" || exit 1

seen=""
for eth in "$@"; do
    [ -n "$eth" ] || continue
    case " $seen " in *" $eth "*) continue ;; esac
    seen="$seen $eth"
    drivers="$(drivers_for_path "/sys/class/net/$eth")"
    printf '%s\n' "$drivers" | grep -Eq "$net_ok" || exit 1
done

__DEBIAN_REINSTALL_ASSET_can_use_cloud_kernel_sh__
    cat >"$asset_root/fix-eth-name.sh" <<'__DEBIAN_REINSTALL_ASSET_fix_eth_name_sh__'
#!/bin/sh
# One-shot Debian ifupdown repair for a NIC name changed by the installed kernel.

set -eu

cleanup_self() {
    rm -f \
        /etc/systemd/system/multi-user.target.wants/fix-eth-name.service \
        /etc/systemd/system/fix-eth-name.service \
        /usr/local/lib/debian-reinstall/fix-eth-name.sh
    rmdir /usr/local/lib/debian-reinstall 2>/dev/null || true
    rm -f /var/log/debian-reinstall-network-repair.error
}

fail() {
    message=$1
    printf '%s\n' "$message" >/var/log/debian-reinstall-network-repair.error
    printf '%s\n' "$message" >&2
    exit 1
}

trap 'exit 1' HUP INT TERM

old_state=
stable=0
seen=false
settled=false
i=0
while [ "$i" -lt 90 ]; do
    i=$((i + 1))
    state="$(ip -o link | sed -n '/: lo:/!p')"
    [ -n "$state" ] && seen=true
    if $seen && [ "$state" = "$old_state" ]; then
        stable=$((stable + 1))
    else
        stable=0
    fi
    if [ "$stable" -ge 10 ]; then
        settled=true
        break
    fi
    old_state=$state
    if [ "$i" -eq 1 ] || [ $((i % 5)) -eq 0 ]; then
        printf 'Waiting for stable network names: %ss, stable %s/10s\n' "$i" "$stable"
    fi
    sleep 1
done
$seen || fail 'No network interface appeared during the first-boot repair window.'
$settled || fail 'Network interface names did not remain stable for 10 seconds.'

interface_for_mac() {
    wanted="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    for path in /sys/class/net/*; do
        name="$(basename "$path")"
        [ "$name" = lo ] && continue
        [ -e "$path/address" ] || continue
        # Azure accelerated-networking VFs share a MAC and have a master.
        [ -L "$path/master" ] && continue
        actual="$(tr '[:upper:]' '[:lower:]' <"$path/address")"
        [ "$actual" = "$wanted" ] && printf '%s\n' "$name"
    done
}

file=/etc/network/interfaces
[ -f "$file" ] || fail 'The generated /etc/network/interfaces file is missing.'
tmp="$file.debian-reinstall.tmp"
trap 'rm -f "$tmp"' EXIT
: >"$tmp"
mapped=
marker_count=0
mapped_count=0

while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
        '# mac '*)
            marker_count=$((marker_count + 1))
            mac="${line##* }"
            matches="$(interface_for_mac "$mac" || true)"
            count="$(printf '%s\n' "$matches" | sed '/^$/d' | wc -l | tr -d ' ')"
            if [ "$count" != 1 ]; then
                fail "Expected exactly one physical interface for MAC $mac, found $count."
            fi
            mapped="$matches"
            mapped_count=$((mapped_count + 1))
            continue
            ;;
        'iface '*|'auto '*|'allow-hotplug '*)
            if [ -n "$mapped" ]; then
                line="$(printf '%s\n' "$line" | awk -v n="$mapped" '{$2=n; print}')"
            fi
            ;;
        *' dev '*)
            if [ -n "$mapped" ]; then
                line="$(printf '%s\n' "$line" | sed -E "s/( dev )[^ ]+/\\1$mapped/")"
            fi
            ;;
    esac
    printf '%s\n' "$line" >>"$tmp"
done <"$file"

[ "$marker_count" -gt 0 ] || fail 'No MAC markers were found in /etc/network/interfaces.'
[ "$mapped_count" = "$marker_count" ] || fail 'Not every generated interface could be mapped by MAC address.'

chmod --reference="$file" "$tmp" 2>/dev/null || chmod 0600 "$tmp"
mv "$tmp" "$file"
trap - EXIT
cleanup_self
__DEBIAN_REINSTALL_ASSET_fix_eth_name_sh__
    cat >"$asset_root/fix-eth-name.service" <<'__DEBIAN_REINSTALL_ASSET_fix_eth_name_service__'
[Unit]
Description=Repair Debian network interface names after reinstall
ConditionPathExists=/usr/local/lib/debian-reinstall/fix-eth-name.sh
After=systemd-udev-settle.service
Before=network-pre.target networking.service network.target
Wants=network-pre.target

[Service]
Type=oneshot
TimeoutStartSec=120
StandardOutput=journal+console
StandardError=journal+console
ExecStart=/usr/local/lib/debian-reinstall/fix-eth-name.sh

[Install]
WantedBy=multi-user.target
__DEBIAN_REINSTALL_ASSET_fix_eth_name_service__
    cat >"$asset_root/fix-console.sh" <<'__DEBIAN_REINSTALL_ASSET_fix_console_sh__'
#!/bin/sh
# One-shot repair for a serial console that the installed kernel exposes but
# the provider has not connected to a usable terminal.

set -eu

error_file=/var/log/debian-reinstall-console-repair.error
script_file=/usr/local/lib/debian-reinstall/fix-console.sh
unit_file=/etc/systemd/system/fix-console.service
unit_link=/etc/systemd/system/multi-user.target.wants/fix-console.service

cleanup_self() {
    rm -f "$unit_link" "$unit_file" "$script_file" "$error_file"
    rmdir /usr/local/lib/debian-reinstall 2>/dev/null || true
}

fail() {
    message=$1
    printf '%s\n' "$message" >"$error_file"
    printf '%s\n' "$message" >&2
    exit 1
}

trap 'exit 1' HUP INT TERM

cmdline="$(cat /proc/cmdline)"
bad_ttys=
for tty in ttyS0 ttyAMA0; do
    case " $cmdline " in
        *" console=$tty"*)
            if [ ! -c "/dev/$tty" ] ||
                ! timeout 3 stty -g -F "/dev/$tty" >/dev/null 2>&1; then
                bad_ttys="$bad_ttys $tty"
            fi
            ;;
    esac
done

if [ -z "$bad_ttys" ]; then
    cleanup_self
    exit 0
fi

[ -f /etc/default/grub ] || fail 'Cannot repair an unusable serial console because /etc/default/grub is missing.'
tmp=/etc/default/grub.debian-reinstall.tmp
trap 'rm -f "$tmp"' EXIT
cp -p /etc/default/grub "$tmp"

for tty in $bad_ttys; do
    # Debian Installer writes its added console arguments to GRUB_CMDLINE_LINUX.
    # Remove only this exact serial-console token and retain every other option.
    sed -E -i \
        "s/(^|[[:space:]\"'])console=${tty}(,[^[:space:]\"']*)?/\\1/g" \
        "$tmp"
done
sed -E -i \
    '/^GRUB_CMDLINE_LINUX=/ { s/[[:space:]]+/ /g; s/="[[:space:]]*/="/; s/[[:space:]]+"$/"/; }' \
    "$tmp"

for tty in $bad_ttys; do
    if grep -Eq "(^|[[:space:]\"'])console=${tty}([,[:space:]\"']|$)" "$tmp"; then
        fail "Failed to remove the unusable $tty console from /etc/default/grub."
    fi
done
mv "$tmp" /etc/default/grub
trap - EXIT

if ! update-grub; then
    fail 'update-grub failed while removing an unusable serial console.'
fi
for tty in $bad_ttys; do
    if grep -Eq "(^|[[:space:]\"'])console=${tty}([,[:space:]\"']|$)" \
        /boot/grub/grub.cfg; then
        fail "The regenerated GRUB configuration still contains the unusable $tty console."
    fi
    timeout 20 systemctl stop "serial-getty@$tty.service" ||
        fail "Could not stop serial-getty@$tty.service; repair retained for diagnosis."
    state="$(systemctl show "serial-getty@$tty.service" -p ActiveState --value)" ||
        fail "Could not verify serial-getty@$tty.service stopped."
    [ "$state" = inactive ] || fail "serial-getty@$tty.service is still $state."
done

cleanup_self
__DEBIAN_REINSTALL_ASSET_fix_console_sh__
    cat >"$asset_root/fix-console.service" <<'__DEBIAN_REINSTALL_ASSET_fix_console_service__'
[Unit]
Description=Validate Debian serial consoles after reinstall
ConditionPathExists=/usr/local/lib/debian-reinstall/fix-console.sh
Wants=systemd-udev-settle.service
After=local-fs.target systemd-udev-settle.service
Before=serial-getty@ttyS0.service serial-getty@ttyAMA0.service
Before=network-pre.target networking.service network.target

[Service]
Type=oneshot
TimeoutStartSec=120
StandardOutput=journal+console
StandardError=journal+console
ExecStart=/usr/local/lib/debian-reinstall/fix-console.sh

[Install]
WantedBy=multi-user.target
__DEBIAN_REINSTALL_ASSET_fix_console_service__
    cat >"$asset_root/installer-early.sh" <<'__DEBIAN_REINSTALL_ASSET_installer_early_sh__'
#!/bin/sh

set -eu

di() {
    printf 'd-i %s\n' "$*" >/tmp/debian-reinstall-selection
    debconf-set-selections /tmp/debian-reinstall-selection
}

hostname="$(cat /configs/hostname)"
di "netcfg/get_hostname string $hostname"
di "netcfg/hostname string $hostname"
di 'passwd/root-login boolean true'
di 'passwd/make-user boolean false'

password_hash="$(cat /configs/password_hash)"
di "passwd/root-password-crypted password $password_hash"
__DEBIAN_REINSTALL_ASSET_installer_early_sh__
    cat >"$asset_root/installer-partman.sh" <<'__DEBIAN_REINSTALL_ASSET_installer_partman_sh__'
#!/bin/sh

set -eu

partman_stage=initialization
partman_ok=false
report_partman_failure() {
    rc=$?
    if ! $partman_ok; then
        message="installer-partman failed: stage=$partman_stage status=$rc"
        printf '%s\n' "$message" >/var/log/debian-reinstall-partman.error 2>/dev/null || true
        # /dev/console points only to the final console= argument. Mirror the
        # error to every candidate so a provider serial console retains it
        # even when tty0 is the primary console.
        for output_device in /dev/console /dev/ttyS0 /dev/ttyAMA0 /dev/tty0; do
            [ -c "$output_device" ] || continue
            printf '%s\n' "$message" >"$output_device" 2>/dev/null || true
        done
    fi
    return "$rc"
}
trap report_partman_failure EXIT
trap 'exit 1' HUP INT TERM

partman_stage=target-disk-identification
target_disk_error=/tmp/debian-reinstall-target-disk.error
if ! target_disk="$(/get-target-disk.sh 2>"$target_disk_error")"; then
    while IFS= read -r message; do
        for output_device in /dev/console /dev/ttyS0 /dev/ttyAMA0 /dev/tty0; do
            [ -c "$output_device" ] || continue
            printf '%s\n' "$message" >"$output_device" 2>/dev/null || true
        done
    done <"$target_disk_error"
    exit 1
fi
rm -f "$target_disk_error"
partman_stage=target-disk-selection
debconf-set partman-auto/disk "$target_disk"
debconf-set grub-installer/bootdev "$target_disk"

partman_stage=partition-recipe
if [ -d /sys/firmware/efi ]; then
    debconf-set partman-partitioning/default_label gpt
    recipe="$(debconf-get partman-auto/expert_recipe_efi 2>/dev/null || true)"
else
    recipe="$(debconf-get partman-auto/expert_recipe_bios 2>/dev/null || true)"
fi
[ -n "$recipe" ] || {
    printf '%s\n' 'The preseeded partition recipe is missing.' >/dev/console 2>/dev/null || true
    exit 1
}
debconf-set partman-auto/expert_recipe "$recipe"

partman_stage=installed-kernel-options
console="$(cat /configs/console_candidates)"
# Recheck against the installer kernel, not just the merchant's old kernel.
usable_console=
for token in $console; do
    case "$token" in
        console=ttyS0*|console=ttyAMA0*)
            tty=${token#console=}; tty=${tty%%,*}
            if [ -c "/dev/$tty" ] && ! timeout 3 stty -g -F "/dev/$tty" >/dev/null 2>&1; then
                continue
            fi
            ;;
    esac
    usable_console="${usable_console:+$usable_console }$token"
done
console=$usable_console
[ -z "$console" ] || debconf-set debian-installer/add-kernel-opts "$console"

partman_stage=installed-kernel-selection
kernel_image="$(cat /configs/kernel_image)"
debconf-set base-installer/kernel/image "$kernel_image"
disk_name="${target_disk#/dev/}"
eths=""
for path in /dev/netconf/*; do
    [ -d "$path" ] && eths="$eths $(basename "$path")"
done
partman_stage=cloud-kernel-compatibility
# Interface names are intentionally passed as separate arguments.
# shellcheck disable=SC2086
if ! /can-use-cloud-kernel.sh "$disk_name" $eths; then
    generic="$(printf '%s' "$kernel_image" | sed 's/-cloud//')"
    debconf-set base-installer/kernel/image "$generic"
fi

# Validate recipe and kernel selection before touching existing filesystems.
# An equal-size ESP may otherwise be reused by partman without mkfs. Invalidate
# at most the first 1 MiB of each confirmed old partition; never zero the disk.
partman_stage=invalidate-old-filesystems
target_disk_name="${target_disk#/dev/}"
for partition_path in "/sys/block/$target_disk_name"/*; do
    [ -f "$partition_path/partition" ] || continue
    partition_name="$(basename "$partition_path")"
    partition_sectors="$(cat "$partition_path/size")"
    wipe_sectors=$partition_sectors
    [ "$wipe_sectors" -le 2048 ] || wipe_sectors=2048
    [ "$wipe_sectors" -gt 0 ] || continue
    dd if=/dev/zero of="/dev/$partition_name" bs=512 count="$wipe_sectors" 2>/dev/null
done
sync

# Wrap bootstrap-base only when the installer needs temporary swap or when an
# EFI System Partition must be cleaned. Debian Installer can reuse an ESP
# without formatting it when the new partition has the same size, so relying
# on method{ efi } format{ } alone can retain files from the previous system.
mem_mb="$(awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo)"
partman_stage=bootstrap-wrapper
need_bootstrap_wrapper=false
[ "$mem_mb" -lt 768 ] && need_bootstrap_wrapper=true
[ -d /sys/firmware/efi ] && need_bootstrap_wrapper=true
if $need_bootstrap_wrapper; then
    postinst=/var/lib/dpkg/info/bootstrap-base.postinst
    if [ -f "$postinst" ] && [ ! -f "$postinst.debian-reinstall.orig" ]; then
        cp "$postinst" "$postinst.debian-reinstall.orig"
        cat >"$postinst" <<EOF
#!/bin/sh
set -eu

if [ -d /sys/firmware/efi ]; then
    esp=/target/boot/efi
    if ! awk '\$2 == "/target/boot/efi" && (\$3 == "vfat" || \$3 == "fat") { found=1 } END { exit found ? 0 : 1 }' /proc/mounts; then
        echo "EFI System Partition is not mounted at \$esp; refusing an installation that could retain old EFI files." >&2
        exit 1
    fi
    find "\$esp" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} \;
    if find "\$esp" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
        echo "Could not completely clean the EFI System Partition at \$esp." >&2
        exit 1
    fi
fi

if [ $mem_mb -lt 768 ]; then
    swapfile=/target/.debian-installer-swap
    need_mb=$((768 - mem_mb))
    if command -v chattr >/dev/null 2>&1; then
        touch "\$swapfile"
        chattr +C "\$swapfile" 2>/dev/null || true
    fi
    if ! fallocate -l "\${need_mb}M" "\$swapfile" 2>/dev/null; then
        dd if=/dev/zero of="\$swapfile" bs=1M count="\$need_mb"
    fi
    chmod 0600 "\$swapfile"
    if ! mkswap "\$swapfile" || ! swapon "\$swapfile"; then
        rm -f "\$swapfile"
        echo "Could not activate the temporary low-memory installer swap." >&2
        exit 1
    fi
fi

"$postinst.debian-reinstall.orig" "\$@"
EOF
        chmod 0755 "$postinst"
        if [ "$mem_mb" -lt 768 ]; then
            mkdir -p /usr/lib/finish-install.d
            cat >/usr/lib/finish-install.d/95-debian-reinstall-swap <<'EOF'
#!/bin/sh
set -e
swapoff /target/.debian-installer-swap
rm -f /target/.debian-installer-swap
EOF
            chmod 0755 /usr/lib/finish-install.d/95-debian-reinstall-swap
        fi
    fi
fi

cat >/bin/os-prober <<'EOF'
#!/bin/sh
exit 0
EOF
chmod 0755 /bin/os-prober

partman_stage=complete
partman_ok=true
rm -f /var/log/debian-reinstall-partman.error
__DEBIAN_REINSTALL_ASSET_installer_partman_sh__
    cat >"$asset_root/installer-block-packages.sh" <<'__DEBIAN_REINSTALL_ASSET_installer_block_packages_sh__'
#!/bin/sh

set -eu

# This hook runs immediately after the Debian base system exists and before
# pkgsel, hardware helper hooks, or grub-installer can add optional packages.
# A temporary negative pin prevents both explicit apt-install calls and
# Recommends from selecting packages outside the requested base + SSH target.
mkdir -p /target/etc/apt/preferences.d
cat >/target/etc/apt/preferences.d/99-debian-reinstall-block-extras <<'EOF'
Package: qemu-guest-agent popularity-contest installation-report os-prober discover discover-data laptop-detect mouseemu xauth cloud-init cloud-initramfs-growroot walinuxagent waagent google-guest-agent google-compute-engine-oslogin amazon-ssm-agent oracle-cloud-agent open-vm-tools xe-guest-utilities aliyun-assist aliyun-service tat-agent
Pin: version *
Pin-Priority: -1
EOF
__DEBIAN_REINSTALL_ASSET_installer_block_packages_sh__
    cat >"$asset_root/installer-late.sh" <<'__DEBIAN_REINSTALL_ASSET_installer_late_sh__'
#!/bin/sh

set -eu

late_stage=initialization
late_status=1
# Invoked indirectly by the EXIT trap below.
# shellcheck disable=SC2317,SC2329
record_late_failure() {
    rc=$?
    if [ "$late_status" != 0 ]; then
        printf 'installer-late failed: stage=%s status=%s\n' "$late_stage" "$rc" \
            >/target/var/log/debian-reinstall-late.error 2>/dev/null || true
        sync /target/var/log/debian-reinstall-late.error 2>/dev/null || sync
    fi
    return "$rc"
}
trap record_late_failure EXIT
trap 'exit 1' HUP INT TERM

ssh_port="$(cat /configs/ssh_port)"
hostname="$(cat /configs/hostname)"
release="$(cat /configs/release)"
case "$release" in
    13)
        codename=trixie
        archive_keyring=/usr/share/keyrings/debian-archive-keyring.pgp
        ;;
    *) exit 1 ;;
esac

late_stage=apt-sources
# Keep only Debian main. Debian 13 recommends deb822 sources with an explicit
# archive keyring. Some d-i releases
# add non-free-firmware despite the corresponding preseed setting being false,
# so replace every generated source rather than editing it in place.
rm -f /target/etc/apt/sources.list
mkdir -p /target/etc/apt/sources.list.d
for source_file in /target/etc/apt/sources.list.d/*; do
    [ -e "$source_file" ] || break
    rm -f "$source_file"
done
cat >/target/etc/apt/sources.list.d/debian.sources <<EOF
Types: deb
URIs: https://deb.debian.org/debian
Suites: $codename $codename-updates
Components: main
Signed-By: $archive_keyring

Types: deb
URIs: https://security.debian.org/debian-security
Suites: $codename-security
Components: main
Signed-By: $archive_keyring
EOF

# The installed system uses deterministic public resolvers.  DHCP and RA may
# still provide addresses and routes, but their DNS values must not replace
# this file on later lease renewals.
late_stage=dns
has_ipv4=false
has_ipv6=false
for netconf in /dev/netconf/*; do
    [ -d "$netconf" ] || continue
    [ "$(cat "$netconf/ipv4_configured" 2>/dev/null || true)" = 1 ] && has_ipv4=true
    [ "$(cat "$netconf/ipv6_configured" 2>/dev/null || true)" = 1 ] && has_ipv6=true
done
$has_ipv4 || $has_ipv6 || exit 1

rm -f /target/etc/resolv.conf
: >/target/etc/resolv.conf
if $has_ipv4; then
    printf '%s\n' \
        'nameserver 8.8.8.8' \
        'nameserver 1.1.1.1' \
        >>/target/etc/resolv.conf
fi
if $has_ipv6; then
    printf '%s\n' \
        'nameserver 2001:4860:4860::8888' \
        'nameserver 2606:4700:4700::1111' \
        >>/target/etc/resolv.conf
fi
chmod 0644 /target/etc/resolv.conf
if [ -d /target/etc/dhcp ]; then
    cat >>/target/etc/dhcp/dhclient.conf <<'EOF'

# Fixed by debian-reinstall-clean: keep the local hostname and ignore DNS
# supplied by DHCPv4/DHCPv6.
send host-name "debian";
supersede host-name "debian";
supersede domain-name-servers 8.8.8.8, 1.1.1.1;
supersede dhcp6.name-servers 2001:4860:4860::8888, 2606:4700:4700::1111;
EOF
fi
if [ -f /target/etc/dhcpcd.conf ]; then
    printf '\n# Fixed by debian-reinstall-clean\nnohook resolv.conf, hostname\n' \
        >>/target/etc/dhcpcd.conf
fi

late_stage=time-synchronization
# Install via pkgsel, enable offline, and retain Debian's packaged defaults.
# Do not start a target service in d-i or block unattended installation on NTP.
in-target systemctl enable systemd-timesyncd.service
in-target systemctl is-enabled --quiet systemd-timesyncd.service

late_stage=network-repair-service
mkdir -p /target/usr/local/lib/debian-reinstall /target/etc/systemd/system
cp /fix-eth-name.sh /target/usr/local/lib/debian-reinstall/fix-eth-name.sh
cp /fix-eth-name.service /target/etc/systemd/system/fix-eth-name.service
cp /fix-console.sh /target/usr/local/lib/debian-reinstall/fix-console.sh
cp /fix-console.service /target/etc/systemd/system/fix-console.service
chmod 0755 /target/usr/local/lib/debian-reinstall/fix-eth-name.sh
chmod 0755 /target/usr/local/lib/debian-reinstall/fix-console.sh
chmod 0644 \
    /target/etc/systemd/system/fix-eth-name.service \
    /target/etc/systemd/system/fix-console.service
in-target systemctl enable fix-eth-name.service
in-target systemctl enable fix-console.service
in-target systemctl enable ssh.service

late_stage=ssh-generator-policy
# Standard systemd administrator mask: keep the official binary/package intact,
# but do not create AF_VSOCK/AF_UNIX or credential-requested SSH listeners.
# This is persistent target policy, not a temporary installer artifact.
generator_dir=/target/etc/systemd/system-generators
mkdir -p "$generator_dir"
chmod 0755 "$generator_dir"
ln -sfn /dev/null "$generator_dir/systemd-ssh-generator"
[ "$(readlink "$generator_dir/systemd-ssh-generator")" = /dev/null ]

late_stage=ssh-configuration
mkdir -p /target/etc/ssh/sshd_config.d
chmod 0755 /target/etc/ssh/sshd_config.d
cat >/target/etc/ssh/sshd_config.d/00-debian-reinstall.conf <<EOF
Port $ssh_port
PermitRootLogin yes
PubkeyAuthentication yes
PasswordAuthentication yes
KbdInteractiveAuthentication no
PermitEmptyPasswords no
UsePAM yes
AllowUsers root
LoginGraceTime 30
MaxAuthTries 3
MaxStartups 10:30:60
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding no
AllowStreamLocalForwarding no
DisableForwarding yes
GatewayPorts no
PermitTunnel no
PermitUserEnvironment no
EOF
chmod 0644 /target/etc/ssh/sshd_config.d/00-debian-reinstall.conf

# The target filesystem is new, so no old host key can normally exist. Remove
# and regenerate anyway so the invariant is explicit and testable.
late_stage=ssh-runtime
rm -f /target/etc/ssh/ssh_host_*
in-target mkdir -p /run/sshd
late_stage=ssh-host-keys
in-target ssh-keygen -A
late_stage=ssh-syntax-validation
in-target /usr/sbin/sshd -t
late_stage=ssh-effective-validation
# Do not capture this through d-i's in-target/log-output wrapper: older d-i
# releases do not reliably pass a command's stdout back to command
# substitution.  Validate the chrooted daemon directly and retain a precise
# failure stage for unattended diagnostics.
sshd_effective_file=/target/run/debian-reinstall-sshd-effective
# Debian 12's in-target may temporarily bind the installer's /run over the
# target /run.  Recreate the privilege-separation directory after leaving the
# wrapper so the direct chroot sees it as well.
mkdir -p /target/run/sshd
chroot /target /usr/sbin/sshd -T >"$sshd_effective_file"
validate_sshd_setting() {
    late_stage="ssh-effective-validation-$1"
    grep -Fqx "$2" "$sshd_effective_file"
}
validate_sshd_setting port "port $ssh_port"
validate_sshd_setting root-login 'permitrootlogin yes'
validate_sshd_setting password 'passwordauthentication yes'
validate_sshd_setting keyboard 'kbdinteractiveauthentication no'
validate_sshd_setting empty-password 'permitemptypasswords no'
validate_sshd_setting x11 'x11forwarding no'
validate_sshd_setting agent-forward 'allowagentforwarding no'
validate_sshd_setting tcp-forward 'allowtcpforwarding no'
validate_sshd_setting streamlocal-forward 'allowstreamlocalforwarding no'
validate_sshd_setting all-forwarding 'disableforwarding yes'
rm -f "$sshd_effective_file"

# Make hostname deterministic even when the provider's DHCP server sends
# option 12. cloud-init and provider agents are not part of the selected
# package set.
late_stage=hostname
printf '%s\n' "$hostname" >/target/etc/hostname
if grep -q '^127\.0\.1\.1[[:space:]]' /target/etc/hosts 2>/dev/null; then
    sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t$hostname/" /target/etc/hosts
else
    printf '127.0.1.1\t%s\n' "$hostname" >>/target/etc/hosts
fi

# netcfg normally copies this itself; the explicit copy covers custom static,
# /32, /128 and split IPv4/IPv6-interface cases.
late_stage=network-configuration
cp /etc/network/interfaces /target/etc/network/interfaces
chmod 0600 /target/etc/network/interfaces

# Do not carry the installer's transient DHCP client state into the first boot.
# In particular, dhcpcd can report a truncated copied lease on Debian 13 even
# though it immediately recovers. The installed client should negotiate a
# fresh lease against the provider network instead.
late_stage=network-lease-cleanup
rm -f \
    /target/var/lib/dhcpcd/*.lease \
    /target/var/lib/dhcpcd/*.lease6 \
    /target/var/lib/dhcp/dhclient*.leases \
    /target/var/lib/dhcp/dhclient*.leases~

# Some providers boot an external GRUB that looks for /boot/grub2/grub.cfg.
# Preserve only the directory alias detected on the source system; no old GRUB
# binary or configuration is copied into the new installation.
late_stage=provider-grub-directory-compatibility
if [ "$(cat /configs/link_grub_dir 2>/dev/null || echo 0)" = 1 ]; then
    if [ -e /target/boot/grub2 ] || [ -L /target/boot/grub2 ]; then
        [ /target/boot/grub2 -ef /target/boot/grub ] || exit 1
    else
        ln -s grub /target/boot/grub2
    fi
fi

# finish-install's official 94save-logs hook otherwise copies the installer's
# cdebconf database (including installation answers) into /var/log/installer.
# Disable the copy after all installer components have been unpacked, so anna
# cannot overwrite an earlier initrd-time patch. Normal target APT/dpkg logs
# remain available; failures before successful completion remain diagnosable.
late_stage=installer-archive-policy
printf '#!/bin/sh\nexit 0\n' >/usr/lib/finish-install.d/94save-logs
chmod 0755 /usr/lib/finish-install.d/94save-logs

late_stage=complete
late_status=0
rm -f /target/var/log/debian-reinstall-late.error
rm -f /target/var/log/debian-reinstall-partman.error
rm -f /target/var/log/debian-reinstall-network-repair.error
rm -f /target/var/log/debian-reinstall-console-repair.error
exit 0
__DEBIAN_REINSTALL_ASSET_installer_late_sh__
    cat >"$asset_root/installer-finish.sh" <<'__DEBIAN_REINSTALL_ASSET_installer_finish_sh__'
#!/bin/sh

set -eu

# These optional packages are blocked before apt can select them. Keep a final
# defensive check because grub-installer runs late. Unexpected packages are
# an installation failure, never a silently repaired success.
error_file=/target/var/log/debian-reinstall-packages.error
package_failure() {
    printf '%s\n' "$1" >>"$error_file"
    logger -t debian-reinstall-clean "$1" || true
    exit 1
}

# Query once, directly: in-target logs stdout unless --pass-stdout is used.
# Never interpret an unreadable/empty/partial inventory as "nothing installed".
# The format must be passed literally to the target's official dpkg-query.
# shellcheck disable=SC2016
if ! inventory="$(chroot /target /usr/bin/dpkg-query -W \
    -f='${Package}\t${db:Status-Status}\n' 2>"$error_file")"; then
    package_failure 'Could not read the target package inventory.'
fi
if ! printf '%s\n' "$inventory" | awk -F '\t' '
    NF!=2 || $1 !~ /^[a-z0-9][a-z0-9+.-]+$/ || seen[$1]++ ||
    $2 !~ /^(not-installed|config-files|half-installed|unpacked|half-configured|triggers-awaited|triggers-pending|installed)$/ {bad=1}
    END {exit (bad || NR<4) ? 1 : 0}
'; then
    package_failure 'The target package inventory is empty or malformed.'
fi
tab="$(printf '\t')"
for required in base-files dpkg libc6 libc-bin openssh-server ca-certificates systemd-timesyncd; do
    printf '%s\n' "$inventory" | grep -Fqx "${required}${tab}installed" ||
        package_failure "Required installed package missing from inventory: $required"
done

unexpected_packages=
for package in \
    qemu-guest-agent popularity-contest installation-report os-prober \
    discover discover-data laptop-detect mouseemu xauth \
    cloud-init cloud-initramfs-growroot walinuxagent waagent \
    google-guest-agent google-compute-engine-oslogin amazon-ssm-agent \
    oracle-cloud-agent open-vm-tools xe-guest-utilities \
    aliyun-assist aliyun-service tat-agent; do
    status="$(printf '%s\n' "$inventory" | awk -F '\t' -v wanted="$package" '$1==wanted {print $2}')"
    case "$status" in
        ''|not-installed) : ;;
        *) unexpected_packages="$unexpected_packages $package($status)" ;;
    esac
done
if [ -n "$unexpected_packages" ]; then
    package_failure "Unexpected optional packages:$unexpected_packages"
fi
rm -f "$error_file"
rm -f /target/etc/apt/preferences.d/99-debian-reinstall-block-extras
in-target apt-get clean
# Remove only known installer archives if an earlier component created them.
# Do not erase the new system's package-manager logs or normal journal.
rm -rf /target/var/log/installer
rm -f /target/var/log/bootstrap.log
__DEBIAN_REINSTALL_ASSET_installer_finish_sh__
    cat >"$asset_root/preseed.cfg" <<'__DEBIAN_REINSTALL_ASSET_preseed_cfg__'
d-i debian-installer/locale string en_US.UTF-8
d-i keyboard-configuration/xkb-keymap select us
d-i netcfg/get_hostname string debian
d-i netcfg/get_domain string
d-i netcfg/hostname string debian

d-i mirror/country string manual
d-i mirror/http/proxy string

d-i passwd/root-login boolean true
d-i passwd/make-user boolean false
d-i clock-setup/utc boolean true
d-i time/zone string UTC
d-i clock-setup/ntp boolean true

d-i partman-auto/method string regular
d-i partman-lvm/device_remove_lvm boolean true
d-i partman-md/device_remove_md boolean true
d-i partman-partitioning/confirm_write_new_label boolean true
d-i partman/choose_partition select finish
d-i partman/confirm boolean true
d-i partman/confirm_nooverwrite boolean true
d-i partman-efi/non_efi_system boolean true
d-i partman-basicfilesystems/no_swap boolean false

d-i partman-auto/expert_recipe_efi string efi :: \
    538 1 538 free \
        $iflabel{ gpt } method{ efi } format{ } . \
    1 1 -1 __FILESYSTEM__ \
        method{ format } format{ } use_filesystem{ } filesystem{ __FILESYSTEM__ } mountpoint{ / } .

d-i partman-auto/expert_recipe_bios string bios :: \
    1 1 1 free \
        $iflabel{ gpt } method{ biosgrub } . \
    1 1 -1 __FILESYSTEM__ \
        method{ format } format{ } use_filesystem{ } filesystem{ __FILESYSTEM__ } mountpoint{ / } .

d-i apt-setup/non-free boolean false
d-i apt-setup/non-free-firmware boolean false
d-i apt-setup/contrib boolean false
d-i apt-setup/enable-source-repositories boolean false
d-i apt-setup/security_host string deb.debian.org
d-i apt-setup/services-select multiselect security, updates
# Optional update services must not turn a temporary mirror outage into an
# interactive stop. Their official HTTPS entries are rebuilt by the late hook.
d-i apt-setup/service-failed seen true
d-i pkgsel/upgrade select safe-upgrade
d-i pkgsel/install-language-support boolean false
d-i pkgsel/run_tasksel boolean false
d-i pkgsel/include string openssh-server ca-certificates systemd-timesyncd
d-i popularity-contest/participate boolean false
d-i grub-installer/force-efi-extra-removable boolean true
d-i finish-install/reboot_in_progress note

d-i preseed/early_command string /installer-early.sh
d-i partman/early_command string /installer-partman.sh
d-i preseed/late_command string /installer-late.sh
__DEBIAN_REINSTALL_ASSET_preseed_cfg__
    chmod 0755 \
        "$asset_root/initrd-network.sh" \
        "$asset_root/debian-network-render.sh" \
        "$asset_root/debian-netcfg.sh" \
        "$asset_root/get-target-disk.sh" \
        "$asset_root/can-use-cloud-kernel.sh" \
        "$asset_root/fix-eth-name.sh" \
        "$asset_root/fix-console.sh" \
        "$asset_root/installer-early.sh" \
        "$asset_root/installer-partman.sh" \
        "$asset_root/installer-block-packages.sh" \
        "$asset_root/installer-late.sh" \
        "$asset_root/installer-finish.sh"
    chmod 0644 \
        "$asset_root/fix-eth-name.service" \
        "$asset_root/fix-console.service" \
        "$asset_root/preseed.cfg"
}

extract_package_to() {
    local type=$1 package=$2 destination=$3 pkg_file
    pkg_file="$workdir/${package}.pkg"
    download_package "$type" "$package" "$pkg_file"
    rm -rf -- "$destination"
    mkdir -p "$destination"
    dpkg-deb -x "$pkg_file" "$destination"
}

merge_extracted_tree() {
    local source=$1 destination=$2 item name resolved
    while IFS= read -r -d '' item; do
        name=${item##*/}
        if [ -d "$item" ] && [ ! -L "$item" ] && [ -L "$destination/$name" ]; then
            resolved="$(readlink -f -- "$destination/$name")"
            case "$resolved" in
                "$destination"/*) ;;
                *) die "refusing extracted-package symlink outside installer initrd: $name -> $resolved" ;;
            esac
            cp -a "$item"/. "$resolved"/
        else
            cp -a "$item" "$destination"/
        fi
    done < <(find "$source" -mindepth 1 -maxdepth 1 -print0)
}

unpack_initrd() {
    initrd_dir="$workdir/initrd"
    mkdir -p "$initrd_dir"
    log "Unpacking Debian Installer initrd"
    (
        cd "$initrd_dir"
        gzip -dc "$workdir/initrd.gz" | cpio --quiet -idmu
    )
    kver="$(find "$initrd_dir/lib/modules" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | head -n 1)"
    [ -n "$kver" ] || die "could not determine the installer kernel version"
}

install_verified_udebs() {
    local root
    log "Adding verified installer disk-identification tools"
    root="$workdir/fdisk-root"
    extract_package_to udeb fdisk-udeb "$root"
    merge_extracted_tree "$root" "$initrd_dir"
    # Debian's minimal busybox-udeb does not provide timeout. Import ONLY the
    # official utility, not the whole coreutils tree, through the same signed
    # Packages hash chain. Its actual loader/dependencies are checked below.
    log "Adding the verified Debian timeout utility for bounded installer probes"
    root="$workdir/timeout-root"
    extract_package_to deb coreutils "$root"
    [ -x "$root/usr/bin/timeout" ] || die "official coreutils package has no timeout executable"
    install -m 0755 "$root/usr/bin/timeout" "$initrd_dir/bin/timeout"
}

drivers_for_path() {
    local path
    path="$(readlink -f "$1")"
    while [ "$path" != / ]; do
        if [ -L "$path/driver/module" ]; then
            basename "$(readlink -f "$path/driver/module")"
        elif [ -L "$path/driver" ]; then
            basename "$(readlink -f "$path/driver")"
        fi
        path="$(dirname "$path")"
    done | sort -u
}

copy_module_udeb() {
    local package=$1 root="$workdir/$1-root"
    extract_package_to udeb "$package" "$root"
    [ -d "$root/lib/modules/$kver" ] || [ -d "$root/usr/lib/modules/$kver" ] ||
        die "$package did not contain modules for $kver"
    merge_extracted_tree "$root" "$initrd_dir"
}

copy_module_udeb_if_available() {
    local package=$1
    if [ -n "$(package_fields "$package_index_udeb" "$package")" ]; then
        copy_module_udeb "$package"
    else
        warn "installer module package is not published for $arch and will be skipped: $package"
    fi
}

configure_memory_mode() {
    local mem_mb
    mem_mb="$(awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo)"
    case "$low_memory" in
        force)
            low_memory_active=true
            ;;
        off)
            low_memory_active=false
            ;;
        auto)
            if [ "$mem_mb" -le 256 ]; then low_memory_active=true; else low_memory_active=false; fi
            ;;
    esac
    log "Host memory: ${mem_mb} MiB; Debian Installer selects lowmem automatically; storage trimming: $low_memory_active"
}

add_low_memory_storage_modules() {
    $low_memory_active || return 0
    local driver need_scsi=false need_sata=false need_pata=false known=false
    local drivers
    drivers="$(drivers_for_path "/sys/block/${target_disk##*/}")"
    log "Current target-disk driver chain: ${drivers//$'\n'/ }"
    for driver in $drivers; do
        case "$driver" in
            nvme|nvme_core|virtio_blk|virtio_scsi|xen_blkfront|xen_scsifront|hv_storvsc|vmw_pvscsi|megaraid_sas|mpt*|qla*|hpsa|aacraid|smartpqi|3w_*|isci)
                need_scsi=true; known=true ;;
            ahci|libahci|ata_piix|sata_*)
                need_sata=true; known=true ;;
            pata_*)
                need_pata=true; known=true ;;
            ata_generic|sd_mod|scsi_mod|virtio_pci|pcieport) : ;;
        esac
    done
    if ! $known; then
        warn "unknown storage driver chain; retaining all major storage module sets"
        need_scsi=true; need_sata=true; need_pata=true
    fi
    $need_scsi && copy_module_udeb_if_available "scsi-modules-$kver-di"
    $need_sata && copy_module_udeb_if_available "sata-modules-$kver-di"
    $need_pata && copy_module_udeb_if_available "pata-modules-$kver-di"
    depmod -b "$initrd_dir" "$kver"
}

add_hyperv_pci_module_if_needed() {
    [ -d /sys/module/pci_hyperv ] || return 0
    if find "$initrd_dir/lib/modules/$kver" -name 'pci-hyperv.ko*' -print -quit | grep -q . ||
        grep -Fq '/pci-hyperv.ko' "$initrd_dir/lib/modules/$kver/modules.builtin" 2>/dev/null; then
        return 0
    fi

    local root="$workdir/linux-image-root" base file rel copied=false
    log "Adding verified pci_hyperv modules required by this Hyper-V/Azure guest"
    extract_package_to deb "linux-image-$kver" "$root"
    if [ -d "$root/usr/lib/modules/$kver" ]; then
        base="$root/usr/lib/modules/$kver"
    else
        base="$root/lib/modules/$kver"
    fi
    while IFS= read -r file; do
        [ -n "$file" ] || continue
        rel=${file#"$base"/}
        mkdir -p "$initrd_dir/lib/modules/$kver/$(dirname "$rel")"
        cp -a "$file" "$initrd_dir/lib/modules/$kver/$rel"
        copied=true
    done < <(find "$base" -type f \( -name 'pci-hyperv.ko*' -o -name 'pci-hyperv-intf.ko*' \))
    $copied || die "linux-image-$kver did not contain expected pci_hyperv modules"
    depmod -b "$initrd_dir" "$kver"
}

detect_console_cmdline() {
    local candidates tty result=''

    if [ "$arch" = arm64 ]; then
        candidates='ttyS0 ttyAMA0 tty0'
    else
        candidates='ttyS0 tty0'
    fi

    # Some VPSes expose a character device for a disconnected or unusable
    # virtual console.  Passing such a device to the installed kernel makes
    # systemd continuously restart its getty.  Keep consoles that work in the
    # current guest; also keep absent candidates because the installer/new
    # Debian kernel can expose a console that the old vendor kernel omitted.
    for tty in $candidates; do
        if { [ -c "/dev/$tty" ] && timeout 3 stty -g -F "/dev/$tty" >/dev/null 2>&1; } ||
            [ ! -c "/dev/$tty" ]; then
            if [ -n "$result" ]; then
                result="$result "
            fi
            case "$tty" in
                ttyS0|ttyAMA0) result="${result}console=$tty,115200n8" ;;
                *) result="${result}console=$tty" ;;
            esac
        else
            log "Ignoring unusable virtual console /dev/$tty"
        fi
    done

    printf '%s\n' "$result"
}

write_runtime_configs() {
    local console_cmdline

    mkdir -p "$initrd_dir/configs/disk" "$initrd_dir/configs/net"
    printf '%s\n' "$release" >"$initrd_dir/configs/release"
    printf '%s\n' "$ssh_port" >"$initrd_dir/configs/ssh_port"
    printf '%s\n' "$new_hostname" >"$initrd_dir/configs/hostname"
    printf '%s\n' "$kernel_image" >"$initrd_dir/configs/kernel_image"
    $linked_grub_dir && printf '1\n' >"$initrd_dir/configs/link_grub_dir" ||
        printf '0\n' >"$initrd_dir/configs/link_grub_dir"
    printf '%s\n' "$disk_ptuuid" >"$initrd_dir/configs/disk/ptuuid"
    printf '%s\n' "$disk_anchor_partuuid" >"$initrd_dir/configs/disk/anchor_partuuid"
    printf '%s\n' "$disk_size" >"$initrd_dir/configs/disk/size_bytes"
    console_cmdline="$(detect_console_cmdline)"
    printf '%s\n' "$console_cmdline" >"$initrd_dir/configs/console"
    # The installer kernel must independently probe every supported candidate,
    # including devices that the vendor kernel incorrectly marked unusable.
    if [ "$arch" = arm64 ]; then
        printf 'console=ttyS0,115200n8 console=ttyAMA0,115200n8 console=tty0\n'
    else
        printf 'console=ttyS0,115200n8 console=tty0\n'
    fi >"$initrd_dir/configs/console_candidates"
    printf '%s\n' "$password_hash" >"$initrd_dir/configs/password_hash"
    unset password_hash
    chmod -R go-rwx "$initrd_dir/configs"

    sed -i "s/__FILESYSTEM__/$filesystem/g" "$initrd_dir/preseed.cfg"
    cat >>"$initrd_dir/preseed.cfg" <<EOF
d-i mirror/http/hostname string $mirror_host
d-i mirror/http/directory string $mirror_directory
d-i mirror/suite string $codename
EOF
}

write_priority_filter() {
    local disabled storage_disabled
    disabled='\
depthcharge-tools-installer
kickseed-common
nobootloader
partman-cros
partman-iscsi
partman-jfs
partman-md
partman-xfs
rescue-check
wpasupplicant-udeb
lilo-installer
systemd-boot-installer
nic-pcmcia-modules-KVER-di
nic-usb-modules-KVER-di
nic-wireless-modules-KVER-di
nic-shared-modules-KVER-di
pcmcia-modules-KVER-di
pcmcia-storage-modules-KVER-di
cdrom-core-modules-KVER-di
firewire-core-modules-KVER-di
usb-storage-modules-KVER-di
isofs-modules-KVER-di
jfs-modules-KVER-di
xfs-modules-KVER-di
loop-modules-KVER-di'
    if [ "$filesystem" != btrfs ]; then
        disabled="$disabled
partman-btrfs"
    fi
    if $low_memory_active; then
        storage_disabled="pata-modules-KVER-di
sata-modules-KVER-di
scsi-modules-KVER-di"
        disabled="$disabled
$storage_disabled"
    fi
    disabled=${disabled//KVER/$kver}

    cat >"$initrd_dir/change-priority.inc" <<'EOF'
change_priority() {
    package=
    while IFS= read -r line; do
        case "$line" in
            'Package: '*) package=${line#Package: } ;;
            'Priority: '*)
                for item in $disabled_list; do
                    if [ "$package" = "$item" ] && [ "$line" = 'Priority: standard' ]; then
                        line='Priority: optional'
                        break
                    fi
                done
                case "$package" in ata-modules-*-di) line='Priority: standard' ;; esac
                ;;
        esac
        printf '%s\n' "$line"
    done
}
EOF
    {
        printf "disabled_list='\n%s\n'\n" "$disabled"
        cat "$initrd_dir/change-priority.inc"
    } >"$initrd_dir/change-priority.inc.new"
    mv "$initrd_dir/change-priority.inc.new" "$initrd_dir/change-priority.inc"
}

patch_installer_initrd() {
    local postinst="$initrd_dir/var/lib/dpkg/info/netcfg.postinst"
    local retriever="$initrd_dir/usr/lib/debian-installer/retriever/net-retriever"
    local hook
    [ -f "$postinst" ] || die "unexpected installer initrd: netcfg.postinst missing"
    [ -f "$retriever" ] || die "unexpected installer initrd: net-retriever missing"

    log "Applying Debian-only installer patches"
    cat >"$postinst" <<'EOF'
#!/bin/sh
set -e
. /usr/share/debconf/confmodule
db_progress START 0 4 debian-installer/netcfg/title
db_progress INFO netcfg/dhcp_progress
/debian-netcfg.sh
db_progress STEP 3
db_progress STOP
EOF
    chmod 0755 "$postinst"

    if [ -f "$initrd_dir/etc/udhcpc/default.script" ]; then
        sed -Ei 's/&&( onlink=)/||\1/' "$initrd_dir/etc/udhcpc/default.script"
    fi

    write_priority_filter
    # The literal $1 belongs to the installer's shell script, not this one.
    # shellcheck disable=SC2016
    grep -Fq '>> "$1"' "$retriever" || die "unexpected net-retriever output code"
    # shellcheck disable=SC2016
    sed -i 's/>> "$1"/| change_priority >> "$1"/' "$retriever"
    sed -i '1a . /change-priority.inc' "$retriever"

    if [ -f "$initrd_dir/lib/debian-installer/menu" ]; then
        sed -i '1a export DEBCONF_DROP_TRANSLATIONS=1' "$initrd_dir/lib/debian-installer/menu"
    fi

    # Debian Installer normally adds hardware/reporting helpers even when no
    # task is selected.  They are unnecessary on a minimal server; notably,
    # qemu-guest-agent would create a privileged host-to-guest control channel.
    for hook in \
        usr/lib/finish-install.d/08hw-detect \
        usr/lib/post-base-installer.d/60install-mouseemu \
        usr/lib/pre-pkgsel.d/20install-hwpackages \
        usr/lib/pre-pkgsel.d/50save-logs; do
        if [ -f "$initrd_dir/$hook" ]; then
            printf '#!/bin/sh\nexit 0\n' >"$initrd_dir/$hook"
            chmod 0755 "$initrd_dir/$hook"
        fi
    done
    install -m 0755 "$initrd_dir/installer-block-packages.sh" \
        "$initrd_dir/usr/lib/post-base-installer.d/10-debian-reinstall-block-extras"
    install -m 0755 "$initrd_dir/installer-finish.sh" \
        "$initrd_dir/usr/lib/finish-install.d/95-debian-reinstall-cleanup"
}

verify_initrd_contents() {
    local required timeout_rc=0
    for required in \
        preseed.cfg initrd-network.sh debian-network-render.sh debian-netcfg.sh \
        get-target-disk.sh can-use-cloud-kernel.sh installer-early.sh \
        installer-partman.sh installer-block-packages.sh installer-late.sh \
        installer-finish.sh \
        fix-eth-name.sh fix-eth-name.service fix-console.sh fix-console.service; do
        [ -s "$initrd_dir/$required" ] || die "missing initrd asset: $required"
    done
    [ ! -e "$initrd_dir/usr/sbin/sshd" ] ||
        die "installer SSH is outside the reduced unattended-install scope"
    [ -x "$initrd_dir/bin/timeout" ] || die "installer timeout utility is missing"
    chroot "$initrd_dir" /bin/timeout 1 /bin/sh -c ':' ||
        die "verified timeout cannot run with the installer's dynamic loader/libraries"
    chroot "$initrd_dir" /bin/timeout 0.1 /bin/sh -c 'sleep 2' >/dev/null 2>&1 || timeout_rc=$?
    [ "$timeout_rc" -eq 124 ] || die "installer timeout did not enforce its deadline (status $timeout_rc)"
    [ -x "$initrd_dir/usr/lib/finish-install.d/95-debian-reinstall-cleanup" ] ||
        die "final package-cleanup hook was not installed"
    [ -x "$initrd_dir/usr/lib/post-base-installer.d/10-debian-reinstall-block-extras" ] ||
        die "optional-package block hook was not installed"
    grep -Fq '/debian-netcfg.sh' "$initrd_dir/var/lib/dpkg/info/netcfg.postinst" ||
        die "netcfg hook was not installed"
    local scan_files=(
        "$initrd_dir/initrd-network.sh"
        "$initrd_dir/debian-network-render.sh"
        "$initrd_dir/debian-netcfg.sh"
        "$initrd_dir/get-target-disk.sh"
        "$initrd_dir/can-use-cloud-kernel.sh"
        "$initrd_dir/installer-early.sh"
        "$initrd_dir/installer-partman.sh"
        "$initrd_dir/installer-block-packages.sh"
        "$initrd_dir/installer-late.sh"
        "$initrd_dir/installer-finish.sh"
        "$initrd_dir/preseed.cfg"
    )
    if grep -Eq 'raw\.githubusercontent|cnb\.cool|websocketd|frpc|curl.*(-k|--insecure)' "${scan_files[@]}" \
        2>/dev/null; then
        die "forbidden remote-code/log-service marker found in generated initrd"
    fi
}

repack_initrd() {
    log "Repacking installer initrd"
    (
        cd "$initrd_dir"
        find . -print0 | cpio --null --quiet -o -H newc -R 0:0 | gzip -1 >"$workdir/initrd.patched.gz"
    )
    gzip -t "$workdir/initrd.patched.gz"
}

grub_relative_path() {
    local file=$1 grub_mkrelpath
    grub_mkrelpath="$(find_grub_command grub-mkrelpath || true)"
    [ -n "$grub_mkrelpath" ] || die "grub-mkrelpath is required"
    "$grub_mkrelpath" "$file"
}

disable_source_kexec_bypass() {
    local tmp loaded

    # Some provider Debian templates (notably some Tencent Cloud images) keep
    # a kernel preloaded with kexec-tools. A normal reboot can then bypass the
    # firmware and GRUB, so the verified one-shot entry would never run.
    if command -v systemctl >/dev/null 2>&1; then
        systemctl stop kexec-load.service >/dev/null 2>&1 || true
    fi
    loaded="$(cat /sys/kernel/kexec_loaded 2>/dev/null || echo 0)"
    if [ "$loaded" = 1 ]; then
        command -v kexec >/dev/null 2>&1 ||
            die "a kexec kernel is loaded but the kexec command is unavailable; unload it before reinstalling"
        kexec -u || die "could not unload the source system's preloaded kexec kernel"
        [ "$(cat /sys/kernel/kexec_loaded 2>/dev/null || echo 1)" = 0 ] ||
            die "the source system still has a preloaded kexec kernel"
    fi

    if [ -f "$KEXEC_DEFAULT" ] &&
        grep -Eq '^[[:space:]]*(export[[:space:]]+)?LOAD_KEXEC[[:space:]]*=' \
            "$KEXEC_DEFAULT"; then
        [ -f "$STATE_DIR/$KEXEC_BACKUP_NAME" ] ||
            cp -p -- "$KEXEC_DEFAULT" "$STATE_DIR/$KEXEC_BACKUP_NAME"
        tmp="$(mktemp "$KEXEC_DEFAULT.debian-reinstall.XXXXXXXX")"
        awk '
            /^[[:space:]]*(export[[:space:]]+)?LOAD_KEXEC[[:space:]]*=/ {
                print "LOAD_KEXEC=false"
                next
            }
            { print }
        ' "$KEXEC_DEFAULT" >"$tmp"
        chmod --reference="$KEXEC_DEFAULT" "$tmp" 2>/dev/null || chmod 0644 "$tmp"
        chown --reference="$KEXEC_DEFAULT" "$tmp" 2>/dev/null || true
        mv -- "$tmp" "$KEXEC_DEFAULT"
        grep -Fqx 'LOAD_KEXEC=false' "$KEXEC_DEFAULT" ||
            die "could not disable LOAD_KEXEC in the source system"
        log "Temporarily disabled source-system kexec; --reset restores its original configuration"
    fi
}

install_one_shot_boot() {
    local update_grub grub_reboot grub_editenv grub_kernel grub_initrd
    local boot_kib boot_available required_bytes active_cfg grub_script_check next_entry installer_console
    local boot_uuid uuid_devices
    update_grub="$(find_grub_command update-grub || true)"
    grub_reboot="$(find_grub_command grub-reboot grub2-reboot || true)"
    grub_editenv="$(find_grub_command grub-editenv grub2-editenv || true)"
    [ -n "$update_grub" ] || die "a working Debian GRUB installation is required"
    [ -n "$grub_reboot" ] || die "grub-reboot is required for a true one-shot installer boot"
    [ -n "$grub_editenv" ] || die "grub-editenv is required to verify the one-shot installer boot"
    [ -d /etc/grub.d ] || die "/etc/grub.d is missing"

    boot_kib="$(df -Pk /boot | awk 'NR == 2 {print $4}')"
    [[ "$boot_kib" =~ ^[0-9]+$ ]] || die "could not determine free space on /boot"
    boot_available=$((boot_kib * 1024))
    required_bytes=$(($(stat -c %s "$workdir/linux") + $(stat -c %s "$workdir/initrd.patched.gz") + 33554432))
    [ "$boot_available" -ge "$required_bytes" ] ||
        die "not enough free space on /boot for the verified installer artifacts and safety margin"

    [ ! -e "$STATE_DIR" ] && [ ! -e "$GRUB_SCRIPT" ] && [ ! -e "$GRUB_DEFAULT_DROPIN" ] ||
        die "an earlier preparation exists; run --reset before preparing again"
    next_entry="$("$grub_editenv" - list | sed -n 's/^next_entry=//p')"
    [ -z "$next_entry" ] || die "another one-shot boot is already selected: $next_entry"
    cp -p -- /boot/grub/grub.cfg "$workdir/grub.cfg.before"
    boot_transaction=true
    mkdir -p "$STATE_DIR"
    disable_source_kexec_bypass
    install -m 0600 "$workdir/linux" "$STATE_DIR/linux"
    install -m 0600 "$workdir/initrd.patched.gz" "$STATE_DIR/initrd.gz"
    grub_kernel="$(grub_relative_path "$STATE_DIR/linux")"
    grub_initrd="$(grub_relative_path "$STATE_DIR/initrd.gz")"
    boot_uuid="$(findmnt -n -o UUID -T "$STATE_DIR/linux")"
    [[ "$boot_uuid" =~ ^[0-9a-fA-F-]+$ ]] || die "installer boot filesystem has no valid UUID"
    uuid_devices="$(blkid -c /dev/null -t "UUID=$boot_uuid" -o device)" ||
        die "could not locate the installer boot filesystem UUID"
    [ "$(printf '%s\n' "$uuid_devices" | wc -l)" -eq 1 ] ||
        die "installer boot filesystem UUID is duplicated; refusing ambiguous boot"
    installer_console="$(cat "$initrd_dir/configs/console")"
    [[ "$grub_kernel" = /* && "$grub_initrd" = /* ]] || die "GRUB returned unsafe artifact paths"
    cat >"$GRUB_SCRIPT" <<EOF
#!/bin/sh
cat <<'GRUBEOF'
if [ -z "\${next_entry}" ]; then
    for env_dir in /boot/grub /boot/grub2 /grub /grub2; do
        set env_file="(\$root)\$env_dir/grubenv"
        if [ -s "\$env_file" ]; then
            load_env --file "\$env_file" next_entry
            if [ -n "\${next_entry}" ]; then
                set default="\${next_entry}"
                set next_entry=
                save_env --file "\$env_file" next_entry
                break
            fi
        fi
    done
fi

menuentry 'Debian $release secure unattended reinstall' --id debian-reinstall --unrestricted {
    insmod part_gpt
    insmod part_msdos
    insmod ext2
    insmod btrfs
    insmod xfs
    insmod lvm
    insmod mdraid1x
    set btrfs_relative_path=n
    search --no-floppy --fs-uuid --set=root $boot_uuid
    linux $grub_kernel lowmem/low=1 auto=true priority=critical preseed/file=/preseed.cfg mirror/http/hostname=$mirror_host mirror/http/directory=$mirror_directory base-installer/kernel/image=$kernel_image $installer_console
    initrd $grub_initrd
}
GRUBEOF
EOF
    chmod 0755 "$GRUB_SCRIPT"
    mkdir -p "$(dirname "$GRUB_DEFAULT_DROPIN")"
    cat >"$GRUB_DEFAULT_DROPIN" <<'EOF'
GRUB_DEFAULT=saved
GRUB_SAVEDEFAULT=false
GRUB_TIMEOUT_STYLE=menu
GRUB_TIMEOUT=5
EOF

    "$update_grub"

    active_cfg="$(readlink -f /boot/grub/grub.cfg)"
    [ -s "$active_cfg" ] || die "update-grub did not produce a readable active configuration"
    grep -Fq -- '--id debian-reinstall' "$active_cfg" ||
        die "the active GRUB configuration does not contain the reinstall entry"
    grub_script_check="$(find_grub_command grub-script-check grub2-script-check || true)"
    if [ -n "$grub_script_check" ]; then
        "$grub_script_check" "$active_cfg" >/dev/null
    else
        die "grub-script-check is required to validate the generated configuration"
    fi
    # Arm only after every artifact/configuration check. EXIT/signal rollback
    # also covers a grub-reboot that writes successfully but returns failure.
    "$grub_reboot" debian-reinstall
    next_entry="$("$grub_editenv" - list 2>/dev/null |
        sed -n 's/^next_entry=//p' | head -n 1)"
    [ "$next_entry" = debian-reinstall ] ||
        die "GRUB did not persist the one-shot reinstall selection"
    sync
    boot_committed=true
}

show_summary() {
    display_heading 36 "Debian reinstall plan"
    cat >&2 <<EOF
------------------------------------------------------------
  Target system    : Debian $release ($codename, $arch)
  Target disk      : $target_disk
  Disk capacity    : $disk_size bytes
  Disk PTUUID      : $disk_ptuuid
  Root filesystem  : $filesystem
  Boot mode        : $([ -d /sys/firmware/efi ] && echo UEFI || echo BIOS)

  Network          : captured from current default IPv4/IPv6 routes
  Mirror           : $mirror
  Verification     : signed metadata and SHA-256 verification required
  Authentication   : $credential_kind

  Installer lowmem : Debian Installer automatic detection
  Temporary swap   : below 768 MiB during installation only
  Storage trimming : $low_memory_active
  Execution        : unattended preparation; reboot remains manual
------------------------------------------------------------
EOF
}

show_completion() {
    display_heading 32 "One-shot Debian reinstall is prepared; this script did not reboot"
    cat >&2 <<EOF
------------------------------------------------------------
  The next boot will repartition $target_disk, format new filesystems,
  and install Debian $release.
  No SSH or HTTP management service is exposed while Debian Installer runs.

  Cancel before reboot:
    bash -- $(printf '%q' "$0") --reset

  Start when ready:
    systemctl reboot
------------------------------------------------------------
EOF
}

main() {
    require_root_debian
    validate_options
    preflight_source_system
    workdir="$(mktemp -d /var/tmp/debian-reinstall.XXXXXXXX)"
    log "Work directory: $workdir"
    install_dependencies
    require_secure_boot_disabled
    detect_architecture
    select_target_disk
    disk_facts "$target_disk"
    validate_disk_fingerprint_unique
    detect_boot_layout
    prepare_credentials
    configure_memory_mode
    show_summary

    load_signed_release
    load_package_indexes
    download_installer_images
    unpack_initrd
    install_embedded_assets "$initrd_dir"
    write_runtime_configs
    collect_network
    install_verified_udebs
    add_low_memory_storage_modules
    add_hyperv_pci_module_if_needed
    patch_installer_initrd
    verify_initrd_contents
    repack_initrd
    install_one_shot_boot

    show_completion
}

if [ "${DEBIAN_REINSTALL_LIBRARY_ONLY:-0}" != 1 ]; then
    main
fi
