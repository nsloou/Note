#!/usr/bin/env bash

set -u

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
apt_log=$(mktemp /tmp/debian-system-check.XXXXXXXX)
trap 'rm -f -- "$apt_log"' EXIT INT TERM

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
value '当前时间' "$(date -Is)"
value 'hostname' "$(hostname)"
value '操作系统' "$os_pretty"
value '内核' "$(uname -r)"
value '内存' "${memory_mib} MiB"
value '运行时间' "$(uptime -p)"
value '根文件系统' "$root_fstype ($root_options)"
value '当前SSH来源' "${current_ip:-无法从当前会话识别}"
value '当前SSH端口' "${current_ssh_port:-未知}"

if [[ $(hostname) == debian ]]; then
    pass 'hostname 固定为 debian'
else
    fail "hostname 不是 debian：$(hostname)"
fi
if grep -Eq '^ID=("?debian"?)$' /etc/os-release; then
    pass "操作系统为 $os_pretty"
else
    fail '操作系统不是 Debian'
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

pending_jobs=$(systemctl list-jobs --no-legend --no-pager 2>/dev/null || true)
if [[ -z $pending_jobs ]]; then
    pass '没有尚未完成的 systemd 启动任务'
else
    fail '仍有 systemd 任务未完成'
    printf '%s\n' "$pending_jobs" | indent
fi

failed_units=$(systemctl --failed --no-legend --no-pager 2>/dev/null || true)
if [[ -z $failed_units ]]; then
    pass '没有失败的 systemd 单元'
else
    fail '存在失败的 systemd 单元'
    printf '%s\n' "$failed_units" | indent
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
if [[ -z $package_processes ]]; then
    pass '没有 apt/dpkg 进程正在运行'
else
    fail '有软件包管理进程正在运行，暂时不要安装软件'
    printf '%s\n' "$package_processes" | indent
fi

package_locks=$(lslocks -n -o COMMAND,PID,PATH 2>/dev/null | awk '
    $3 ~ /^\/var\/(lib\/(dpkg|apt\/lists)|cache\/apt\/archives)\/lock/ {print}
')
if [[ -z $package_locks ]]; then
    pass '没有 apt/dpkg 锁被占用'
else
    fail 'apt/dpkg 锁正在被占用'
    printf '%s\n' "$package_locks" | indent
fi

dpkg_audit=$(dpkg --audit 2>&1 || true)
if [[ -z $dpkg_audit ]]; then
    pass 'dpkg 数据库完整，没有未配置或残缺软件包'
else
    fail 'dpkg 数据库存在异常'
    printf '%s\n' "$dpkg_audit" | indent
fi

dpkg_updates=$(find /var/lib/dpkg/updates -mindepth 1 -maxdepth 1 \
    -type f -print 2>/dev/null || true)
if [[ -z $dpkg_updates ]]; then
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

section 'SSH 安全策略与成功登录来源'
sshd_effective=$(/usr/sbin/sshd -T 2>&1)
sshd_rc=$?
if [[ $sshd_rc == 0 ]]; then
    pass 'sshd 配置语法与展开检查通过'
else
    fail 'sshd -T 检查失败'
    printf '%s\n' "$sshd_effective" | indent
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
    'gatewayports no'
    'permittunnel no'
    'permituserenvironment no'
)
for setting in "${required_settings[@]}"; do
    if grep -Fqx "$setting" <<<"$sshd_effective"; then
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

ssh_log=$(journalctl -u ssh.service -b --no-pager -o cat 2>/dev/null || true)
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
if [[ -z ${current_ip:-} ]]; then
    warn '当前环境没有 SSH_CONNECTION，无法自动判断你的来源 IP'
elif [[ -z $accepted_ips ]]; then
    warn '没有可比较的 SSH 成功登录记录'
else
    unexpected_accepted=$(awk -v own="$current_ip" '$0 != own' <<<"$accepted_ips")
    if [[ -z $unexpected_accepted ]]; then
        pass "所有 SSH 成功登录均来自当前 IP：$current_ip"
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
    ($3==0 || ($3>=1000 && $3<65534)) && $7 !~ /(nologin|false)$/ {
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
        pass 'root authorized_keys 存在且可解析；请核对以下指纹'
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
    /var/log/debian-reinstall-late.error
    /usr/local/lib/debian-reinstall/fix-eth-name.sh
    /etc/systemd/system/fix-eth-name.service
    /etc/systemd/system/multi-user.target.wants/fix-eth-name.service
    /etc/apt/preferences.d/99-debian-reinstall-block-extras
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

if [[ -z $(swapon --show --noheadings 2>/dev/null) ]] &&
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
)
installed_blocked=()
for package in "${blocked_packages[@]}"; do
    if dpkg-query -W -f='${db:Status-Status}\n' "$package" 2>/dev/null |
        grep -qx installed; then
        installed_blocked+=("$package")
    fi
done
if (( ${#installed_blocked[@]} == 0 )); then
    pass '禁止的可选包均未安装'
else
    fail "发现不应安装的可选包：${installed_blocked[*]}"
fi

sources=/etc/apt/sources.list.d/debian.sources
if [[ -s $sources ]] &&
    grep -Fxq 'URIs: https://deb.debian.org/debian' "$sources" &&
    grep -Fxq 'URIs: https://security.debian.org/debian-security' "$sources" &&
    [[ ! -s /etc/apt/sources.list ]]; then
    pass 'APT 仅使用预期的 Debian HTTPS 源'
else
    fail 'APT 源不符合预期'
fi

unexpected_dns=$(awk '
    $1=="nameserver" &&
    $2!="8.8.8.8" && $2!="1.1.1.1" &&
    $2!="2001:4860:4860::8888" &&
    $2!="2606:4700:4700::1111" {print $2}
' /etc/resolv.conf)
if [[ -z $unexpected_dns ]]; then
    pass 'DNS 仅包含约定的公共解析器'
else
    fail "发现约定之外的 DNS：$unexpected_dns"
fi

section '本次启动的高优先级日志'
boot_errors=$(journalctl -b -p err..alert --no-pager --no-hostname \
    -o short-monotonic 2>/dev/null || true)
known_benign_errors=$(grep -E 'systemd-ssh-generator' <<<"$boot_errors" || true)
actionable_boot_errors=$(grep -Ev 'systemd-ssh-generator' <<<"$boot_errors" || true)
if [[ -z $actionable_boot_errors || $actionable_boot_errors == '-- No entries --' ]]; then
    pass '本次启动没有需要处理的 error 及以上日志'
    if [[ -n $known_benign_errors ]]; then
        printf '%s  INFO  未提供 AF_VSOCK，systemd-ssh-generator 已跳过；KVM VPS 中无害。%s\n' \
            "$dim" "$reset"
    fi
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
    printf '%s✓ 系统已完整启动，可以安装软件和修改配置。%s\n' "$green" "$reset"
    printf '%s  WARN 不阻止操作，但建议阅读对应日志。%s\n' "$yellow" "$reset"
    exit 0
else
    printf '%s✓ 系统完整、稳定启动，软件包管理器和网络均已就绪。%s\n' \
        "$green" "$reset"
    printf '%s✓ 可以放心安装软件和修改配置。%s\n' "$green" "$reset"
    exit 0
fi
