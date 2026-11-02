#!/bin/bash
# lib/rootfs_inner.sh — 在 chroot 内执行的系统配置脚本
# 兼容 Ubuntu 20.04 (focal) / 22.04 (jammy) / 24.04 (noble)
# 修复U盘挂载后root密码失效问题--修复中文乱码--修复wifi驱动安装出错
#
# 本版关键修复（vs 用户上传版）：
#   [P1] firstboot-password 改用正向判据 /etc/firstboot-pwd.txt（不再依赖 .done）
#   [P2] 服务启动时机用 WantedBy=multi-user.target + After=local-fs.target
#        + Before=ssh.service（保证 /etc 已 rw，chpasswd 不会静默失败）
#   [P3] 脚本内 chpasswd 失败则保留密码文件（避免"密码没改但密码文件被删"死局）
#   [P4] 密码读取用 printf + cat 管道（避开 bash 内建 $PWD 冲突）
#   [P5] 移除 modules-load.d（4.4 内核模块全内建，避免 systemd-modules-load 失败）
#   [P6] 加 system.conf.d/99-old-kernel.conf（全局关闭 ProtectProc，消除 hidepid 警告）
#   [P7] 保留 apt lists + 99-no-translations（刷完机直接 apt install，无需先 apt update）
#   [P8] A 级精简：删 consolefonts/keymaps/hwdb.bin（-17MB，零影响）
#   [P9] 精简操作不做任何 apt-get remove（避免打断 systemd enable 状态）
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C LANG=C
export SYSTEMD_OFFLINE=1

echo "==> [${MODE} 模式] 挂载 tmpfs"
mount -t tmpfs tmpfs /tmp 2>/dev/null || true
mkdir -p /var/cache/apt/archives
mount -t tmpfs tmpfs /var/cache/apt/archives 2>/dev/null || true

# ============================================================
# APT 最小化（保留 /usr/share/i18n/locales，供 locale-gen 使用）
# ============================================================
cat > /etc/apt/apt.conf.d/99minimize << 'APTCONF'
APT::Install-Recommends "false";
APT::Install-Suggests "false";
APT::Get::Install-Recommends "false";
APT::Get::Install-Suggests "false";
DPkg::Options:: "--path-exclude=/usr/share/doc/*";
DPkg::Options:: "--path-exclude=/usr/share/man/*";
DPkg::Options:: "--path-exclude=/usr/share/info/*";
DPkg::Options:: "--path-exclude=/usr/share/lintian/*";
DPkg::Options:: "--path-exclude=/usr/share/groff/*";
APTCONF

cat > /etc/apt/apt.conf.d/99locale-keep << 'LOCCONF'
DPkg::Options:: "--path-exclude=/usr/share/locale/*";
DPkg::Options:: "--path-include=/usr/share/locale/en/*";
DPkg::Options:: "--path-include=/usr/share/locale/zh_CN/*";
LOCCONF

# 跳过 DEP-11 (AppStream) 和 Translation，apt lists 只保留 Packages（省 ~15MB）
cat > /etc/apt/apt.conf.d/99-no-translations << 'APTCONF'
Acquire::IndexTargets::deb::DEP-11::DefaultEnabled "false";
Acquire::IndexTargets::deb::DEP-11-icons::DefaultEnabled "false";
Acquire::IndexTargets::deb::DEP-11-icons-small::DefaultEnabled "false";
Acquire::IndexTargets::deb::DEP-11-icons-large::DefaultEnabled "false";
Acquire::Languages "none";
APTCONF

CODENAME="${UBUNTU_CODENAME:-focal}"
echo "==> Ubuntu 代号: $CODENAME"
echo "==> 软件源: $MIRROR"

# ============================================================
# APT 源格式（兼容性核心）
#   20.04 / 22.04 → 传统 sources.list
#   24.04 → DEB822 sources.list.d/ubuntu.sources
# ============================================================
if [ "$CODENAME" = "noble" ]; then
    echo "==> DEB822 格式软件源 (24.04+)"
    mkdir -p /etc/apt/sources.list.d
    cat > /etc/apt/sources.list.d/ubuntu.sources << SOURCES
