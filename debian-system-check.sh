#!/usr/bin/env bash

set -u
set -o pipefail

if (( EUID != 0 )); then
    printf '请使用 root 运行此检查器。\n' >&2
    exit 2
fi

if [[ -t 1 && ${TERM:-dumb} != dumb && -z ${NO_COLOR:-} ]]; then
    green=$'\033[1;32m'
    yellow=$'\033[1;33m'
    red=$'\033[1;31m'
    cyan=$'\033[1;36m'
    bold=$'\033[1m'
    dim=$'\033[2m'
    reset=$'\033[0m'
else
    green='' yellow='' red='' cyan='' bold='' dim='' reset=''
fi

pass_count=0
warn_count=0
fail_count=0
apt_log=$(mktemp /tmp/debian-system-check.XXXXXXXX) || exit 2
trap 'rm -f -- "$apt_log"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

pass() {
    ((pass_count += 1))
    printf '%s✓ PASS%s  %s\n' "$green" "$reset" "$*"
}

warn() {
    ((warn_count += 1))
    printf '%s⚠ WARN%s  %s\n' "$yellow" "$reset" "$*"
}

fail() {
    ((fail_count += 1))
    printf '%s✗ FAIL%s  %s\n' "$red" "$reset" "$*"
}

section() {
    printf '\n%s━━ %s ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n' \
        "$cyan" "$*" "$reset"
}

value() {
    printf '  %-18s %s\n' "$1" "$2"
}

indent() {
    sed 's/^/    /'
}

