#!/bin/sh
# shellcheck shell=ash
# SPDX-License-Identifier: GPL-3.0-or-later
# Read-only acceptance of this project's minimal Alpine ECS installation.
set -u
set -o pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C
umask 077
SELF_SHA256=2476e2ea77c4ef88f881a3aae4e2b0ec01037498a6823f3dd6c19057ae63761f
REPOSITORY=https://dl-cdn.alpinelinux.org/alpine/v3.24/main
passed=0; failed=0; warned=0; work=; ntp_pid=
port=; observe=60; offline=no; before=; after=
root_device=; root_uuid=; host_key=; boot_id=
ui_green=; ui_red=; ui_yellow=; ui_cyan=; ui_bold=; ui_reset=

fatal() { printf 'ERROR: %s\n' "$*" >&2; exit 3; }
init_display() {
    ui_green=; ui_red=; ui_yellow=; ui_cyan=; ui_bold=; ui_reset=
    # No extra terminal tools; redirected reports and NO_COLOR stay plain text.
    if [ -t 1 ] && [ "${TERM:-dumb}" != dumb ] && [ -z "${NO_COLOR+x}" ]; then
        ui_green=$(printf '\033[32m'); ui_red=$(printf '\033[31m')
        ui_yellow=$(printf '\033[33m'); ui_cyan=$(printf '\033[36m')
        ui_bold=$(printf '\033[1m'); ui_reset=$(printf '\033[0m')
    fi
}
render_row() {
    case "$1" in PASS) ui_tint=$ui_green ;; FAIL) ui_tint=$ui_red ;; WARN) ui_tint=$ui_yellow ;; *) ui_tint=$ui_cyan ;; esac
    printf '%s[%s]%s %-15s %s\n' "$ui_tint" "$1" "$ui_reset" "$2:" "$3"
}
report() {
    case "$1" in PASS) passed=$((passed + 1)) ;; FAIL) failed=$((failed + 1)) ;; WARN) warned=$((warned + 1)) ;; esac
    # File names and command output are data, never terminal control sequences.
    ui_detail=$(printf '%s' "$3" | tr '\r\n\t' '   ' | tr -d '\000-\010\013-\037\177')
    render_row "$1" "$2" "$ui_detail"
    case "$1" in FAIL|WARN)
        if [ -n "$work" ]; then
            printf '%s\t%s\t%s\n' "$1" "$2" "$ui_detail" >>"$work/issues" || fatal '无法保存验收问题摘要。'
        fi ;;
    esac
}
pass() { report PASS "$1" "$2"; }
fail() { report FAIL "$1" "$2"; }
warn() { report WARN "$1" "$2"; }
note() { report INFO "$1" "$2"; }
display_header() {
    printf '\n%s============================================================%s\n' "$ui_cyan" "$ui_reset"
    printf '%s  ALPINE ECS  /  重装后验收%s\n' "$ui_bold" "$ui_reset"
    printf '  系统时间（UTC） %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S')"
    if [ "$offline" = yes ]; then ui_mode='离线检查'; else ui_mode='在线检查'; fi
    printf '  %s  |  观察 %s 秒  |  SSH 端口 %s\n' "$ui_mode" "$observe" "${port:-读取当前配置}"
    printf '  %sPASS 通过%s   %sFAIL 失败%s   %sWARN 待核实%s\n' "$ui_green" "$ui_reset" "$ui_red" "$ui_reset" "$ui_yellow" "$ui_reset"
    printf '%s============================================================%s\n' "$ui_cyan" "$ui_reset"
}
section() {
    printf '\n%s%s[%s/08] %s%s\n' "$ui_bold" "$ui_cyan" "$1" "$2" "$ui_reset"
    printf '%s------------------------------------------------------------%s\n' "$ui_cyan" "$ui_reset"
}
display_progress() {
    ui_step=$(( $1 * 20 / $2 ))
    [ "$ui_step" -le 20 ] || ui_step=20
    ui_bar=; ui_index=0
    while [ "$ui_index" -lt 20 ]; do
        if [ "$ui_index" -lt "$ui_step" ]; then ui_bar=${ui_bar}'#'; else ui_bar=${ui_bar}'-'; fi
        ui_index=$((ui_index + 1))
    done
    printf '       %s[%s]%s  观察 %s / %s 秒\n' "$ui_cyan" "$ui_bar" "$ui_reset" "$1" "$2"
}
display_summary() {
    printf '\n%s============================================================%s\n' "$ui_cyan" "$ui_reset"
    if [ "$failed" -ne 0 ]; then
        printf '%s%s  FAIL  /  发现未通过项目%s\n' "$ui_bold" "$ui_red" "$ui_reset"
    elif [ "$warned" -ne 0 ]; then
        printf '%s%s  WARN  /  尚有待核实项目%s\n' "$ui_bold" "$ui_yellow" "$ui_reset"
    else
        printf '%s%s  PASS  /  本次检查通过%s\n' "$ui_bold" "$ui_green" "$ui_reset"
    fi
    printf '  %sPASS=%s%s   %sFAIL=%s%s   %sWARN=%s%s\n' "$ui_green" "$passed" "$ui_reset" "$ui_red" "$failed" "$ui_reset" "$ui_yellow" "$warned" "$ui_reset"
    printf '%s============================================================%s\n' "$ui_cyan" "$ui_reset"
    if [ "$failed" -ne 0 ] || [ "$warned" -ne 0 ]; then
        printf '\n%s需要关注（先失败，后待核实）%s\n' "$ui_bold" "$ui_reset"
        for ui_level in FAIL WARN; do
            while IFS="$(printf '\t')" read -r ui_kind ui_id ui_text; do
                [ "$ui_kind" != "$ui_level" ] || render_row "$ui_kind" "$ui_id" "$ui_text"
            done <"$work/issues"
        done
    fi
    printf '\n'
}
brief() { head -n 6 "$1" | tr '\n\r\t' '   ' | cut -c 1-600; }
stop_probe() {
    if [ -n "$ntp_pid" ]; then
        kill "$ntp_pid" 2>/dev/null || :
        wait "$ntp_pid" 2>/dev/null || :
        ntp_pid=
    fi
}
# shellcheck disable=SC2329 # Invoked through the EXIT trap.
cleanup() { stop_probe; [ -z "$work" ] || rm -rf "$work"; }
usage() {
    cat <<'EOF'
在重装后的 Alpine 中以 root 运行；只需本文件，不安装额外软件。
  sh verify-alpine.sh --ssh-port 2222
  sh verify-alpine.sh --ssh-port 2222 --before-reboot /root/alpine-acceptance.before
  # 你自行重启并重新登录 SSH 后：
  sh verify-alpine.sh --ssh-port 2222 --after-reboot /root/alpine-acceptance.before

选项：
  --ssh-port PORT          预期 SSH 端口；省略时读取当前 sshd 配置
  --observe-seconds N      轻量观察 10..600 秒，默认 60 秒
  --offline               跳过主动 DNS / HTTPS / NTP 查询，报告为未验证
  --before-reboot FILE     检查无 FAIL 后保存基线；文件必须尚不存在
  --after-reboot FILE      校验基线并确认 boot ID 已改变、根 UUID 和主机密钥保留

不修改系统配置、安装包、分区或时钟；不重启、重启服务或触发 DHCP 续租。
临时文件只写入 /run 下的私有目录并自动清理；基线文件仅按上述选项保存。
在线模式只查询官方 Alpine 仓库和三个已配置的阿里云 VPC 时间源。
退出码：0 本次检查通过；1 有失败；2 有待核实项；3 无法执行或参数错误。
执行前请用独立取得的完整文件 SHA-256 核对本文件。
终端自动使用绿色 PASS、红色 FAIL、黄色 WARN；重定向或设置 NO_COLOR 时为纯文本。
EOF
}
valid_port() {
    case "$1" in ''|0*|*[!0-9]*) return 1 ;; esac
    [ "${#1}" -le 5 ] && [ "$1" -le 65535 ]
}
verify_self() {
    [ "${0##*/}" = verify-alpine.sh ] && [ -f "$0" ] && [ ! -L "$0" ] || fatal '请直接运行原名 verify-alpine.sh，不能通过管道或符号链接运行。'
    actual=$(sed 's/^SELF_SHA256=[0-9a-f]*$/SELF_SHA256=/' "$0" | sha256sum | cut -d ' ' -f 1)
    [ "$actual" = "$SELF_SHA256" ] || fatal '脚本内容校验失败；请重新取得并校验完整文件。'
}
platform() {
    if grep -Eiq 'Alibaba Cloud|Aliyun' /sys/class/dmi/id/sys_vendor /sys/class/dmi/id/product_name 2>/dev/null; then
        pass ECS 'DMI 识别为阿里云。'
    else fail ECS 'DMI 与本脚本针对的阿里云环境不符。'; fi
    if [ ! -d /sys/firmware/efi ] && grep -q '^3\.24\.' /etc/alpine-release && [ "$(uname -r | sed 's/.*-//')" = virt ]; then
        pass PLATFORM "Alpine $(cat /etc/alpine-release)，BIOS，$(uname -r)。"
    else fail PLATFORM '预期 Alpine 3.24、BIOS 和 virt 内核。'; fi
    cpus=$(grep -c '^processor' /proc/cpuinfo)
    ram=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
    if [ "$cpus" -eq 2 ] && [ "$ram" -ge 409600 ]; then
        pass CAPACITY "${cpus} vCPU，内核可用总内存 $((ram / 1024)) MiB。"
    else warn CAPACITY "检测到 ${cpus} vCPU / $((ram / 1024)) MiB，与预期规格核对。"; fi
    boot_id=$(cat /proc/sys/kernel/random/boot_id)
}
packages() {
    printf '%s\n' alpine-base linux-virt openssh-server openssh-server-common-openrc syslinux e2fsprogs ca-certificates-bundle | sort >"$work/world.expected"
    sort /etc/apk/world >"$work/world.actual"
    if cmp -s "$work/world.expected" "$work/world.actual"; then
        pass WORLD '显式包清单符合七项最小安装基线。'
    else fail WORLD "显式包清单偏离新装基线：$(brief "$work/world.actual")"; fi
    missing=
    while IFS= read -r pkg; do
        apk --no-network --no-logfile --repositories-file /dev/null info -e "$pkg" >/dev/null 2>&1 || missing="$missing $pkg"
    done <"$work/world.expected"
    if [ -z "$missing" ]; then pass PACKAGES '必要软件包均已安装。'; else fail PACKAGES "缺少：$missing"; fi
    if ! apk --no-network --no-logfile --repositories-file /dev/null info >"$work/packages" 2>"$work/packages.err"; then
        fail PACKAGE_DB "无法读取包数据库：$(brief "$work/packages.err")"; return
    fi
    if grep -Ei '^(cloud-init|tiny-cloud|aliyun|aegis|cloudmonitor|openssh-client|openssh-sftp|openssh-server-pam|openssh-server-krb5|xauth|xorg|xserver|sfdisk|wipefs|curl)(-|$)' "$work/packages" >"$work/extra-packages"; then
        fail MINIMAL "发现基线外的云代理、客户端或安装工具包：$(brief "$work/extra-packages")"
    else pass MINIMAL '未发现列出的云代理、X11、SSH 客户端、SFTP 或安装工具包。'; fi
    if [ "$(cat /etc/apk/repositories)" = "$REPOSITORY" ] && ! find /etc/apk/repositories.d /lib/apk/repositories.d -type f -name '*.list' 2>/dev/null | grep -q .; then
        pass REPOSITORY '仅配置固定的 Alpine 官方 main 仓库。'
    else fail REPOSITORY '软件源不是唯一指定的官方仓库，或存在额外仓库列表。'; fi
    # No protected-path exceptions for package-owned code, service scripts and keys.
    if apk --no-network --no-logfile --repositories-file /dev/null --no-progress audit --system --recursive --check-permissions --protected-paths /dev/null \
        /bin /sbin /usr/bin /usr/sbin /lib /usr/lib /etc/init.d /etc/ssl >"$work/audit" 2>"$work/audit.err"; then
        if [ ! -s "$work/audit" ] && [ ! -s "$work/audit.err" ]; then
            pass FILES '程序、库、服务脚本及 CA 文件与本机包数据库一致。'
        else fail FILES "包文件或权限存在差异：$(brief "$work/audit") $(brief "$work/audit.err")"; fi
    else fail FILES "无法完成包文件审计：$(brief "$work/audit.err")"; fi
    # This installer copies public keys with umask 077; root:0600 is intentional.
    bad=no
    for key in /etc/apk/keys/*; do
        mode=$(stat -c '%u:%a' "$key")
        [ -f "$key" ] && [ ! -L "$key" ] && { [ "$mode" = 0:600 ] || [ "$mode" = 0:644 ]; } || bad=yes
    done
    if apk --no-network --no-logfile --repositories-file /dev/null --no-progress audit --full --recursive --protected-paths /dev/null /etc/apk/keys >"$work/keys" 2>"$work/keys.err" && [ ! -s "$work/keys" ] && [ ! -s "$work/keys.err" ] && [ "$bad" = no ]; then
        pass APK_KEYS 'APK 公钥内容符合包数据库；权限为 root:0600 或 root:0644。'
    else fail APK_KEYS "APK 公钥内容、数量或权限不符：$(brief "$work/keys") $(brief "$work/keys.err")"; fi
    set -- /bin /sbin /usr/bin /usr/sbin
    for extra in /usr/local/bin /usr/local/sbin; do [ ! -d "$extra" ] || set -- "$@" "$extra"; done
    if apk --no-network --no-logfile --repositories-file /dev/null --no-progress audit --full --recursive --ignore-busybox-symlinks \
        "$@" >"$work/added" 2>"$work/added.err"; then
        if grep -E '^[AdD] ' "$work/added" >"$work/unowned"; then
            warn ADDED "程序目录有包数据库外的文件，需核对来源：$(brief "$work/unowned")"
        else pass ADDED '已检查程序目录中新增的非包文件。'; fi
    else warn ADDED "无法完成新增文件检查：$(brief "$work/added.err")"; fi
    if apk --no-network --no-logfile --repositories-file /dev/null --no-progress audit --full --recursive --check-permissions --protected-paths /dev/null \
        /etc/crontabs /etc/periodic /etc/local.d /etc/init.d >"$work/startup" 2>"$work/startup.err"; then
        if [ -s "$work/startup" ]; then fail STARTUP "启动脚本或计划任务偏离包基线：$(brief "$work/startup")";
        else pass STARTUP '启动脚本和计划任务未发现包基线外的改动。'; fi
    else fail STARTUP "无法检查启动脚本和计划任务：$(brief "$work/startup.err")"; fi
    note TRUST '包文件审计以本机 APK 数据库为依据；不把它等同于独立来源认证。'
}
storage() {
    mm=$(awk '$5 == "/" {print $3}' /proc/self/mountinfo)
    node=$(readlink -f "/sys/dev/block/$mm")
    if [ ! -f "$node/partition" ]; then fail ROOT '根目录不是普通磁盘分区。'; return; fi
    root_device=/dev/${node##*/}
    disk_node=$(dirname "$node")
    disk=/dev/${disk_node##*/}
    if awk '$2 == "/" && $3 == "ext4" && $4 ~ /(^|,)rw(,|$)/ {ok=1} END {exit !ok}' /proc/mounts; then
        pass ROOT "$root_device，ext4，当前以读写方式挂载。"
    else fail ROOT '根文件系统不是可读写的 ext4。'; fi
    count=0
    for entry in "$disk_node"/*; do [ ! -f "$entry/partition" ] || count=$((count + 1)); done
    if [ "$count" -eq 1 ] && [ "$(cat "$node/start")" = 2048 ] && [ "$(wc -l </proc/swaps)" -eq 1 ]; then
        pass LAYOUT '系统盘为单根分区、1 MiB 对齐，无活动交换空间。'
    else fail LAYOUT '分区布局或活动交换空间偏离安装基线。'; fi
    root_uuid=$(blkid "$root_device" | sed -n 's/.* UUID="\([^"]*\)".*/\1/p')
    if [ -n "$root_uuid" ] && awk -v id="UUID=$root_uuid" '$1 == id && $2 == "/" && $3 == "ext4" && $6 == 1 {ok=1} END {exit !ok}' /etc/fstab; then
        pass FSTAB '根目录按正确 UUID 挂载，启动检查顺序为 1。'
    else fail FSTAB 'fstab 的根 UUID、类型或检查顺序不符。'; fi
    errors=/sys/fs/ext4/${root_device##*/}/errors_count
    if [ -r "$errors" ]; then
        if [ "$(cat "$errors")" -eq 0 ]; then pass EXT4 'ext4 错误计数为 0。'; else fail EXT4 'ext4 已记录错误。'; fi
    else warn EXT4 '无法读取 ext4 错误计数。'; fi
    journal=no
    for info in /proc/fs/jbd2/"${root_device##*/}"-*/info; do [ ! -r "$info" ] || journal=yes; done
    if [ "$journal" = yes ] && [ -r "/sys/fs/ext4/${root_device##*/}/journal_task" ]; then
        pass JOURNAL '内核为根分区提供活动的 JBD2 日志状态。'
    else fail JOURNAL '无法确认根分区的活动日志状态。'; fi
    free_kb=$(df -Pk / | awk 'END {print $4}')
    inode_pct=$(df -Pi / | awk 'END {gsub(/%/, "", $5); print $5}')
    if [ "$free_kb" -lt 65536 ] || [ "$inode_pct" -ge 95 ]; then
        fail SPACE "剩余 $((free_kb / 1024)) MiB；inode 已用 ${inode_pct}%。"
    elif [ "$free_kb" -lt 131072 ] || [ "$inode_pct" -ge 90 ]; then
        warn SPACE "剩余 $((free_kb / 1024)) MiB；inode 已用 ${inode_pct}%，余量偏小。"
    else pass SPACE "剩余 $((free_kb / 1024)) MiB；inode 已用 ${inode_pct}%。"; fi
    expected=$(dd if=/dev/zero bs=512 count=2047 2>/dev/null | sha256sum | cut -d ' ' -f 1)
    actual=$(dd if="$disk" bs=512 skip=1 count=2047 2>/dev/null | sha256sum | cut -d ' ' -f 1)
    if [ "$actual" = "$expected" ]; then pass BOOT_GAP 'MBR 后至 1 MiB 的引导保留区仍为空。'; else fail BOOT_GAP '引导保留区与重装后的空白基线不同。'; fi
    if [ -f /usr/share/syslinux/mbr.bin ]; then
        expected=$(dd if=/usr/share/syslinux/mbr.bin bs=440 count=1 2>/dev/null | sha256sum | cut -d ' ' -f 1)
        actual=$(dd if="$disk" bs=440 count=1 2>/dev/null | sha256sum | cut -d ' ' -f 1)
        if [ "$actual" = "$expected" ]; then pass MBR 'MBR 引导代码与当前官方 Syslinux 文件一致。'; else fail MBR 'MBR 引导代码不匹配。'; fi
    else fail MBR '缺少用于比较的官方 Syslinux MBR 文件。'; fi
    note FSCK '运行中的根分区只检查状态和错误记录；不在已挂载分区上运行 fsck。'
}
boot_files() {
    bad=no
    for file in /boot/vmlinuz-virt /boot/initramfs-virt /boot/extlinux.conf /boot/ldlinux.sys; do
        [ -s "$file" ] || bad=yes
    done
    if [ "$bad" = no ] && [ -n "$root_uuid" ] && grep -Fq "root=UUID=$root_uuid" /boot/extlinux.conf; then
        pass BOOT_FILES '内核、initramfs、Syslinux 文件及根 UUID 配置齐全。'
    else fail BOOT_FILES '启动文件缺失、为空或根 UUID 不匹配。'; fi
    if gzip -dc /boot/initramfs-virt 2>"$work/initramfs.err" | cpio -t >"$work/initramfs.list" 2>>"$work/initramfs.err"; then
        if grep -Fq "lib/modules/$(uname -r)/" "$work/initramfs.list"; then
            pass INITRAMFS '压缩包可完整读取，包含当前内核的模块目录。'
        else warn INITRAMFS 'initramfs 与运行内核的版本可能不同；若刚更新过内核，应重启复验。'; fi
    else fail INITRAMFS "启动内存盘不可完整读取：$(brief "$work/initramfs.err")"; fi
    if grep -Eq '(^|[[:space:]])root=UUID=' /proc/cmdline && grep -q 'net.ifnames=0' /proc/cmdline && grep -q 'console=ttyS0,115200' /proc/cmdline; then
        pass CMDLINE '本次启动使用 UUID、固定网卡命名和串口参数。'
    else fail CMDLINE '当前内核启动参数偏离基线。'; fi
}
services() {
    bad=
    for item in sysinit:devfs sysinit:dmesg sysinit:mdev sysinit:hwdrivers boot:modules boot:sysctl boot:hostname boot:bootmisc boot:syslog boot:networking boot:seedrng boot:hwclock default:sshd default:crond default:ntpd shutdown:killprocs shutdown:mount-ro; do
        level=${item%%:*}; svc=${item#*:}
        [ -e "/etc/runlevels/$level/$svc" ] || bad="$bad $item"
    done
    if [ -z "$bad" ]; then pass AUTOSTART '必要 OpenRC 启动和关机服务均已启用。'; else fail AUTOSTART "缺少：$bad"; fi
    bad=
    for link in /etc/runlevels/*/*; do
        [ -e "$link" ] || continue
        item=${link#/etc/runlevels/}
        case "$item" in
            sysinit/devfs|sysinit/dmesg|sysinit/mdev|sysinit/hwdrivers|boot/modules|boot/sysctl|boot/hostname|boot/bootmisc|boot/syslog|boot/networking|boot/seedrng|boot/hwclock|default/sshd|default/crond|default/ntpd|default/acpid|shutdown/killprocs|shutdown/mount-ro) ;;
            *) bad="$bad $item" ;;
        esac
    done
    if [ -z "$bad" ]; then pass RUNLEVELS '没有额外启用的 OpenRC 服务。'; else warn RUNLEVELS "另有启用项，需核对：$bad"; fi
    bad=
    for svc in sshd networking ntpd syslog crond; do
        timeout 5 rc-service -q "$svc" status >/dev/null 2>&1 || bad="$bad $svc"
    done
    if [ -z "$bad" ]; then pass SERVICES 'SSH、网络、NTP、日志和计划任务服务运行正常。'; else fail SERVICES "未运行：$bad"; fi
    rc-status --crashed >"$work/crashed" 2>"$work/crashed.err" || :
    if [ -s "$work/crashed.err" ]; then warn OPENRC "无法读取崩溃状态：$(brief "$work/crashed.err")"
    elif [ -s "$work/crashed" ]; then fail OPENRC "崩溃的服务：$(brief "$work/crashed")"
    else pass OPENRC 'OpenRC 未报告崩溃服务。'; fi
    if grep -qx 'Power Button' /sys/class/input/input*/name 2>/dev/null; then
        if [ -e /etc/runlevels/default/acpid ] && timeout 5 rc-service -q acpid status >/dev/null 2>&1; then
            pass ACPI '已检测到电源按钮，BusyBox acpid 已启用并运行。'
        else fail ACPI '存在电源按钮，但 acpid 未正常启用。'; fi
    else note ACPI '未检测到电源按钮；不强制要求 acpid。'; fi
    if [ -s /var/lib/seedrng/seed.no-credit ] || [ -s /var/lib/seedrng/seed.credit ]; then
        pass RANDOM '存在随机种子持久化文件。'
    else warn RANDOM '未找到预期的随机种子文件，需核对 seedrng 状态。'; fi
}
ssh_checks() {
    if ! timeout 10 sshd -t >"$work/sshd.err" 2>&1 || ! timeout 10 sshd -T >"$work/sshd" 2>>"$work/sshd.err"; then
        fail SSH_CONFIG "sshd 配置或主机密钥检查失败：$(brief "$work/sshd.err")"; return
    fi
    if [ -z "$port" ]; then
        port=$(awk '$1 == "port" {print $2}' "$work/sshd")
        valid_port "$port" || { fail SSH_PORT '无法唯一确定 SSH 端口。'; port=0; return; }
        note SSH_PORT "自动读取端口 $port；如需核对预期值，请显式传入 --ssh-port。"
    fi
    bad=
    for setting in "port $port" 'addressfamily inet' 'permitrootlogin yes' 'passwordauthentication yes' 'pubkeyauthentication no' 'kbdinteractiveauthentication no' 'authenticationmethods password' 'permitemptypasswords no' 'disableforwarding yes' 'x11forwarding no' 'permittunnel no' 'permituserenvironment no' 'permituserrc no' 'allowusers root' 'usedns no' 'maxauthtries 3' 'maxsessions 2' 'maxstartups 3:30:10' 'logingracetime 30'; do
        grep -Fqx "$setting" "$work/sshd" || bad="$bad [$setting]"
    done
    if [ -z "$bad" ] && ! grep -q '^subsystem ' "$work/sshd" && [ "$(grep -c '^port ' "$work/sshd")" -eq 1 ]; then
        pass SSH_CONFIG "端口 $port，仅 root 密码登录；X11、转发、隧道和 SFTP 均未启用。"
    else fail SSH_CONFIG "SSH 有效配置偏离基线：$bad"; fi
    if grep -Eiq '^[[:space:]]*(Include|Match)[[:space:]]' /etc/ssh/sshd_config; then
        fail SSH_OVERRIDES '发现基线外的 Include 或 Match，不能仅凭默认上下文判断全部 SSH 策略。'
    else pass SSH_OVERRIDES '没有 Include 或 Match 分支覆盖 SSH 策略。'; fi
    if awk -F: '$1 == "root" && $2 ~ /^\$6\$/ {ok=1} END {exit !ok}' /etc/shadow && ! awk -F: '$3 == 0 && $1 != "root" {print $1}' /etc/passwd | grep -q .; then
        pass ACCOUNT 'root 密码为 SHA-512 哈希，未发现其他 UID 0 账号；不输出密码或哈希。'
    else fail ACCOUNT 'root 密码状态或 UID 0 账号不符。'; fi
    bad=no
    for key in /etc/ssh/ssh_host_*_key; do
        [ -f "$key" ] && [ ! -L "$key" ] && [ "$(stat -c '%u:%a' "$key")" = 0:600 ] || bad=yes
    done
    if [ "$bad" = no ] && ssh-keygen -y -P '' -f /etc/ssh/ssh_host_ed25519_key 2>/dev/null | awk '{print $1 " " $2}' >"$work/public-key"; then
        awk '{print $1 " " $2}' /etc/ssh/ssh_host_ed25519_key.pub >"$work/public-key.expected"
        if cmp -s "$work/public-key" "$work/public-key.expected"; then
            host_key=$(sha256sum "$work/public-key" | cut -d ' ' -f 1)
            pass HOST_KEYS '主机私钥权限为 root:0600，ED25519 公私钥配对正确。'
        else fail HOST_KEYS 'ED25519 公私钥不匹配。'; fi
    else fail HOST_KEYS '主机私钥缺失、权限不符或不可读取。'; fi
    shadow_mode=$(stat -c '%u:%a' /etc/shadow)
    if { [ "$shadow_mode" = 0:600 ] || [ "$shadow_mode" = 0:640 ]; } && [ "$(stat -c '%u:%a' /etc)" = 0:755 ] && [ "$(stat -c '%u:%a' /etc/network/interfaces)" = 0:644 ] && [ "$(stat -c '%u:%a' /etc/apk/repositories)" = 0:644 ]; then
        pass PERMISSIONS '关键系统目录与配置文件权限符合安装基线。'
    else fail PERMISSIONS '关键目录、shadow、网络或仓库配置权限异常。'; fi
    if [ -n "${SSH_CONNECTION:-}" ] && [ "$(printf '%s\n' "$SSH_CONNECTION" | awk '{print $4}')" = "$port" ]; then
        pass SSH_SESSION '当前 SSH 会话确实通过预期服务端端口连接；此项不模拟一次新密码认证。'
    else note SSH_SESSION '未识别到预期端口的当前 SSH 会话；外部访问与密码登录需由客户端确认。'; fi
}
residue() {
    found=
    for path in /etc/cloud /var/lib/cloud /usr/local/aegis /usr/local/cloudmonitor /usr/local/share/aliyun-assist /boot/grub /boot/alpine-reinstall /run/reinstall /etc/local.d/reinstall.start /root/old-system-marker /usr/bin/ssh /usr/bin/xauth; do
        if [ -e "$path" ] || [ -L "$path" ]; then found="$found $path"; fi
    done
    if [ -z "$found" ]; then pass RESIDUE '列出的旧云初始化、云代理、GRUB 和重装暂存路径均不存在。'; else fail RESIDUE "发现基线外路径：$found"; fi
    if [ -d /root/.ssh ] && find /root/.ssh -type f -print | grep -q .; then warn USER_SSH '发现 /root/.ssh 中的文件，需确认是重装后自行创建的内容。'; fi
    if find /var/cache/apk -type f -name '*.apk' -print | grep -q .; then warn CACHE '发现 APK 安装包缓存。'; else pass CACHE '没有遗留的 APK 安装包缓存。'; fi
}
network() {
    count=0
    for nic in /sys/class/net/*; do [ ! -e "$nic/device" ] || count=$((count + 1)); done
    if [ "$count" -eq 1 ] && [ -r /sys/class/net/eth0/carrier ] && [ "$(cat /sys/class/net/eth0/carrier)" = 1 ] && [ "$(ip -o -4 addr show dev eth0 scope global | wc -l)" -eq 1 ] && [ "$(ip -4 route show default | wc -l)" -eq 1 ] && ip -4 route show default | grep -q ' dev eth0 '; then
        pass NETWORK '单 eth0 链路正常，具有一个 IPv4 地址和默认路由。'
    else fail NETWORK '网卡、IPv4 地址、链路或默认路由不符合预期。'; fi
    printf 'auto lo\niface lo inet loopback\nauto eth0\niface eth0 inet dhcp\n' >"$work/network.expected"
    awk 'NF && $1 !~ /^#/ {$1=$1; print}' /etc/network/interfaces >"$work/network.actual"
    if cmp -s "$work/network.expected" "$work/network.actual" && pidof udhcpc >/dev/null; then
        pass DHCP '持久配置使用 DHCP，udhcpc 客户端存在。'
    else fail DHCP 'DHCP 持久配置或客户端缺失。'; fi
    if [ -z "$(ip -o -6 addr show scope global)" ]; then pass IPV4 '没有活动全局 IPv6 地址，符合本项目范围。'; else fail IPV4 '存在超出本项目范围的全局 IPv6 地址。'; fi
    if netstat -lntp >"$work/tcp" 2>"$work/tcp.err"; then
        if awk -v port="$port" '$1 ~ /^tcp/ {n++; if ($1 != "tcp" || $4 != "0.0.0.0:" port || $7 !~ /\/sshd/) bad=1} END {exit !(n == 1 && !bad)}' "$work/tcp"; then
            pass TCP "唯一 TCP 监听为 sshd 的 0.0.0.0:$port。"
        else fail TCP "TCP 监听偏离基线：$(brief "$work/tcp")"; fi
    else fail TCP '无法读取 TCP 监听状态。'; fi
    if netstat -lnup >"$work/udp" 2>"$work/udp.err"; then
        if awk '$1 ~ /^udp/ && $4 ~ /:123$/ {found=1} END {exit !found}' "$work/udp"; then
            fail NTP_SERVER '发现 UDP 123 监听；本项目不应提供 NTP 服务端。'
        else pass NTP_SERVER '未监听 NTP 服务端 UDP 123。'; fi
        if awk '$1 ~ /^udp/ && $NF !~ /\/(ntpd|udhcpc)$/ {print}' "$work/udp" >"$work/udp.extra" && [ -s "$work/udp.extra" ]; then
            warn UDP "存在需要核对的其他 UDP 套接字：$(brief "$work/udp.extra")"
        fi
    else warn UDP '无法读取 UDP 套接字。'; fi
    if [ "$offline" = yes ]; then warn ONLINE '离线模式跳过主动 DNS、HTTPS 和仓库签名验证。'; return; fi
    if timeout 12 nslookup dl-cdn.alpinelinux.org >"$work/dns" 2>&1; then pass DNS '可解析 Alpine 官方 CDN。'; else fail DNS "官方 CDN 解析失败：$(brief "$work/dns")"; fi
    # An empty database is created only in the private temporary root; no package is added.
    probe=$work/repository-probe
    mkdir -p "$probe/etc/apk/keys"
    if ! cp /etc/apk/keys/* "$probe/etc/apk/keys/"; then fail HTTPS '无法准备临时仓库检查。'; return; fi
    if apk --root "$probe" --initdb --no-network --no-cache --no-progress --no-logfile --repositories-file /dev/null add >"$work/repo.log" 2>&1 &&
        timeout 40 apk --root "$probe" --no-cache --no-progress --no-logfile --repositories-file /dev/null --repository "$REPOSITORY" --timeout 10 update >>"$work/repo.log" 2>&1; then
        pass HTTPS '官方仓库索引可下载，HTTPS 证书及 APK 索引签名校验通过；未安装软件包。'
    else fail HTTPS "官方仓库连接或验证失败：$(brief "$work/repo.log")"; fi
}
time_config() {
    if grep -qx 'clock="UTC"' /etc/conf.d/hwclock && grep -qx 'NTPD_OPTS="-N -p ntp.cloud.aliyuncs.com -p ntp7.cloud.aliyuncs.com -p ntp8.cloud.aliyuncs.com"' /etc/conf.d/ntpd; then
        pass TIME_CONFIG '硬件时钟配置为 UTC，NTP 配置为三个阿里云 VPC 时间源。'
    else fail TIME_CONFIG 'UTC 或 VPC 时间源配置与安装结果不符。'; fi
    if [ "$offline" = no ]; then
        # BusyBox -w explicitly never sets the clock and implies foreground mode.
        # No -l, -I, -S or -q: no NTP server, hooks, clock changes or daemonizing.
        busybox ntpd -w -d -p ntp.cloud.aliyuncs.com -p ntp7.cloud.aliyuncs.com -p ntp8.cloud.aliyuncs.com >"$work/ntp.log" 2>&1 &
        ntp_pid=$!
    fi
}
kernel_errors() {
    if dmesg >"$work/dmesg" 2>"$work/dmesg.err"; then
        if grep -Ei 'Out of memory:|oom-kill:|Killed process .*total-vm:|I/O error|Buffer I/O error|EXT4-fs (error|warning)|JBD2:.*(error|abort)|Kernel panic|BUG:|Oops:|soft lockup|hard LOCKUP|NETDEV WATCHDOG' "$work/dmesg" >"$work/kernel-errors"; then
            fail KERNEL "当前内核日志含明确错误，需处理：$(brief "$work/kernel-errors")"
        else pass KERNEL '当前可读取的启动日志中未发现列出的 OOM、磁盘、ext4、锁死或网卡超时错误。'; fi
    else warn KERNEL '无法读取内核日志。'; fi
}
ntp_result() {
    # Count only accepted replies with numeric offsets and a valid stratum.
    awk '/reply from/ {o=""; s=0; for(i=1;i<=NF;i++){if($i ~ /^offset:/){o=$i;sub(/^offset:/,"",o)} if($i ~ /^strat:/){s=$i;sub(/^strat:/,"",s)}} if(o ~ /^[+-]?[0-9]+\.[0-9]+$/ && s ~ /^[0-9]+$/ && (s+0)>=1 && (s+0)<=15){n++;v=o+0;if(v<0)v=-v;if(v>m)m=v}} END{if(n)printf "%d %.6f\n",n,m}' "$1" >"$work/offsets"
    if [ -s "$work/offsets" ]; then
        samples=$(awk '{print $1}' "$work/offsets"); offset=$(awk '{print $2}' "$work/offsets")
        if awk -v n="$offset" 'BEGIN {exit !(n <= 1)}'; then pass NTP_QUERY "收到 $samples 个有效时间响应，最大绝对偏差 ${offset} 秒。"
        elif awk -v n="$offset" 'BEGIN {exit !(n <= 5)}'; then warn NTP_QUERY "收到时间响应，最大绝对偏差 ${offset} 秒。"
        else fail NTP_QUERY "与 VPC 时间源偏差达到 ${offset} 秒。"; fi
    else warn NTP_QUERY '限时查询未取得有效 VPC 时间响应；本项未验证，不代表已同步。'; fi
}
clock_result() {
    status=$(awk '$1 == "status:" {print $2}' "$1")
    result=$(awk '$1 == "return" && $2 == "value:" {print $3}' "$1")
    case "$status" in ''|*[!0-9]*) warn CLOCK '无法解析内核时钟同步状态。'; return ;; esac
    case "$result" in 0|1|2|3|4|5) ;; *) warn CLOCK '内核时钟查询结果不完整。'; return ;; esac
    if [ "$((status & 4160))" -eq 0 ] && [ "$result" -ne 5 ]; then
        pass CLOCK '内核没有标记 UNSYNC 或 CLOCKERR。'
    else warn CLOCK '内核仍标记时钟未同步或存在时钟错误；服务存在不能代替同步完成。'; fi
}
observe_system() {
    start=$(awk '{print int($1)}' /proc/uptime)
    min_mem=999999999; bad=; changes=no
    ip -4 route show default >"$work/route.before"
    initial_pid=$(cat /run/sshd.pid 2>/dev/null)
    note OBSERVE "轻量观察 ${observe} 秒；不做压力测试，也不主动续租或重启服务。"
    while :; do
        now=$(awk '{print int($1)}' /proc/uptime)
        elapsed=$((now - start))
        available=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
        [ "$available" -ge "$min_mem" ] || min_mem=$available
        [ "$(cat /sys/class/net/eth0/carrier 2>/dev/null)" = 1 ] || bad="$bad link"
        awk '$2 == "/" && $4 ~ /(^|,)rw(,|$)/ {ok=1} END {exit !ok}' /proc/mounts || bad="$bad root-ro"
        for svc in sshd networking ntpd; do timeout 5 rc-service -q "$svc" status >/dev/null 2>&1 || bad="$bad $svc"; done
        ip -4 route show default >"$work/route.now"
        cmp -s "$work/route.before" "$work/route.now" || changes=yes
        [ "$initial_pid" = "$(cat /run/sshd.pid 2>/dev/null)" ] || changes=yes
        [ "$elapsed" -lt "$observe" ] || break
        [ "$elapsed" -lt 25 ] || stop_probe
        if [ "$elapsed" -ge 20 ] && [ "$((elapsed % 20))" -lt 5 ]; then display_progress "$elapsed" "$observe"; fi
        sleep 5
    done
    stop_probe
    if [ -z "$bad" ]; then pass OBSERVE "${elapsed} 秒内链路、根目录读写状态及关键服务未出现检查失败。"; else fail OBSERVE "观察期间出现异常：$bad"; fi
    if [ "$changes" = yes ]; then warn CONTINUITY '观察期间默认路由或 SSH 主进程发生变化，需结合维护操作核对。'; else pass CONTINUITY '观察期间默认路由和 SSH 主进程保持一致。'; fi
    if [ "$min_mem" -lt 24576 ]; then fail MEMORY "观察期最低可用内存 $((min_mem / 1024)) MiB。"
    elif [ "$min_mem" -lt 65536 ]; then warn MEMORY "观察期最低可用内存 $((min_mem / 1024)) MiB，余量偏小。"
    else pass MEMORY "观察期最低可用内存 $((min_mem / 1024)) MiB。"; fi
    if busybox adjtimex >"$work/timex" 2>"$work/timex.err"; then
        clock_result "$work/timex"
    else warn CLOCK '无法读取内核时钟同步状态。'; fi
    if [ "$offline" = yes ]; then warn NTP_QUERY '离线模式未验证 VPC 时间源响应。'
    else ntp_result "$work/ntp.log"; fi
    kernel_errors
}
baseline() {
    if [ -n "$after" ]; then
        if [ ! -f "$after" ] || [ -L "$after" ] || [ "$(stat -c '%u:%a' "$after")" != 0:600 ] || [ "$(stat -c %s "$after")" -gt 1024 ]; then fail REBOOT '基线必须为 root:0600 的普通小文件。'; return; fi
        cp "$after" "$work/baseline"
        if ! awk 'BEGIN{split("format boot_id root_uuid ssh_port host_key result sha256",k)} NF!=2 || $1!=k[NR]{exit 1} NR==1 && $2!="alpine-ecs-acceptance-v1"{exit 1} NR==6 && $2!~/^(PASS|WARN)$/{exit 1} END{if(NR!=7)exit 1}' "$work/baseline"; then fail REBOOT '基线格式不完整或不受支持。'; return; fi
        expected=$(awk '$1 == "sha256" {print $2}' "$work/baseline")
        actual=$(head -n 6 "$work/baseline" | sha256sum | cut -d ' ' -f 1)
        if [ "$expected" != "$actual" ]; then fail REBOOT '基线校验失败。'; return; fi
        if [ -z "$root_uuid" ] || [ -z "$host_key" ] || [ "$(awk '$1 == "root_uuid" {print $2}' "$work/baseline")" != "$root_uuid" ] || [ "$(awk '$1 == "ssh_port" {print $2}' "$work/baseline")" != "$port" ] || [ "$(awk '$1 == "host_key" {print $2}' "$work/baseline")" != "$host_key" ]; then
            fail REBOOT '对照基线的根 UUID、SSH 端口或主机身份不一致。'
        elif [ "$(awk '$1 == "boot_id" {print $2}' "$work/baseline")" = "$boot_id" ]; then
            warn REBOOT 'boot ID 尚未改变，不能认定已经完成重启复验。'
        else pass REBOOT 'boot ID 已改变；根 UUID、SSH 端口与主机身份保持一致。'; fi
        note BASELINE "基线保存时结论为 $(awk '$1 == "result" {print $2}' "$work/baseline")；本次仍独立检查当前状态。"
    elif [ -z "$before" ]; then note REBOOT '本次没有执行重启前后对照；可使用 --before-reboot / --after-reboot。'; fi
    if [ -n "$before" ]; then
        if [ "$failed" -ne 0 ] || [ -z "$root_uuid" ] || [ -z "$host_key" ] || [ -z "$boot_id" ]; then fail BASELINE '当前存在失败或身份信息不完整，未保存基线。'; return; fi
        parent=$(dirname "$before")
        if [ ! -d "$parent" ] || [ -L "$parent" ] || [ "$(stat -c '%u:%a' "$parent")" != 0:700 ]; then fail BASELINE '基线父目录必须已存在，且为 root:0700，例如 /root。'; return; fi
        result=PASS; [ "$warned" -eq 0 ] || result=WARN
        printf 'format alpine-ecs-acceptance-v1\nboot_id %s\nroot_uuid %s\nssh_port %s\nhost_key %s\nresult %s\n' "$boot_id" "$root_uuid" "$port" "$host_key" "$result" >"$work/baseline.out"
        actual=$(sha256sum "$work/baseline.out" | cut -d ' ' -f 1)
        printf 'sha256 %s\n' "$actual" >>"$work/baseline.out"
        if (set -C; cat "$work/baseline.out" >"$before") 2>/dev/null; then pass BASELINE "已保存 $before；脚本不会自动重启。"
        else fail BASELINE '基线文件已存在或不可写；没有覆盖原文件。'; fi
    fi
}

# Entry point. Helper tests read definitions above this marker, never run this CLI.
while [ "$#" -gt 0 ]; do
    case "$1" in
        --ssh-port|--observe-seconds|--before-reboot|--after-reboot)
            [ "$#" -ge 2 ] || fatal "缺少 $1 的值。"
            case "$1" in --ssh-port) port=$2 ;; --observe-seconds) observe=$2 ;; --before-reboot) before=$2 ;; --after-reboot) after=$2 ;; esac
            shift 2 ;;
        --offline) offline=yes; shift ;;
        --help|-h) usage; exit 0 ;;
        *) fatal "未知参数：$1" ;;
    esac
done
[ -z "$port" ] || valid_port "$port" || fatal 'SSH 端口必须为 1..65535。'
case "$observe" in ''|0*|*[!0-9]*) fatal '观察时长必须为 10..600 秒。' ;; esac
[ "${#observe}" -le 3 ] && [ "$observe" -ge 10 ] && [ "$observe" -le 600 ] || fatal '观察时长必须为 10..600 秒。'
[ -z "$before" ] || [ -z "$after" ] || fatal '重启前和重启后选项不能同时使用。'
for file in "$before" "$after"; do case "$file" in ''|/*) ;; *) fatal '基线路径必须为绝对路径。' ;; esac; done
verify_self
[ "$(id -u)" -eq 0 ] && [ "$(uname -s)" = Linux ] && [ "$(uname -m)" = x86_64 ] && [ -f /etc/alpine-release ] || fatal '需要重装后的 x86_64 Alpine，且以 root 运行。'
for cmd in apk sshd ssh-keygen rc-service rc-status timeout ip netstat blkid cpio gzip sha256sum; do command -v "$cmd" >/dev/null || fatal "必要命令缺失：$cmd；脚本不会安装它。"; done
[ -d /run/openrc ] || fatal '需要已从磁盘启动、由 OpenRC 管理的目标系统。'
work=$(mktemp -d /run/alpine-acceptance.XXXXXX) || fatal '不能创建私有临时目录。'
trap cleanup EXIT
trap 'exit 3' HUP INT TERM
init_display
display_header
section 01 '系统与资源'
platform
section 02 '软件与来源'
packages
section 03 '磁盘与启动'
storage
boot_files
section 04 '启动服务'
services
section 05 'SSH 与已知残留'
ssh_checks
residue
section 06 '网络与官方仓库'
network
section 07 '时间同步与运行观察'
time_config
observe_system
section 08 '重启复验'
baseline
display_summary
note SCOPE '结果覆盖列出的当前状态与观察窗口；不能代替外部新连接、离线文件系统检查或长期负载验证。'
[ "$failed" -eq 0 ] || exit 1
[ "$warned" -eq 0 ] || exit 2
exit 0