Types: deb
URIs: $MIRROR
Suites: $CODENAME $CODENAME-updates $CODENAME-backports
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: $MIRROR
Suites: $CODENAME-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
SOURCES
    > /etc/apt/sources.list
else
    echo "==> 传统格式软件源 (20.04 / 22.04)"
    cat > /etc/apt/sources.list << SOURCES
deb $MIRROR $CODENAME main restricted universe multiverse
deb $MIRROR $CODENAME-updates main restricted universe multiverse
deb $MIRROR $CODENAME-security main restricted universe multiverse
deb $MIRROR $CODENAME-backports main restricted universe multiverse
SOURCES
fi

apt-get update -qq
apt-get -f install -y -qq 2>&1 || true

# ============================================================
# 核心软件包
#   包含 WiFi 依赖：file / network-manager / wpasupplicant / iw / rfkill
# ============================================================
echo "==> 安装核心软件包"
apt-get install -y -qq --no-install-recommends \
  systemd systemd-sysv systemd-timesyncd dbus udev \
  ifupdown isc-dhcp-client iproute2 net-tools iputils-ping iputils-arping ethtool procps \
  openssh-server ssh sudo \
  e2fsprogs ca-certificates \
  vim-tiny less htop wget curl cron rsyslog bash-completion \
  locales tzdata \
  file network-manager wpasupplicant iw rfkill

# ============================================================
# USB 存储支持（不写 modules-load.d）
#   exfat 用 exfat-fuse（4.4 内核无内建，Ubuntu 20.04/22.04/24.04 均可安装）
# ============================================================
echo "==> USB 存储支持"
apt-get install -y -qq --no-install-recommends \
  util-linux usbutils \
  dosfstools ntfs-3g exfat-fuse eject

cat > /etc/udev/rules.d/99-usb-storage-mount.rules << 'UDEV'
ACTION=="add", SUBSYSTEM=="block", KERNEL=="sd[a-z][0-9]", ENV{SYSTEMD_WANTS}+="usb-mount@%k.service"
ACTION=="remove", SUBSYSTEM=="block", KERNEL=="sd[a-z][0-9]", ENV{SYSTEMD_WANTS}+="usb-umount@%k.service"
UDEV

cat > /etc/systemd/system/usb-mount@.service << 'SVC'
[Unit]
Description=Auto-mount USB block device /dev/%i
After=dev-%i.device

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/usb-mount.sh add %i
ExecStop=/usr/local/sbin/usb-mount.sh remove %i
SVC

cat > /etc/systemd/system/usb-umount@.service << 'SVC'
[Unit]
Description=Auto-unmount USB block device /dev/%i

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/usb-mount.sh remove %i
SVC

mkdir -p /usr/local/sbin
cat > /usr/local/sbin/usb-mount.sh << 'SCRIPT'
#!/bin/bash
set -euo pipefail
ACTION="$1"
DEV="$2"
DEV_PATH="/dev/$DEV"
MOUNT_POINT="/media/$DEV"

case "$ACTION" in
  add)
    [ -b "$DEV_PATH" ] || exit 0
    sleep 0.5
    FSTYPE=$(blkid -o value -s TYPE "$DEV_PATH" 2>/dev/null || true)
    [ -z "$FSTYPE" ] && exit 0
    mkdir -p "$MOUNT_POINT"
    case "$FSTYPE" in
      vfat|fat|msdos) mount -t vfat -o rw,uid=0,gid=0,umask=000 "$DEV_PATH" "$MOUNT_POINT" || true ;;
      exfat) mount.exfat-fuse -o rw,uid=0,gid=0,umask=000 "$DEV_PATH" "$MOUNT_POINT" 2>/dev/null \
               || mount -t exfat -o rw,uid=0,gid=0,umask=000 "$DEV_PATH" "$MOUNT_POINT" 2>/dev/null || true ;;
      ntfs) mount -t ntfs-3g -o rw,uid=0,gid=0,umask=000 "$DEV_PATH" "$MOUNT_POINT" || true ;;
      ext4|ext3|ext2) mount -t "$FSTYPE" -o rw "$DEV_PATH" "$MOUNT_POINT" || true ;;
      *) mount -o rw "$DEV_PATH" "$MOUNT_POINT" 2>/dev/null || true ;;
    esac
    ;;
  remove)
    umount "$MOUNT_POINT" 2>/dev/null || umount -l "$MOUNT_POINT" 2>/dev/null || true
    rmdir "$MOUNT_POINT" 2>/dev/null || true
    ;;
