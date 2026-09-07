# 阿里云 ECS Alpine 重装与验收

针对 **Alpine → Alpine、x86_64、BIOS、2 vCPU、512 MB 内存、约 1 GB 系统盘、单网卡 IPv4 DHCP** 的阿里云 ECS。

重装会删除所选系统盘的全部分区，创建新文件系统。不会迁移旧系统的文件、配置、SSH 密钥或云代理；不整盘清零，也不属于取证意义上的安全擦除。

## 发布文件

| 文件 | 用途 |
| --- | --- |
| [reinstall.sh](reinstall.sh) | 独立单文件重装脚本，已内嵌安装器 |
| [verify-alpine.sh](verify-alpine.sh) | 独立单文件验收脚本，在重装完成后运行 |
| [SHA256SUMS](SHA256SUMS) | 两份脚本的完整文件 SHA-256 |
| README.md | 重装与验收使用说明 |
| [LICENSE](LICENSE) | GPL-3.0 许可证文本 |

两份脚本各自独立运行，不需要配套安装器或测试文件。执行前用独立可信渠道取得的 SHA-256 核对脚本。SHA-256 用于检测内容变化，不是发布者数字签名。

## 重装

把 `reinstall.sh` 放到旧系统，以 root 操作。先校验：

```sh
printf '%s  reinstall.sh\n' '6011f2a0c37569890493d20756132491585cbe465cfacb671330c7b51eaf0753' | sha256sum -c -
```

确认显示 `reinstall.sh: OK` 后，安装准备工具。这些工具使用旧 Alpine 对应版本的官方源，旧系统随后会被重装：

```sh
alpine_branch=$(cut -d. -f1,2 /etc/alpine-release)
apk --no-cache --repositories-file /dev/null \
  --repository "https://dl-cdn.alpinelinux.org/alpine/v${alpine_branch}/main" \
  add curl libarchive-tools
```

将 `/dev/vda` 换成实际系统盘，必须是整盘设备；将 `2222` 换成需要的 SSH 端口。安全组须允许该 TCP 端口。

```sh
# 只读检查。
sh reinstall.sh check --disk /dev/vda

# 下载并校验官方介质，交互输入两次新 root 密码；不改变启动配置。
sh reinstall.sh prepare --disk /dev/vda --ssh-port 2222

# 核对准备结果后执行；此操作会重启并删除系统盘全部分区。
sh reinstall.sh install --disk /dev/vda --erase-system-disk
```

需要无人值守输入密码时，先准备只含一行密码的私有文件：

```sh
chmod 600 /root/new-password.txt
sh reinstall.sh prepare --disk /dev/vda --ssh-port 2222 \
  --password-file /root/new-password.txt
```

准备完成后、执行安装前，可以取消：

```sh
sh reinstall.sh cancel
```

如果旧系统同时存在 extlinux 和 GRUB 配置，给 `check`、`prepare` 和 `install` 都加上与实际引导器对应的 `--bootloader extlinux` 或 `--bootloader grub`。旧引导器仅负责进入内存安装环境；最终重新安装官方 Syslinux/extlinux 和 MBR，不保留旧 GRUB。

安装期间没有 SSH 或 Web 控制台，进度输出到串口/屏幕。完成后连接：

```sh
ssh -p 2222 root@你的服务器地址
```

新系统会生成新的 SSH 主机密钥，客户端需要核对并更新旧主机记录。公网 IP / EIP 由平台映射，不写入网卡配置。

## 重装后的系统

安装介质为校验值固定的官方 Alpine virt 3.24.1 ISO。新内核启动的内存环境仅从 `https://dl-cdn.alpinelinux.org/alpine/v3.24/main` 下载目标包，并在校验完成后才分区和格式化。没有第三方镜像或网络失败后的替代源。

显式安装包仅为以下七项及其官方依赖：

```text
alpine-base
linux-virt
openssh-server
openssh-server-common-openrc
syslinux
e2fsprogs
ca-certificates-bundle
```

系统使用一个 ext4 根分区，保留日志，无 swap 分区；按 UUID 引导，包含必要的 VirtIO、SCSI、NVMe 驱动。网卡使用 IPv4 DHCP，硬件时钟配置为 UTC，BusyBox NTP 客户端使用阿里云 VPC 时间源；检测到电源按钮时启用基础系统自带的 BusyBox acpid。

仅提供 root 密码 SSH 登录，禁用公钥登录、X11、端口转发、隧道和 SFTP。不安装 cloud-init、阿里云代理、SSH 客户端、X11 或 SFTP 服务端。SSH 主机密钥是协议必需的服务器身份，不是用户登录密钥。

## 验收

最终系统没有 SFTP。可在本地电脑上通过普通 SSH 传入验收脚本：

```sh
ssh -p 2222 root@你的服务器地址 'umask 077; cat > /root/verify-alpine.sh' < verify-alpine.sh
```