resolve_backing_disks() {
    local path=$1 source major_minor
    source=$(findmnt -n -o SOURCE -T "$path" 2>/dev/null || true)
    source=${source%%\[*}
    if [[ ! -b $source ]]; then
        major_minor=$(findmnt -n -o MAJ:MIN -T "$path" 2>/dev/null || true)
        if [[ -n $major_minor && -e /dev/block/$major_minor ]]; then
            source=$(readlink -f -- "/dev/block/$major_minor")
        fi
    fi
    [[ -b $source ]] || return 1
    lsblk -s -n -o KNAME,TYPE "$source" 2>/dev/null |
        awk '$2=="disk" {print "/dev/" $1}' | sort -u
}

valid_public_dns() {
    awk '
        /^[[:space:]]*(#|$)/ {next}
        $1=="nameserver" {
            if ($2!="8.8.8.8" && $2!="1.1.1.1" &&
                $2!="2001:4860:4860::8888" && $2!="2606:4700:4700::1111") bad=1
            count++
        }
        END {exit (bad || !count) ? 1 : 0}
    ' "$1"
}

valid_debian_sources() {
    # Intentionally strict for this newly installed system: reject duplicate
    # fields, extra URIs/suites, Trusted/Enabled overrides and unknown fields.
    awk '
        BEGIN {RS=""; FS="\n"}
        {
            delete fields
            n=0
            for (i=1; i<=NF; i++) {
                line=$i
                if (line ~ /^[[:space:]]*(#|$)/) continue
                colon=index(line, ":")
                if (!colon) {bad=1; continue}
                key=substr(line,1,colon-1); value=substr(line,colon+1)
                sub(/^[[:space:]]+/, "", value); sub(/[[:space:]]+$/, "", value)
                if (key in fields) bad=1
                fields[key]=value; n++
            }
            if (!n) next
            records++
            if (n!=5 || fields["Types"]!="deb" || fields["Components"]!="main" ||
                fields["Signed-By"]!="/usr/share/keyrings/debian-archive-keyring.pgp") bad=1
            if (fields["URIs"]=="https://deb.debian.org/debian" &&
                fields["Suites"]=="trixie trixie-updates") main++
            else if (fields["URIs"]=="https://security.debian.org/debian-security" &&
                fields["Suites"]=="trixie-security") security++
            else bad=1
        }
        END {exit (bad || records!=2 || main!=1 || security!=1) ? 1 : 0}
    ' "$1"
}

check_ssh_socket_policy() {
    local mask=/etc/systemd/system-generators/systemd-ssh-generator
    local override=/run/systemd/system-generators/systemd-ssh-generator
    local mask_ok=true unit_files units unexpected unix_sockets vsock_sockets
    if [[ ! -L $mask || $(readlink "$mask" 2>/dev/null) != /dev/null ]]; then
        mask_ok=false
    fi
    if [[ -e $override || -L $override ]]; then
        if [[ ! -L $override || $(readlink "$override" 2>/dev/null) != /dev/null ]]; then
            mask_ok=false
        fi
    fi
    if $mask_ok; then
        pass '自动 SSH socket 生成器已持久禁用，且没有覆盖它的运行时生成器'
    else
        fail '自动 SSH socket 生成器未可靠禁用，可能创建额外登录入口'
    fi

    if unit_files=$(LC_ALL=C systemctl list-unit-files --type=socket --no-legend --no-pager 2>&1); then
        unexpected=$(awk '$1 ~ /^ssh.*\.socket$/ && $2 !~ /^(disabled|masked|masked-runtime)$/ {print}' <<<"$unit_files")
        if [[ -z $unexpected ]]; then
            pass '没有启用或生成的额外 SSH socket 单元'
        else
            fail '发现启用、生成或其他非预期状态的 SSH socket 单元'
            printf '%s\n' "$unexpected" | indent
        fi
    else
        fail "无法读取 SSH socket 单元文件状态：$unit_files"
    fi
    if units=$(LC_ALL=C systemctl list-units --all --type=socket --plain --no-legend --no-pager 2>&1); then
        unexpected=$(awk '$1 ~ /^ssh.*\.socket$/ && $3 != "inactive" {print}' <<<"$units")
        if [[ -z $unexpected ]]; then
            pass '没有运行中、正在启动或失败的额外 SSH socket 单元'
        else
            fail '发现非预期的 SSH socket 运行状态'
            printf '%s\n' "$unexpected" | indent
        fi
    else
        fail "无法读取 SSH socket 运行状态：$units"
    fi

    if unix_sockets=$(LC_ALL=C ss -H -l -x -n -p 2>&1); then
        unexpected=$(grep -E '/run/ssh-|/run/host/unix-export/ssh|users:\(\("sshd' <<<"$unix_sockets" || true)
        if [[ -z $unexpected ]]; then
            pass '没有检测到额外的 Unix-socket SSH 监听'
        else
            fail '发现额外的 Unix-socket SSH 监听'
            printf '%s\n' "$unexpected" | indent
        fi
    else
        fail "无法读取 Unix socket 监听：$unix_sockets"
    fi
    if vsock_sockets=$(LC_ALL=C ss -H -l -n -p --vsock 2>&1); then
        if [[ -z $vsock_sockets ]]; then
            pass '没有 VSOCK 监听'
        else
            fail '发现非预期的 VSOCK 监听'
            printf '%s\n' "$vsock_sockets" | indent
        fi
    else
        warn '无法查询 VSOCK 监听；不据此宣称没有此类入口'
        printf '%s\n' "$vsock_sockets" | indent
    fi
}

check_baseline_packages() {
    local inventory package status version
    # Read the whole database so a query failure cannot mean "not installed".
    # shellcheck disable=SC2016
    if ! inventory=$(dpkg-query -W -f='${Package}\t${db:Status-Status}\t${Version}\n' 2>&1); then
        fail "无法读取基础组件安装状态：$inventory"
        return
    fi
    for package in libc6 libc-bin openssh-server ca-certificates systemd-timesyncd; do
        status=$(awk -F '\t' -v p="$package" '$1==p {print $2}' <<<"$inventory")
        version=$(awk -F '\t' -v p="$package" '$1==p {print $3}' <<<"$inventory")
        if [[ $status == installed && -n $version ]]; then
            pass "基础组件已安装：$package $version"
        else
            fail "基础组件未完整安装：$package（状态：${status:-不在清单中}）"
        fi
    done
}

check_time_sync() {
    local properties can_ntp ntp_enabled synchronized
    if ! properties=$(timedatectl show -p CanNTP -p NTP -p NTPSynchronized 2>&1); then
        warn "无法读取时钟同步状态：$properties"
        return
    fi
    can_ntp=$(sed -n 's/^CanNTP=//p' <<<"$properties")
    ntp_enabled=$(sed -n 's/^NTP=//p' <<<"$properties")
    synchronized=$(sed -n 's/^NTPSynchronized=//p' <<<"$properties")
    if [[ ! $can_ntp =~ ^(yes|no)$ || ! $ntp_enabled =~ ^(yes|no)$ || ! $synchronized =~ ^(yes|no)$ ]]; then
        warn '时钟同步状态缺失或格式异常，不能据此确认已同步'
        return
    fi
    if [[ $can_ntp == no ]]; then
        warn '未发现可用网络校时服务；等待或重启不会自动安装服务'
    elif [[ $ntp_enabled == no ]]; then
        warn '已有网络校时服务，但尚未启用；不能依靠等待自动完成校时'
    elif ! systemctl is-enabled --quiet systemd-timesyncd.service; then
        warn '网络校时已启用，但预期的 systemd-timesyncd 未设置为开机启用；请核对是否更换了校时实现'
    elif ! systemctl is-active --quiet systemd-timesyncd.service; then
        warn 'systemd-timesyncd 已设置开机启用，但当前未运行；请检查服务日志'
    elif [[ $synchronized == yes ]]; then
        pass 'systemd-timesyncd 已启用并运行，内核已报告时钟同步'
    else
        warn 'systemd-timesyncd 已启用并运行，但内核尚未报告同步；可能正在等待首次响应，持续不成功请检查 NTP 连通性'
    fi
}

if [[ ${DEBIAN_SYSTEM_CHECK_LIBRARY_ONLY:-0} == 1 ]]; then
    return 0 2>/dev/null || exit 0
fi

connection=${SSH_CONNECTION:-}
current_ip=${connection%% *}
current_ssh_port=${connection##* }
if [[ -z $connection ]]; then
    current_ip=
    current_ssh_port=$(/usr/sbin/sshd -T 2>/dev/null |
        awk '$1 == "port" {print $2; exit}')
fi

printf '%s╭──────────────────────────────────────────────────────╮%s\n' "$bold$cyan" "$reset"
printf '%s│       Debian 新系统完整性与操作就绪检查             │%s\n' "$bold$cyan" "$reset"
printf '%s╰──────────────────────────────────────────────────────╯%s\n' "$bold$cyan" "$reset"
printf '%s只执行状态检查和一次 apt-get update，不安装软件包。%s\n' "$dim" "$reset"

section '系统信息'
os_pretty=$(sed -n 's/^PRETTY_NAME=//p' /etc/os-release | tr -d '"')
root_fstype=$(findmnt -n -o FSTYPE /)
root_options=$(findmnt -n -o OPTIONS /)
memory_mib=$(awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo)
boot_mode=$([[ -d /sys/firmware/efi ]] && echo UEFI || echo BIOS)
root_disks=$(resolve_backing_disks / || true)
value '当前时间' "$(date -Is)"
value 'hostname' "$(hostname)"
value '操作系统' "$os_pretty"
value '内核' "$(uname -r)"
value '内存' "${memory_mib} MiB"
value '运行时间' "$(uptime -p)"
value '根文件系统' "$root_fstype ($root_options)"
value '启动模式' "$boot_mode"
value '系统磁盘' "${root_disks:-无法识别}"
value '当前SSH来源' "${current_ip:-无法从当前会话识别}"
value '当前SSH端口' "${current_ssh_port:-未知}"

if [[ $(hostname) == debian ]]; then
    pass 'hostname 固定为 debian'
else
    fail "hostname 不是 debian：$(hostname)"
fi
if grep -Eq '^ID=("?debian"?)$' /etc/os-release &&
    grep -Eq '^VERSION_ID="?13"?$' /etc/os-release; then
    pass "操作系统为 $os_pretty"
else
    fail '操作系统不是预期的 Debian 13'
fi
if [[ $root_fstype == ext4 ]]; then
    pass '根文件系统为 ext4'
else
    fail "根文件系统不是 ext4：$root_fstype"
fi
if [[ ,$root_options, == *,rw,* ]]; then
    pass '根文件系统已按读写模式挂载'
else
    fail '根文件系统不是读写模式，暂时不能修改配置'
fi

section '磁盘、分区与引导完整性'
lsblk -e 7 -o NAME,TYPE,FSTYPE,SIZE,RO,MOUNTPOINTS,UUID,PARTUUID 2>/dev/null | indent
root_disk_count=$(sed '/^$/d' <<<"$root_disks" | wc -l | tr -d ' ')
if [[ $root_disk_count == 1 ]]; then
    root_disk=$root_disks
    pass "根文件系统只位于一块系统盘：$root_disk"
else
    root_disk=
    fail "根文件系统对应 $root_disk_count 块磁盘，无法确认干净的单盘布局"
fi

if [[ -n $root_disk ]]; then
    disk_ro=$(lsblk -dn -o RO "$root_disk" 2>/dev/null | tr -d '[:space:]')
    if [[ $disk_ro == 0 ]]; then
        pass '系统盘不是只读设备'
    else
        fail "系统盘只读状态异常：$disk_ro"
    fi

    stack_types=$(lsblk -nr -o TYPE "$root_disk" 2>/dev/null)
    if [[ $? != 0 || -z $stack_types ]]; then
        fail '无法读取系统盘的存储层级'
    elif grep -Eq '^(crypt|lvm|raid[0-9]+|md)$' <<<"$stack_types"; then
        fail '新系统盘仍包含加密、LVM 或软件 RAID 层'
    else
        pass '新系统盘没有旧的加密、LVM 或软件 RAID 层'
    fi

    partition_count=$(grep -c '^part$' <<<"$stack_types" || true)
    partition_table=$(lsblk -dn -o PTTYPE "$root_disk" 2>/dev/null | tr -d '[:space:]')
    if [[ $boot_mode == UEFI ]]; then
        expected_partitions=2
    elif [[ $partition_table == gpt ]]; then
        expected_partitions=2
    else
        expected_partitions=1
    fi
    if (( partition_count == expected_partitions )); then
        pass "系统盘分区数量符合 $boot_mode/$partition_table 最小布局：$partition_count"
    else
        fail "系统盘有 $partition_count 个分区，预期最小布局为 $expected_partitions 个"
    fi

    boot_disks=$(resolve_backing_disks /boot || true)
    if [[ $boot_disks == "$root_disk" ]]; then
        pass '/boot 与根文件系统位于同一系统盘'
    else
        fail "/boot 的磁盘与根文件系统不一致：${boot_disks:-无法识别}"
    fi
fi

if [[ $boot_mode == UEFI ]]; then
    esp_mount=
    for path in /boot/efi /efi /boot; do
        if findmnt -rn -M "$path" >/dev/null 2>&1; then
            path_fstype=$(findmnt -n -o FSTYPE -M "$path" 2>/dev/null || true)
            case "$path_fstype" in vfat|fat|msdos) esp_mount=$path; break ;; esac
        fi
    done
    if [[ -n $esp_mount ]]; then
        pass "EFI System Partition 已挂载：$esp_mount"
        esp_disks=$(resolve_backing_disks "$esp_mount" || true)
        if [[ -n ${root_disk:-} && $esp_disks == "$root_disk" ]]; then
            pass 'EFI System Partition 与根文件系统位于同一系统盘'
        else
            fail "EFI System Partition 位于其他磁盘：${esp_disks:-无法识别}"
        fi
        unexpected_esp_top=$(find "$esp_mount" -mindepth 1 -maxdepth 1 \
            ! -name EFI -printf '%f\n' 2>/dev/null || true)
        unexpected_efi=$(find "$esp_mount/EFI" -mindepth 1 -maxdepth 1 \
            ! -iname debian ! -iname boot -printf '%f\n' 2>/dev/null || true)
        efi_loader=$(find "$esp_mount/EFI" -type f \
            \( -iname '*.efi' -o -iname 'grub*.efi' \) -size +0c \
            -print -quit 2>/dev/null || true)
        if [[ -z $unexpected_esp_top && -z $unexpected_efi && -n $efi_loader ]]; then
            pass 'EFI 分区没有顶层隐藏残留，仅包含 Debian 与标准回退引导目录'
        else
            fail "EFI 分区内容异常：顶层=${unexpected_esp_top:-正常}，EFI目录=${unexpected_efi:-正常}，引导文件=${efi_loader:-缺失}"
        fi
    else
        fail 'UEFI 系统没有挂载 EFI System Partition'
    fi
else
    pass '当前为 BIOS，引导检查不涉及 EFI 分区残留'
fi

if [[ -s /boot/grub/grub.cfg ]] &&
    find /boot -maxdepth 1 -type f -name 'vmlinuz-*' -size +0c -print -quit | grep -q . &&
    find /boot -maxdepth 1 -type f -name 'initrd.img-*' -size +0c -print -quit | grep -q .; then
    pass 'GRUB 配置、内核与 initrd 均存在'
else
    fail 'GRUB 配置、内核或 initrd 不完整'
fi

kexec_loaded=0
if [[ -e /sys/kernel/kexec_loaded ]]; then
    kexec_loaded=$(cat /sys/kernel/kexec_loaded 2>/dev/null) || kexec_loaded=unknown
fi
kexec_config_safe=true
if [[ -e /etc/default/kexec ]]; then
    # Do not source this file. Only literal disabled assignments are safe;
    # quoted true, comments, exports and expressions must not be overlooked.
    if ! awk '
        /^[[:space:]]*(export[[:space:]]+)?LOAD_KEXEC[[:space:]]*=/ {
            sub(/^[^=]*=[[:space:]]*/, "")
            sub(/[[:space:]]*#.*/, ""); gsub(/[\047\042]/, "")
            sub(/[[:space:]]+$/, "")
            if ($0!="false" && $0!="no" && $0!="0") bad=1
        }
        END {exit bad ? 1 : 0}
    ' /etc/default/kexec; then kexec_config_safe=false; fi
fi
if [[ $kexec_loaded == 0 ]] && $kexec_config_safe; then
    pass '没有预载 kexec 内核或绕过 GRUB 的 LOAD_KEXEC 配置'
else
    fail "检测到可能绕过正常 GRUB 启动的 kexec 状态：loaded=$kexec_loaded"
fi

fstab_verify=$(findmnt --verify --tab-file /etc/fstab 2>&1)
fstab_rc=$?
if (( fstab_rc == 0 )); then
    pass 'fstab 语法及设备引用验证通过'
else
    fail 'fstab 验证失败'
    printf '%s\n' "$fstab_verify" | indent
fi

section 'systemd 完整启动状态'
boot_state=$(timeout 90 systemctl is-system-running --wait 2>&1)
boot_state_rc=$?
value 'systemd 状态' "$boot_state"
if [[ $boot_state_rc == 0 && $boot_state == running ]]; then
    pass 'systemd 已完成启动并处于 running'
else
    fail "systemd 未达到正常 running 状态：$boot_state"
fi

multi_user_state=$(systemctl is-active multi-user.target 2>&1 || true)
if [[ $multi_user_state == active ]]; then
    pass 'Debian Server 已到达 multi-user.target'
else
    fail "multi-user.target 状态异常：$multi_user_state"
fi

pending_jobs=$(systemctl list-jobs --no-legend --no-pager 2>&1)
if [[ $? != 0 ]]; then
    fail "无法读取 systemd 待处理任务：$pending_jobs"
elif [[ -z $pending_jobs ]]; then
    pass '没有尚未完成的 systemd 启动任务'
else
    fail '仍有 systemd 任务未完成'
    printf '%s\n' "$pending_jobs" | indent
fi

failed_units=$(systemctl --failed --no-legend --no-pager 2>&1)
if [[ $? != 0 ]]; then
    fail "无法读取 systemd 失败单元：$failed_units"
elif [[ -z $failed_units ]]; then
    pass '没有失败的 systemd 单元'
else
    fail '存在失败的 systemd 单元'
    printf '%s\n' "$failed_units" | indent
fi

serial_console_problem=false
for tty in ttyS0 ttyAMA0; do
    case " $(cat /proc/cmdline) " in
        *" console=$tty"*)
            if [[ ! -c /dev/$tty ]] ||
                ! timeout 3 stty -g -F "/dev/$tty" >/dev/null 2>&1; then
                unit="serial-getty@$tty.service"
                unit_state=$(systemctl is-active "$unit" 2>/dev/null || true)
                unit_restarts=$(systemctl show "$unit" -p NRestarts --value \
                    2>/dev/null || true)
                if [[ $unit_state == active || $unit_state == activating || $unit_state == reloading || $unit_state == deactivating ]]; then
                    fail "$tty 不可用但 $unit 仍在运行/重试（NRestarts=${unit_restarts:-未知}）"
                    serial_console_problem=true
                elif [[ $unit_state == inactive || $unit_state == failed ]]; then
                    warn "$tty 在本次内核命令行中不可用，但对应 getty 已停止；下次重启会验证修正后的 GRUB 配置"
                else
                    fail "无法确定 $unit 的运行状态"
                    serial_console_problem=true
                fi
            fi
            ;;
    esac
done
if ! $serial_console_problem; then
    pass '无效串口 getty 当前未处于运行或自动重启状态'
fi

# A single snapshot can land between retries. Observe restart counters for all
# running/activating services, including agetty and the first-boot repairs.
restart_before=$(systemctl show '*.service' --all -p Id -p NRestarts 2>&1)
restart_rc=$?
sleep 5
restart_after=$(systemctl show '*.service' --all -p Id -p NRestarts 2>&1)
if [[ $restart_rc != 0 || $? != 0 || -z $restart_before || -z $restart_after ]]; then
    fail '无法完成服务重启计数的短时观察'
else
    growing_restarts=$(awk -v before="$restart_before" '
        BEGIN {
            RS=""; FS="\n"
            n=split(before, records, "\n\n")
            for (r=1;r<=n;r++) {
                m=split(records[r], a, "\n"); id=""; v=0
                for (i=1;i<=m;i++) {
                    if (a[i] ~ /^Id=/) id=substr(a[i],4)
                    if (a[i] ~ /^NRestarts=/) v=substr(a[i],11)+0
                }
                if (id!="") counts[id]=v
            }
        }
        {
            id=""; v=0
            for (i=1;i<=NF;i++) {
                if ($i ~ /^Id=/) id=substr($i,4)
                if ($i ~ /^NRestarts=/) v=substr($i,11)+0
            }
            if (id!="" && v>counts[id]) print id ": " counts[id] " -> " v
        }
    ' <<<"$restart_after")
    if [[ -n $growing_restarts ]]; then
        fail "观察窗口内服务发生自动重启：$growing_restarts"
    else
        pass '5 秒观察窗口内未检测到服务自动重启计数增长（非长期稳定性保证）'
    fi
fi

startup_time=$(systemd-analyze time 2>&1 || true)
if grep -Fq 'Startup finished in ' <<<"$startup_time"; then
    pass "$startup_time"
else
    warn "systemd-analyze 没有返回标准启动耗时：$startup_time"
fi

section '软件包管理器就绪状态'
package_processes=$(ps -eo pid=,comm=,args= | awk '
    $2 ~ /^(apt|apt-get|dpkg|dpkg-deb|unattended-upgr)$/ {print}
')
if [[ $? != 0 ]]; then
    fail '无法读取软件包管理进程'
elif [[ -z $package_processes ]]; then
    pass '没有 apt/dpkg 进程正在运行'
else
    fail '有软件包管理进程正在运行，暂时不要安装软件'
    printf '%s\n' "$package_processes" | indent
fi

package_locks=$(lslocks -n -o COMMAND,PID,PATH 2>/dev/null | awk '
    $3 ~ /^\/var\/(lib\/(dpkg|apt\/lists)|cache\/apt\/archives)\/lock/ {print}
')
if [[ $? != 0 ]]; then
    fail '无法读取软件包管理器锁状态'
elif [[ -z $package_locks ]]; then
    pass '没有 apt/dpkg 锁被占用'
else
    fail 'apt/dpkg 锁正在被占用'
    printf '%s\n' "$package_locks" | indent
fi

dpkg_audit=$(dpkg --audit 2>&1)
if [[ $? != 0 ]]; then
    fail "无法完成 dpkg 数据库检查：$dpkg_audit"
elif [[ -z $dpkg_audit ]]; then
    pass 'dpkg 数据库完整，没有未配置或残缺软件包'
else
    fail 'dpkg 数据库存在异常'
    printf '%s\n' "$dpkg_audit" | indent
fi

dpkg_updates=$(find /var/lib/dpkg/updates -mindepth 1 -maxdepth 1 \
    -type f -print 2>/dev/null)
if [[ $? != 0 ]]; then
    fail '无法读取 dpkg 状态更新目录'
elif [[ -z $dpkg_updates ]]; then
    pass '没有未完成的 dpkg 状态更新文件'
else
    fail '发现未完成的 dpkg 状态更新文件'
    printf '%s\n' "$dpkg_updates" | indent
fi

available_kib=$(df -Pk / | awk 'NR == 2 {print $4}')
available_mib=$((available_kib / 1024))
available_inodes=$(df -Pi / | awk 'NR == 2 {print $4}')
value '根分区可用空间' "${available_mib} MiB"
value '根分区可用 inode' "$available_inodes"
if (( available_mib >= 512 )); then
    pass '根分区至少有 512 MiB 可用空间'
else
    fail '根分区可用空间不足 512 MiB'
fi
if (( available_inodes >= 1000 )); then
    pass '根分区 inode 余量正常'
else
    fail '根分区可用 inode 过少'
fi

if apt-get check >"$apt_log" 2>&1; then
    pass 'APT 依赖关系检查通过'
else
    fail 'APT 依赖关系异常'
    tail -n 20 "$apt_log" | indent
fi

printf '  正在验证 DNS、HTTPS、签名和仓库索引...\n'
if DEBIAN_FRONTEND=noninteractive apt-get \
    -o Acquire::Retries=2 \
    -o APT::Update::Error-Mode=any \
    update >"$apt_log" 2>&1; then
    pass 'apt-get update 成功，可以安装软件'
else
    fail 'apt-get update 失败，暂时不要安装软件'
    tail -n 25 "$apt_log" | indent
fi

if [[ -e /run/reboot-required ]]; then
    warn '系统提示需要再次重启；请先查看 /run/reboot-required.pkgs'
else
    pass '系统没有待处理的重启要求'
fi

section '基础组件与时钟同步'
check_baseline_packages
check_time_sync

section '网络与监听端口'
default_routes=$(ip -4 route show default; ip -6 route show default)
if [[ -n $default_routes ]]; then
    pass '至少存在一条默认路由'
    printf '%s\n' "$default_routes" | indent
else
    fail '没有 IPv4 或 IPv6 默认路由'
fi
if getent ahosts deb.debian.org >/dev/null 2>&1; then
    pass 'DNS 可以解析 deb.debian.org'
else
    fail 'DNS 无法解析 deb.debian.org'
fi

configured_ifaces=$(awk '
    $1=="auto" || $1=="allow-hotplug" || $1=="iface" {
        if ($2 != "lo") print $2
    }
' /etc/network/interfaces 2>/dev/null | sort -u)
missing_ifaces=
for interface in $configured_ifaces; do
    [[ -e /sys/class/net/$interface ]] || missing_ifaces+=" $interface"
done
if [[ -n $configured_ifaces && -z $missing_ifaces ]]; then
    pass '网络配置中的所有网卡名称都与当前内核一致'
else
    fail "网络配置引用了不存在的网卡，或没有配置物理网卡：${missing_ifaces:-无网卡条目}"
fi

route_ifaces=$(awk '
    {
        for (i=1; i<NF; i++) if ($i=="dev") print $(i+1)
    }
' <<<"$default_routes" | sort -u)
unconfigured_routes=
for interface in $route_ifaces; do
    grep -Fxq "$interface" <<<"$configured_ifaces" || unconfigured_routes+=" $interface"
done
if [[ -n $route_ifaces && -z $unconfigured_routes ]]; then
    pass '所有默认路由都使用已写入配置的网卡'
else
    fail "默认路由使用了未持久化的网卡：${unconfigured_routes:-无法识别}"
fi

tcp_listeners=$(ss -H -lntp 2>/dev/null || true)
printf '%s\n' "$tcp_listeners" | indent
if [[ -n ${current_ssh_port:-} && -n $tcp_listeners ]] &&
    grep -Eq ":${current_ssh_port}([[:space:]]|$)" <<<"$tcp_listeners" &&
    ! awk -v port="$current_ssh_port" \
    '$4 !~ (":" port "$") {unexpected=1} END {exit unexpected ? 0 : 1}' \
    <<<"$tcp_listeners"; then
    pass "所有 TCP 监听都属于 SSH 端口 $current_ssh_port"
else
    fail '发现 SSH 端口以外的 TCP 监听，或无法识别 SSH 端口'
fi

udp_listeners=$(ss -H -lunp 2>/dev/null)
udp_rc=$?
unexpected_udp=
while read -r state recvq sendq local_addr peer_addr process; do
    [[ -n ${local_addr:-} ]] || continue
    udp_port=${local_addr##*:}
    udp_host=${local_addr%:*}
    udp_host=${udp_host#[}
    udp_host=${udp_host%]}
    udp_host=${udp_host%%%*}
    case "$udp_port" in
        68|546) continue ;;
    esac
    case "$udp_host" in
        127.*|::1) continue ;;
    esac
    unexpected_udp+="${unexpected_udp:+$'\n'}$state $recvq $sendq $local_addr $peer_addr ${process:-}"
done <<<"$udp_listeners"
if [[ $udp_rc != 0 ]]; then
    fail '无法读取 UDP 监听状态'
elif [[ -z $unexpected_udp ]]; then
    pass '没有额外的公网 UDP 监听（DHCP 客户端端口除外）'
else
    fail '发现非预期的公网 UDP 监听'
    printf '%s\n' "$unexpected_udp" | indent
fi

section '额外 SSH socket 入口'
check_ssh_socket_policy

section 'SSH 安全策略与成功登录来源'
ssh_context=()
if [[ -n $connection ]]; then
    read -r client_addr _client_port server_addr server_port <<<"$connection"
    ssh_context=(-C "user=root,addr=$client_addr,host=$client_addr,laddr=$server_addr,lport=$server_port")
fi
sshd_effective=$(/usr/sbin/sshd -T "${ssh_context[@]}" 2>&1)
sshd_rc=$?
if [[ $sshd_rc == 0 ]]; then
    pass 'sshd 配置展开成功（有 SSH 会话时按当前 root 连接条件计算）'
else
    fail 'sshd -T 检查失败'
    printf '%s\n' "$sshd_effective" | indent
fi
if grep -Eiq '^[[:space:]]*Match[[:space:]]' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null; then
    warn '发现 SSH Match 条件：以下结果只覆盖当前连接；其他来源、主机名和用户的策略需要单独审查'
fi

required_settings=(
    "port ${current_ssh_port:-unknown}"
    'allowusers root'
    'pubkeyauthentication yes'
    'kbdinteractiveauthentication no'
    'permitemptypasswords no'
    'logingracetime 30'
    'maxauthtries 3'
    'maxstartups 10:30:60'
    'x11forwarding no'
    'allowagentforwarding no'
    'allowtcpforwarding no'
    'allowstreamlocalforwarding no'
    'disableforwarding yes'
    'gatewayports no'
    'permittunnel no'
    'permituserenvironment no'
)
for setting in "${required_settings[@]}"; do
    if [[ $sshd_rc == 0 ]] && grep -Fqx "$setting" <<<"$sshd_effective"; then
        pass "SSH：$setting"
    else
        fail "SSH 配置不符合预期：$setting"
    fi
done

root_login_value=$(awk '$1=="permitrootlogin" {print $2; exit}' <<<"$sshd_effective")
case "$root_login_value" in
    yes) pass 'SSH：root 登录已启用（当前密码初始化模式）' ;;
    prohibit-password|without-password)
        pass 'SSH：root 仅允许密钥登录'
        ;;
    *) fail "SSH：PermitRootLogin 状态不符合 root 管理模式：$root_login_value" ;;
esac
password_auth_value=$(awk '$1=="passwordauthentication" {print $2; exit}' <<<"$sshd_effective")
case "$password_auth_value" in
    yes) pass 'SSH：密码登录当前已启用，便于首次初始化' ;;
    no) pass 'SSH：密码登录已关闭，当前为更安全的密钥模式' ;;
    *) fail "SSH：无法判断 PasswordAuthentication：$password_auth_value" ;;
esac

# Same-field journal matches are ORed. Include the split OpenSSH processes,
# irrespective of whether a service, socket unit or manual invocation ran them.
ssh_log=$(journalctl -b --no-pager -o cat \
    _COMM=sshd _COMM=sshd-session _COMM=sshd-auth 2>/dev/null)
ssh_log_rc=$?
accepted_lines=$(grep -E \
    'Accepted (password|publickey|keyboard-interactive)' \
    <<<"$ssh_log" || true)
printf '%s成功登录记录：%s\n' "$bold" "$reset"
if [[ -n $accepted_lines ]]; then
    printf '%s\n' "$accepted_lines" | indent
else
    printf '    没有从 journal 中读到 Accepted 记录。\n'
fi

accepted_ips=$(awk '
    /Accepted / {
        for (i=1; i<=NF; i++) if ($i=="from") print $(i+1)
    }
' <<<"$accepted_lines" | sort -u)
if [[ $ssh_log_rc != 0 ]]; then
    fail '无法读取本次启动的 SSH 日志，不能确认登录来源'
elif [[ -z ${current_ip:-} ]]; then
    warn '当前环境没有 SSH_CONNECTION，无法自动判断你的来源 IP'
elif [[ -z $accepted_ips ]]; then
    warn '没有可比较的 SSH 成功登录记录'
else
    unexpected_accepted=$(awk -v own="$current_ip" '$0 != own' <<<"$accepted_ips")
    if [[ -z $unexpected_accepted ]]; then
        pass "本次启动可读取的 SSH 成功记录均来自当前 IP：$current_ip（不是无后门证明）"
    else
        fail "发现其他 IP 成功登录：$(tr '\n' ' ' <<<"$unexpected_accepted")"
    fi
fi

failed_auth_count=$(grep -Ec \
    'Failed password|Invalid user|authentication failure' \
    <<<"$ssh_log" || true)
value '失败/无效认证' "$failed_auth_count 次（扫描噪音不判失败）"
if (( failed_auth_count > 0 )); then
    grep -E 'Failed password|Invalid user|authentication failure' \
        <<<"$ssh_log" | tail -n 10 | indent
fi

section '账户、安装残留与最小化状态'
login_accounts=$(awk -F: '
    $3==0 || $7 !~ /\/(nologin|false|sync|shutdown|halt)$/ {
        print $1 ":uid=" $3 ":shell=" $7
    }
' /etc/passwd)
value '可交互账户' "$login_accounts"
if [[ $login_accounts == root:uid=0:* && $login_accounts != *$'\n'* ]]; then
    pass '只有 root 具有交互登录 shell'
else
    fail '发现 root 以外的交互登录账户'
fi

if [[ -s /root/.ssh/authorized_keys ]]; then
    key_fingerprints=$(ssh-keygen -lf /root/.ssh/authorized_keys 2>/dev/null || true)
    if [[ -n $key_fingerprints ]]; then
        warn 'root authorized_keys 可以解析，但是否属于你只能由你核对指纹'
        printf '%s\n' "$key_fingerprints" | indent
    else
        fail 'root authorized_keys 存在但无法解析'
    fi
else
    if [[ $password_auth_value == no ]]; then
        fail '密码登录已关闭，但 root authorized_keys 为空，可能导致无法再次登录'
    else
        pass '首次初始化阶段尚未写入 root authorized_keys'
    fi
fi

residual_paths=(
    /.debian-installer-swap
    /var/log/installer
    /var/log/bootstrap.log
    /var/log/debian-reinstall-late.error
    /var/log/debian-reinstall-partman.error
    /usr/local/lib/debian-reinstall/fix-eth-name.sh
    /usr/local/lib/debian-reinstall/fix-console.sh
    /etc/systemd/system/fix-eth-name.service
    /etc/systemd/system/fix-console.service
    /etc/systemd/system/multi-user.target.wants/fix-eth-name.service
    /etc/systemd/system/multi-user.target.wants/fix-console.service
    /etc/apt/preferences.d/99-debian-reinstall-block-extras
    /var/log/debian-reinstall-network-repair.error
    /var/log/debian-reinstall-console-repair.error
    /var/log/debian-reinstall-packages.error
    /etc/rc.local
    /etc/cloud
    /var/lib/cloud
    /var/lib/waagent
    /opt/google
    /var/lib/google
    /opt/oracle-cloud-agent
    /usr/local/qcloud
    /usr/local/agenttools
    /usr/local/aegis
    /opt/aliyun
)
residual_found=()
for path in "${residual_paths[@]}"; do
    if [[ -e $path || -L $path ]]; then
        residual_found+=("$path")
    fi
done
if (( ${#residual_found[@]} == 0 )); then
    pass '没有安装器临时文件、服务、错误标记或 APT pin 残留'
else
    fail "发现安装残留：${residual_found[*]}"
fi

swap_state=$(swapon --show --noheadings 2>&1)
if [[ $? != 0 ]]; then
    fail "无法读取 swap 状态：$swap_state"
elif [[ -z $swap_state ]] &&
    ! grep -Eq '^[^#]+[[:space:]]+[^[:space:]]+[[:space:]]+swap([[:space:]]|$)' \
    /etc/fstab; then
    pass '没有活动或持久化 swap'
else
    fail '发现活动 swap 或 fstab swap 项'
    swapon --show | indent || true
fi

blocked_packages=(
    qemu-guest-agent popularity-contest installation-report os-prober
    discover discover-data laptop-detect mouseemu xauth
    cloud-init cloud-initramfs-growroot walinuxagent waagent
    google-guest-agent google-compute-engine-oslogin amazon-ssm-agent
    oracle-cloud-agent open-vm-tools xe-guest-utilities
    aliyun-assist aliyun-service tat-agent
)
installed_blocked=()
package_inventory=$(dpkg-query -W -f='${Package}\t${db:Status-Status}\n' 2>/dev/null)
inventory_rc=$?
for package in "${blocked_packages[@]}"; do
    if awk -F '\t' -v wanted="$package" \
        '$1==wanted && $2!="not-installed" {found=1} END {exit found ? 0 : 1}' <<<"$package_inventory"; then
        installed_blocked+=("$package")
    fi
done
if [[ $inventory_rc != 0 || -z $package_inventory ]]; then
    fail '无法读取软件包清单，不能确认禁止的可选包未安装'
elif (( ${#installed_blocked[@]} == 0 )); then
    pass '禁止的可选包均未安装'
else
    fail "发现不应安装的可选包：${installed_blocked[*]}"
fi

root_crontab=$(LC_ALL=C crontab -l -u root 2>&1)
crontab_rc=$?
if [[ $crontab_rc == 1 && $root_crontab == 'no crontab for root' ]] ||
    [[ $crontab_rc == 0 && -z $root_crontab ]]; then
    pass 'root 没有额外的用户 crontab'
elif [[ $crontab_rc != 0 ]]; then
    fail "无法读取 root crontab：$root_crontab"
else
    fail 'root 存在用户 crontab，请确认是否为预期持久化任务'
    printf '%s\n' "$root_crontab" | indent
fi

custom_units=$(find /etc/systemd/system -type f -print 2>/dev/null)
if [[ $? != 0 ]]; then
    fail '无法扫描本地 systemd 服务目录'
elif [[ -z $custom_units ]]; then
    pass '/etc/systemd/system 没有厂商自定义服务文件'
else
    fail '发现本地自定义 systemd 服务文件'
    printf '%s\n' "$custom_units" | indent
fi

local_executables=$(find /usr/local/bin /usr/local/sbin -mindepth 1 -maxdepth 1 \
    -type f -print 2>/dev/null)
if [[ $? != 0 ]]; then
    fail '无法扫描 /usr/local 程序目录'
elif [[ -z $local_executables ]]; then
    pass '/usr/local/bin 与 /usr/local/sbin 没有额外程序'
else
    fail '发现非 Debian 软件包路径中的本地程序'
    printf '%s\n' "$local_executables" | indent
fi

sources=/etc/apt/sources.list.d/debian.sources
nonempty_source_files=$(find /etc/apt/sources.list.d -maxdepth 1 -type f -size +0c \
    -print 2>/dev/null || true)
if [[ -s $sources ]] && valid_debian_sources "$sources" &&
    [[ ! -s /etc/apt/sources.list ]] &&
    [[ $nonempty_source_files == "$sources" ]] &&
    [[ $(grep -Fxc 'Types: deb' "$sources") == 2 ]] &&
    [[ $(grep -Fxc 'Components: main' "$sources") == 2 ]]; then
    pass 'APT 仅使用预期的 Debian HTTPS 源'
else
    fail 'APT 源不符合预期'
fi

if valid_public_dns /etc/resolv.conf; then
    pass 'DNS 仅包含约定的公共解析器'
else
    fail 'DNS 为空、无法读取，或包含约定之外的解析器'
fi

section '本次启动的高优先级日志'
kernel_log=$(journalctl -k -b --no-pager -o cat 2>/dev/null)
kernel_log_rc=$?
kernel_critical=$(grep -Ei \
    'kernel panic|BUG:|Oops:|Out of memory:|oom-kill|Buffer I/O error|I/O error, dev|EXT4-fs error|Remounting filesystem read-only' <<<"$kernel_log" || true)
kernel_suspicious=$(grep -Ei \
    'Call Trace:|blocked for more than [0-9]+ seconds|nvme.*(timeout|reset)|segfault at' <<<"$kernel_log" || true)
if [[ $kernel_log_rc != 0 || -z $kernel_log || $kernel_log == '-- No entries --' ]]; then
    fail '内核日志不可读或为空，不能据此报告没有严重错误'
elif [[ -z $kernel_critical ]]; then
    pass '内核日志没有 panic、OOM、I/O 或 EXT4 严重错误'
else
    fail '内核日志发现严重错误'
    printf '%s\n' "$kernel_critical" | tail -n 20 | indent
fi
if [[ $kernel_log_rc == 0 && -n $kernel_log && $kernel_log != '-- No entries --' && -z $kernel_suspicious ]]; then
    pass '内核日志没有超时、重置、Call Trace 或段错误迹象'
else
    warn '内核日志发现需要人工确认的异常迹象'
    printf '%s\n' "$kernel_suspicious" | tail -n 20 | indent
fi

boot_errors=$(journalctl -b -p err..alert --no-pager --no-hostname \
    -o short-monotonic 2>/dev/null)
boot_errors_rc=$?
actionable_boot_errors=$boot_errors
agetty_errors=$(grep -E 'agetty.*failed to get terminal attributes: Input/output error' \
    <<<"$actionable_boot_errors" || true)
non_agetty_errors=$(grep -Ev 'agetty.*failed to get terminal attributes: Input/output error' \
    <<<"$actionable_boot_errors" || true)
if [[ $boot_errors_rc != 0 ]]; then
    fail '无法读取本次启动的高优先级日志'
elif [[ -z $actionable_boot_errors || $actionable_boot_errors == '-- No entries --' ]]; then
    pass '本次启动没有需要处理的 error 及以上日志'
elif [[ -n $agetty_errors && -z $non_agetty_errors ]]; then
    warn '本次启动出现过 agetty 错误；是否仍在重试请以上面的实时状态与计数为准'
    printf '%s\n' "$agetty_errors" | tail -n 5 | indent
    for getty_unit in getty@tty1.service serial-getty@ttyS0.service \
        serial-getty@ttyAMA0.service; do
        if journalctl -b -u "$getty_unit" --no-pager 2>/dev/null |
            grep -Fq 'failed to get terminal attributes: Input/output error'; then
            getty_restarts=$(systemctl show "$getty_unit" -p NRestarts --value \
                2>/dev/null || true)
            printf '    受影响单元：%s（本次启动重启 %s 次）\n' \
                "$getty_unit" "${getty_restarts:-未知}"
        fi
    done
else
    warn '本次启动存在 error 及以上日志，请人工判断是否为虚拟硬件噪音'
    printf '%s\n' "$actionable_boot_errors" | tail -n 20 | indent
fi

section '正常运行的服务（信息）'
systemctl --type=service --state=running --no-legend --no-pager |
    sed -E 's/^[[:space:]]*/    /' || true

printf '\n%s╭──────────────── 最终结论 ─────────────────╮%s\n' "$bold" "$reset"
printf '%s│%s  %sPASS %-3d%s   %sWARN %-3d%s   %sFAIL %-3d%s             %s│%s\n' \
    "$bold" "$reset" "$green" "$pass_count" "$reset" \
    "$yellow" "$warn_count" "$reset" "$red" "$fail_count" "$reset" \
    "$bold" "$reset"
printf '%s╰────────────────────────────────────────────╯%s\n' "$bold" "$reset"

if (( fail_count > 0 )); then
    printf '%s✗ 暂时不要安装软件或修改关键配置。先处理上面的 FAIL。%s\n' \
        "$red" "$reset"
    exit 1
elif (( warn_count > 0 )); then
    printf '%s✓ 启动与操作就绪检查通过；仍有 WARN 需要核对。%s\n' "$green" "$reset"
    printf '%s  确认警告不涉及当前操作后，可安装软件和修改配置。%s\n' "$yellow" "$reset"
    exit 0
else
    printf '%s✓ 本次检查通过：系统已启动，软件包管理器和网络已就绪。%s\n' \
        "$green" "$reset"
    printf '%s✓ 可以进行安装和配置；短时检查不保证长期稳定或绝对无后门。%s\n' "$green" "$reset"
    exit 0
fi