esac
SCRIPT
chmod +x /usr/local/sbin/usb-mount.sh
echo "✅ USB 存储支持已配置"

# ========== 基础系统配置 ==========
echo "==> 基础系统配置"
echo "$HOSTNAME" > /etc/hostname
hostname "$HOSTNAME" 2>/dev/null || true
cat > /etc/hosts << HOSTS
127.0.0.1 localhost
127.0.1.1 $HOSTNAME
HOSTS
ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
echo "$TIMEZONE" > /etc/timezone
dpkg-reconfigure -f noninteractive tzdata >/dev/null 2>&1 || true

# ========== root 密码（构建期 chpasswd） ==========
echo "==> 设置 root 密码（长度 ${#ROOT_PASSWORD} 字符）"
echo "root:$ROOT_PASSWORD" | chpasswd
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config

# ============================================================
# 【P1~P4】firstboot-password（正向判据防弹版）
#   - 判据：/etc/firstboot-pwd.txt 存在（正向，不依赖 .done）
#   - 时机：WantedBy=multi-user.target + After=local-fs.target
#           + Before=ssh.service（保证 /etc 已 rw）
#   - 读取：printf + cat 管道（不用 $PWD 变量，避免 bash 内建冲突）
#   - 失败：chpasswd 失败则保留密码文件，下次启动重试
# ============================================================
printf '%s\n' "$ROOT_PASSWORD" > /etc/firstboot-pwd.txt
chmod 600 /etc/firstboot-pwd.txt
chown root:root /etc/firstboot-pwd.txt

cat > /usr/local/sbin/firstboot-password.sh << 'SH'
#!/bin/bash
PWDFILE=/etc/firstboot-pwd.txt
[ -f "$PWDFILE" ] || exit 0

# 用 printf + cat 管道，避免任何特殊字符展开问题
if { printf 'root:'; cat "$PWDFILE"; } | chpasswd; then
    chage -d "$(date +%Y-%m-%d)" root 2>/dev/null || true
    rm -f "$PWDFILE"
    touch /var/lib/firstboot-password.done
    echo "firstboot-password: reset done at $(date)" | systemd-cat -t firstboot-password 2>/dev/null || true
else
    echo "firstboot-password: chpasswd FAILED, keeping $PWDFILE for retry" \
        | systemd-cat -t firstboot-password 2>/dev/null || true
    exit 1
fi
SH
chmod +x /usr/local/sbin/firstboot-password.sh

cat > /etc/systemd/system/firstboot-password.service << 'SVC'
[Unit]
Description=First boot: force reset root password
ConditionPathExists=/etc/firstboot-pwd.txt
After=local-fs.target
Before=ssh.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/firstboot-password.sh
TimeoutStartSec=60

[Install]
WantedBy=multi-user.target
SVC
systemctl enable firstboot-password.service 2>/dev/null || true
echo "✅ firstboot-password.service 已启用（正向判据）"

# ========== firstboot-apt-update（首次启动后台刷新 apt lists） ==========
cat > /etc/systemd/system/firstboot-apt-update.service << 'SVC'
[Unit]
Description=First boot: refresh apt package lists in background
ConditionPathExists=!/var/lib/firstboot-apt-update.done
After=network-online.target networking.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c 'for i in $(seq 1 90); do if ping -c 1 -W 1 223.5.5.5 >/dev/null 2>&1; then break; fi; sleep 1; done; /usr/bin/apt-get update -qq && /bin/touch /var/lib/firstboot-apt-update.done'
TimeoutStartSec=600