随后登录服务器，在 `/root` 中校验并运行：

```sh
printf '%s  verify-alpine.sh\n' '5e587b93f99e7e1ab703c3a4f93258f195a0e24b22010a96e64117513d03c466' | sha256sum -c - &&
sh verify-alpine.sh --ssh-port 2222
```

默认轻量观察 60 秒，检查系统与包基线、官方源、文件一致性、磁盘与启动、服务、SSH 策略、网络、时间同步、内核错误和已知残留。不会安装软件、修改配置、调整时钟、自动修复或重启；临时文件只写入 `/run` 私有目录，退出时清理。

| 结果 | 显示 | 含义 | 退出码 |
| --- | --- | --- | --- |
| PASS | 绿色 | 本次检查通过 | 0 |
| FAIL | 红色 | 发现明确不符合基线的项目 | 1 |
| WARN | 黄色 | 无 FAIL，但有未验证或需要核对的项目 | 2 |
| ERROR | 错误提示 | 校验、参数或运行环境不满足要求 | 3 |

报告分组显示，最后汇总数量和问题。重定向、管道、`NO_COLOR` 或 `TERM=dumb` 使用纯文本；`INFO` 说明项不计入结果。有 FAIL 时退出码优先为 1。

常用选项：

```sh
# 调整观察时间：10..600 秒。
sh verify-alpine.sh --ssh-port 2222 --observe-seconds 120

# 跳过主动 DNS、HTTPS、NTP 查询，相关项目显示未验证。
sh verify-alpine.sh --ssh-port 2222 --offline

# 保存报告并保留退出码。
sh verify-alpine.sh --ssh-port 2222 > /root/alpine-acceptance.log 2>&1
acceptance_status=$?
cat /root/alpine-acceptance.log
printf '验收退出码：%s\n' "$acceptance_status"
```

省略 `--ssh-port` 会读取当前配置；要核对是否使用预期端口，请显式指定。

时间同步会结合 NTP 服务状态、内核同步状态、VPC 时间源的实际响应和偏差判断。收到有效响应且最大绝对偏差不超过 1 秒，`NTP_QUERY` 才通过；超过 1 秒至 5 秒为 WARN，超过 5 秒为 FAIL。无有效响应也显示 WARN。探测使用 BusyBox `ntpd -w`，不修改时钟。普通 VPC NTP 不提供 NTS 加密认证。

### 重启复验

先保存基线；仅在没有 FAIL 且身份信息完整时保存，已有文件不会覆盖：

```sh
sh verify-alpine.sh --ssh-port 2222 --before-reboot /root/alpine-acceptance.before
```

基线父目录须为 root:0700，生成的文件为 root:0600。自行重启并重新通过 SSH 登录后，再运行：

```sh
sh verify-alpine.sh --ssh-port 2222 --after-reboot /root/alpine-acceptance.before
```

复验重新执行检查，并核对 boot ID 已改变、根 UUID、SSH 端口与主机身份不变。同一次启动中重复运行不会被判为重启成功。

## 适用范围

重装要求普通系统盘根分区、BIOS、单网卡 IPv4 DHCP，以及可用的 DNS 和出站 HTTPS。准备阶段 `/var/tmp` 需至少 256 MiB 可用磁盘空间，`/boot` 需至少 64 MiB；不支持 LVM/RAID 根目录、UEFI、多网卡或活动全局 IPv6。

已有启动文件支持 Alpine 标准位置 `/boot/extlinux.conf` 和 `/boot/grub/grub.cfg`。分区前失败时可从启动菜单选择旧系统并取消；分区后失败需要救援环境或重新安装。脚本没有自动循环重装机制。

本地已验证 GRUB 与 extlinux 的完整重装、实际 SSH、故障识别、只读验收、重启复验，以及 NVMe / VirtIO-SCSI 冷启动和 ACPI 关机。完整重装实测磁盘为 VirtIO 块设备；真实 ECS 的 VPC 时间同步、EIP/安全组路径仍需实机验证，Xen 与独立 `/boot` 尚未实测。

验收覆盖列出的当前状态和观察窗口。文件审计以本机 APK 数据库为依据；不在已挂载根分区运行 fsck，也不把一次验收当作长期运行保证。重装后自行增加软件或修改配置，可能偏离新装基线，不自动等同于系统被入侵。

## 上游与许可证

参考 [bin456789/reinstall](https://github.com/bin456789/reinstall) 的两阶段启动与低内存安装经验，研究基准为提交 [6a0a2c9b3c678728fe63bc8bbb0ab82c86717830](https://github.com/bin456789/reinstall/tree/6a0a2c9b3c678728fe63bc8bbb0ab82c86717830)。本项目仅保留阿里云 Alpine 重装 Alpine 的实现。

许可证为 **GPL-3.0-or-later**，完整文本见 [LICENSE](LICENSE)。