[Install]
WantedBy=multi-user.target
SVC
systemctl enable firstboot-apt-update.service 2>/dev/null || true
echo "✅ firstboot-apt-update.service 已启用"

# ========== 网络配置 ==========
echo "==> 网络配置 (eth0: ifupdown / wlan0: NetworkManager)"
mkdir -p /etc/network/interfaces.d
if [ -n "${CUSTOM_MAC:-}" ]; then
  echo "自定义 eth0 MAC: $CUSTOM_MAC"
  cat > /etc/network/interfaces.d/eth0 << ETH0
auto eth0
iface eth0 inet dhcp
pre-up ifconfig eth0 hw ether $CUSTOM_MAC
ETH0
else
  cat > /etc/network/interfaces.d/eth0 << ETH0
auto eth0
iface eth0 inet dhcp
ETH0
fi
if ! grep -q 'source /etc/network/interfaces.d/\*' /etc/network/interfaces 2>/dev/null; then
  echo 'source /etc/network/interfaces.d/*' >> /etc/network/interfaces
fi

mkdir -p /etc/NetworkManager/conf.d
cat > /etc/NetworkManager/conf.d/99-hinas.conf << 'NMCONF'
[keyfile]
unmanaged-devices=interface-name:eth0

[device]
wifi.scan-rand-mac-address=no

[connection]
wifi.powersave = 2
NMCONF

# ========== locale（含硬验证兜底） ==========
echo "==> 生成 locale: $LOCALES"
cat > /etc/locale.gen << 'LGEN'
en_US.UTF-8 UTF-8
zh_CN.UTF-8 UTF-8
LGEN

if ! locale-gen; then
  echo "⚠️  locale-gen 返回非 0"
fi

for _loc in en_US.UTF-8 zh_CN.UTF-8; do
  _dir="/usr/lib/locale/$(echo "$_loc" | tr 'A-Z.' 'a-z' | sed 's/utf-8/utf8/')"
  if [ ! -d "$_dir" ] || [ -z "$(ls -A "$_dir" 2>/dev/null)" ]; then
    echo "❌ locale 生成失败: $_dir，尝试 localedef 兜底..."
    mkdir -p "$_dir"
    if ! localedef -i "$(echo "$_loc" | cut -d. -f1)" -f UTF-8 "$_loc" 2>&1; then
      echo "❌ localedef 也失败，检查 /usr/share/i18n/locales/"
      ls -la /usr/share/i18n/locales/ 2>&1 | head -10
      exit 1
    fi
  fi
  echo "  ✅ $_loc -> $_dir"
done

cat > /etc/default/locale << 'LOCALE'
LANG=en_US.UTF-8
LC_ALL=en_US.UTF-8
LOCALE
cat > /etc/environment << 'ENV'
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
LANG=en_US.UTF-8
LC_ALL=en_US.UTF-8
ENV
cat > /etc/profile.d/zz-locale.sh << 'LOCSH'
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8
LOCSH
chmod +x /etc/profile.d/zz-locale.sh
update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 >/dev/null 2>&1 || true
echo "✅ locale 生成完成"

systemd-machine-id-setup 2>/dev/null || true

# ========== SSH 主机密钥（用正确 hostname 做 comment） ==========
rm -f /etc/ssh/ssh_host_*
if command -v ssh-keygen >/dev/null 2>&1; then
  mkdir -p /etc/ssh
  for _t in rsa ecdsa ed25519; do
    ssh-keygen -t "$_t" -N '' -f "/etc/ssh/ssh_host_${_t}_key" \
      -C "root@${HOSTNAME}" -q >/dev/null 2>&1 || true
  done
fi

# ========== 服务优化 ==========
echo "==> 服务优化"
systemctl enable ssh networking systemd-timesyncd systemd-resolved 2>/dev/null || true
systemctl enable NetworkManager NetworkManager-dispatcher 2>/dev/null || true
systemctl mask motd-news.timer motd-news.service 2>/dev/null || true
systemctl mask apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
systemctl mask dpkg-db-backup.timer 2>/dev/null || true
systemctl mask networkd-dispatcher 2>/dev/null || true
systemctl set-default multi-user.target 2>/dev/null || true

cat > /etc/systemd/system/rfkill-unblock-wifi.service << 'SVC'
[Unit]
Description=Unblock WiFi via rfkill
Before=NetworkManager.service

[Service]
Type=oneshot
ExecStart=/usr/sbin/rfkill unblock wifi
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SVC
systemctl enable rfkill-unblock-wifi.service 2>/dev/null || true

cat > /etc/systemd/timesyncd.conf << 'NTP'
[Time]
NTP=ntp.aliyun.com ntp.tencent.com cn.pool.ntp.org
FallbackNTP=0.cn.pool.ntp.org 1.cn.pool.ntp.org 2.cn.pool.ntp.org 3.cn.pool.ntp.org
NTP

# ============================================================
# 【P6】systemd 版本检测 + logind/system 兼容
#   systemd 245 (20.04): 跳过
#   systemd 249/255 (22.04/24.04): 写入 logind + system 兼容配置
# ============================================================
SYSTEMD_VER=$(systemctl --version 2>/dev/null | head -1 | awk '{print $2}' | cut -d. -f1)
if [ "${SYSTEMD_VER:-0}" -ge 247 ] 2>/dev/null; then
    echo "==> systemd $SYSTEMD_VER >= 247，写入 logind + system 兼容配置"
    mkdir -p /etc/systemd/logind.conf.d
    cat > /etc/systemd/logind.conf.d/99-old-kernel.conf << 'LOGIND'
[Login]
ProtectProc=default
ProcSubset=all
LOGIND

    mkdir -p /etc/systemd/system.conf.d
    cat > /etc/systemd/system.conf.d/99-old-kernel.conf << 'SYSCONF'
[Manager]
DefaultProtectProc=default
SYSCONF
else
    echo "==> systemd ${SYSTEMD_VER:-未知} < 247，跳过 logind 兼容配置"
fi

mkdir -p /etc/systemd/resolved.conf.d
cat > /etc/systemd/resolved.conf.d/99-dns.conf << 'DNS'
[Resolve]
DNS=223.5.5.5 223.6.6.6
FallbackDNS=119.29.29.29 1.1.1.1
DNSStubListener=yes
DNS

cat > /root/.bashrc << 'BASHRC'
[ -f /etc/bash.bashrc ] && . /etc/bash.bashrc
[ -f /etc/bash_completion ] && . /etc/bash_completion
alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'
PS1='\[\e[1;32m\]\u@\h\[\e[0m\]:\[\e[1;34m\]\w\[\e[0m\]\$ '
BASHRC

cat > /etc/resolv.conf << 'RESOLV'
nameserver 223.5.5.5
nameserver 223.6.6.6
RESOLV

# ============================================================
# 深度清理（保留 /var/lib/apt/lists/*，配合 99-no-translations 已省 15MB）
# ============================================================
echo "==> 深度清理"
apt-get autoremove -y --purge
apt-get clean

# 保留 apt lists（刷完机可直接 apt install）
rm -rf /var/tmp/* /tmp/* /root/.cache 2>/dev/null || true
rm -rf /usr/share/doc /usr/share/man /usr/share/info \
       /usr/share/lintian /usr/share/linda /usr/share/groff 2>/dev/null || true
rm -rf /usr/lib/systemd/catalog \
       /usr/lib/systemd/systemd-analyze \
       /usr/lib/systemd/systemd-boot* 2>/dev/null || true
find /usr/lib -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || true
find /usr/lib -name '*.pyc' -delete 2>/dev/null || true

if [ -d /usr/share/bash-completion/completions ]; then
  cd /usr/share/bash-completion/completions
  _KEEP="apt apt-get apt-cache dpkg ssh scp systemctl journalctl hostname ip curl wget less vim htop nmcli"
  for _f in *; do
    _keep=0
    for _k in $_KEEP; do
      [ "$_f" = "$_k" ] && _keep=1 && break
    done
    [ "$_keep" -eq 0 ] && rm -f "$_f"
  done
  cd /
fi

: > /var/log/bootstrap.log 2>/dev/null || true
: > /var/log/apt/history.log 2>/dev/null || true
: > /var/log/apt/term.log 2>/dev/null || true
: > /var/log/dpkg.log 2>/dev/null || true
: > /var/log/alternatives.log 2>/dev/null || true
rm -f /var/log/*.gz /var/log/*.old /var/log/*.1 2>/dev/null || true

rm -f /usr/bin/qemu-arm-static
rm -f /etc/apt/apt.conf.d/99minimize /etc/apt/apt.conf.d/99locale-keep

# ============================================================
# 【P8/P9】A 级精简（零影响，纯文件删除，不涉及 apt 操作）
#   - consolefonts: 物理 console 字体，SSH/TTL 不影响（-5MB）
#   - keymaps:     物理 console 键盘布局（-2MB）
#   - hwdb.bin:    udev 硬件数据库，删除后 udev 降级运行（-10MB）
#   注意：不执行 apt-get remove eject（1MB 保留，避免打断 systemd enable 状态）
#   注意：不删除 dpkg md5sums/triggers（避免 dpkg 状态不一致）
# ============================================================
echo "==> 精简 A 级（零影响）"
rm -rf /usr/share/consolefonts 2>/dev/null || true
rm -rf /usr/share/keymaps 2>/dev/null || true
rm -f /etc/udev/hwdb.bin 2>/dev/null || true
echo "  ✅ 已移除 consolefonts / keymaps / hwdb.bin（~17MB）"

# B 级精简（可选，MINIMAL_MODE=yes 时执行）
if [ "${MINIMAL_MODE:-no}" = "yes" ]; then
    echo "==> 精简 B 级（纯文件删除）"
    rm -rf /usr/bin/htop 2>/dev/null || true
    rm -rf /usr/share/bash-completion 2>/dev/null || true
    echo "  ✅ 已移除 htop / bash-completion（~4MB）"
fi

# 精简后重新 enable 所有服务（保证符号链接存在）
echo "==> 重新 enable firstboot 服务（保证精简后符号链接存在）"
systemctl enable firstboot-password.service 2>/dev/null || true
systemctl enable firstboot-apt-update.service 2>/dev/null || true
systemctl enable ssh networking NetworkManager systemd-timesyncd systemd-resolved 2>/dev/null || true
systemctl enable rfkill-unblock-wifi.service 2>/dev/null || true

# ========== 防御性清理 ==========
find /root -mindepth 1 -maxdepth 1 \
    ! -name '.bashrc' ! -name '.profile' ! -name '.bash_logout' \
    ! -name '.cache' ! -name '.local' \
    -exec rm -rf {} + 2>/dev/null || true
find /tmp  -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
find /home -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
rm -rf /root/work /root/original_usb /root/tmp 2>/dev/null || true
for f in /mv100*.zip /www_raw.ext4 /backup-32.gz /sdat2img.py \
         /simg2img.py /sparse_info.py /p9-rootfs.img /p8-backup.img; do
  rm -f "$f" 2>/dev/null || true
done

# ============================================================
# 审计（含硬性 fail 检查）
# ============================================================
echo "========== rootfs 审计 =========="
echo "--- Ubuntu 代号 ---"
echo "$CODENAME"
echo "--- APT 源 ---"
if [ "$CODENAME" = "noble" ]; then
    cat /etc/apt/sources.list.d/ubuntu.sources
else
    cat /etc/apt/sources.list
fi

echo "--- APT lists（应非空）---"
du -sh /var/lib/apt/lists/ 2>/dev/null || echo "(MISSING!)"

echo "--- /root ---"
ls -la /root/
echo "--- /tmp ---"
ls -la /tmp/ 2>/dev/null || echo "(empty)"
echo "--- /home ---"
ls -la /home/
echo "--- locale 数据 ---"
ls /usr/lib/locale/ 2>/dev/null
echo "--- WiFi / NM 命令检查 ---"
for c in file nmtui nmtui-connect nmcli iw rfkill wpa_supplicant; do
  printf '  %-18s ' "$c"
  command -v "$c" 2>/dev/null || echo "(MISSING!)"
done

echo "--- firstboot-password 检查（关键）---"
echo -n "  /etc/firstboot-pwd.txt: "
if [ -f /etc/firstboot-pwd.txt ]; then
    echo "存在 (size=$(stat -c%s /etc/firstboot-pwd.txt) bytes)"
else
    echo "❌ 缺失！首次启动不会重置密码"
    exit 1
fi
echo -n "  /usr/local/sbin/firstboot-password.sh: "
if [ -x /usr/local/sbin/firstboot-password.sh ]; then
    echo "存在且可执行"
else
    echo "❌ 缺失或不可执行"
    exit 1
fi
echo -n "  systemd enable: "
systemctl is-enabled firstboot-password.service 2>/dev/null || { echo "❌ 未 enable"; exit 1; }
echo "  service 的 ConditionPathExists:"
grep '^ConditionPathExists' /etc/systemd/system/firstboot-password.service
if grep -q '^ConditionPathExists=!' /etc/systemd/system/firstboot-password.service; then
    echo "  ❌ 检测到反向判据（!），会导致 p7 残留 .done 拦住服务"
    exit 1
fi
echo "  service 的 WantedBy:"
grep '^WantedBy' /etc/systemd/system/firstboot-password.service
echo "  service 的 After/Before:"
grep -E '^(After|Before)=' /etc/systemd/system/firstboot-password.service

echo "--- /etc/shadow 中 root 行（前 40 字符）---"
grep '^root:' /etc/shadow | cut -c1-40
if ! grep -q '^root:\$' /etc/shadow; then
    echo "  ❌ shadow 中 root 行结构异常（无 root:\$ 前缀）"
    exit 1
fi

echo "--- shadow/passwd 权限 ---"
stat -c '    %A %U:%G %n' /etc/passwd /etc/shadow /etc/group /etc/gshadow
SHADOW_PERM=$(stat -c '%a %U:%G' /etc/shadow)
if [ "$SHADOW_PERM" != "640 root:shadow" ]; then
    echo "  ⚠️  shadow 权限非标准：$SHADOW_PERM（将在 firstboot 时修正）"
fi

echo "--- logind / system 兼容配置 ---"
ls /etc/systemd/logind.conf.d/ /etc/systemd/system.conf.d/ 2>/dev/null || echo "(无，旧版 systemd 跳过)"

echo "--- modules-load.d（应为空）---"
ls -la /etc/modules-load.d/ 2>/dev/null

echo "--- 精简 A 级验证（应全部不存在）---"
for p in /usr/share/consolefonts /usr/share/keymaps /etc/udev/hwdb.bin; do
  if [ -e "$p" ]; then
    echo "  ⚠️  $p 仍存在"
  else
    echo "  ✅ $p 已清除"
  fi
done

echo "--- SSH 主机密钥 comment ---"
for k in /etc/ssh/ssh_host_*_key.pub; do
  [ -f "$k" ] && ssh-keygen -lf "$k" 2>/dev/null
done

echo "--- rootfs 各目录体积 ---"
for d in /usr /etc /var /opt /home /root /lib /bin /sbin /boot; do
    if [ -e "$d" ]; then
        sz=$(du -sh "$d" 2>/dev/null | awk '{print $1}')
        printf '  %-8s %s\n' "$sz" "$d"
    fi
done
echo "--- rootfs 总计（不含 proc/sys/dev/run/tmp）---"
du -sh --exclude=/proc --exclude=/sys --exclude=/dev --exclude=/run --exclude=/tmp / 2>/dev/null | awk '{print "  " $1 "  总计"}' || true

echo "========== 审计结束 =========="
echo "✅ Chroot 内配置完成"
