#!/bin/bash
# lib/rootfs_inner2.sh.sh — 在 chroot 内执行的系统配置脚本（极致精简版）
# 基于套2优化：保留跨版本兼容性（20.04/22.04/24.04），最大化压缩 rootfs 体积
# 所需变量由 common.sh 通过 /usr/bin/env 传入：
#   MODE MIRROR HOSTNAME ROOT_PASSWORD TIMEZONE LOCALES UBUNTU_CODENAME
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C LANG=C
export SYSTEMD_OFFLINE=1

echo "==> [${MODE} 模式] 构建期挂载 tmpfs（省磁盘、防空间不足）"
mount -t tmpfs tmpfs /tmp 2>/dev/null || true
mkdir -p /var/cache/apt/archives
mount -t tmpfs tmpfs /var/cache/apt/archives 2>/dev/null || true

# ========== [优化1] APT 全局配置：安装阶段即排除 doc/man/locale/info 等 ==========
cat > /etc/apt/apt.conf.d/99minimize << 'APTCONF'
APT::Install-Recommends "false";
APT::Install-Suggests "false";
APT::Get::Install-Recommends "false";
APT::Get::Install-Suggests "false";
DPkg::Options:: "--path-exclude=/usr/share/doc/*";
DPkg::Options:: "--path-exclude=/usr/share/man/*";
DPkg::Options:: "--path-exclude=/usr/share/info/*";
DPkg::Options:: "--path-exclude=/usr/share/lintian/*";
DPkg::Options:: "--path-exclude=/usr/share/linda/*";
DPkg::Options:: "--path-exclude=/usr/share/groff/*";
DPkg::Options:: "--path-exclude=/usr/share/i18n/locales/*";
APTCONF

# locale 数据：只保留 en 和 zh_CN，其余全部排除
cat > /etc/apt/apt.conf.d/99locale-keep << LOCCONF
DPkg::Options:: "--path-exclude=/usr/share/locale/*";
DPkg::Options:: "--path-include=/usr/share/locale/en/*";
DPkg::Options:: "--path-include=/usr/share/locale/zh_CN/*";
LOCCONF

# ========== 使用传入的 UBUNTU_CODENAME 变量（跨版本兼容） ==========
CODENAME="${UBUNTU_CODENAME:-focal}"
echo "==> 使用 Ubuntu 代号: $CODENAME"
echo "==> 配置软件源: $MIRROR ($CODENAME)"

cat > /etc/apt/sources.list << SOURCES
deb $MIRROR $CODENAME main restricted universe multiverse
deb $MIRROR $CODENAME-updates main restricted universe multiverse
deb $MIRROR $CODENAME-security main restricted universe multiverse
deb $MIRROR $CODENAME-backports main restricted universe multiverse
SOURCES

echo "==> 更新软件源并安装核心软件包（--no-install-recommends 精简体积）"
apt-get update -qq

# 先尝试修复已有依赖问题，再安装
apt-get -f install -y -qq 2>&1 || true

# ========== [优化2] 命令行 + apt.conf 双重保障不装推荐包 ==========
apt-get install -y -qq --no-install-recommends \
  systemd systemd-sysv dbus udev \
  ifupdown iproute2 net-tools iputils-ping ethtool procps \
  openssh-server ssh sudo \
  e2fsprogs ca-certificates \
  vim-tiny less htop wget curl cron rsyslog bash-completion \
  locales tzdata

echo "==> 基础系统配置"
echo "$HOSTNAME" > /etc/hostname
cat > /etc/hosts << HOSTS
127.0.0.1 localhost
127.0.1.1 $HOSTNAME
HOSTS
ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
echo "$TIMEZONE" > /etc/timezone
dpkg-reconfigure -f noninteractive tzdata >/dev/null 2>&1 || true
echo "root:$ROOT_PASSWORD" | chpasswd
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config

echo "==> 网络配置 (DHCP)"
mkdir -p /etc/network/interfaces.d
cat > /etc/network/interfaces.d/eth0 << ETH0
auto eth0
iface eth0 inet dhcp
ETH0

echo "==> 生成 locale: $LOCALES"
locale-gen $LOCALES >/dev/null 2>&1 || true
update-locale LANG=en_US.UTF-8 >/dev/null 2>&1 || true

echo "==> 预生成 machine-id 与 SSH 主机密钥（首次开机免等待）"
systemd-machine-id-setup 2>/dev/null || true
ssh-keygen -A 2>/dev/null || true

echo "==> 服务优化（低配盒子减负）"
systemctl enable ssh networking systemd-timesyncd 2>/dev/null || true
systemctl mask motd-news.timer motd-news.service 2>/dev/null || true
systemctl mask apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
systemctl set-default multi-user.target 2>/dev/null || true

echo "==> Shell 体验优化"
cat > /root/.bashrc << 'BASHRC'
[ -f /etc/bash.bashrc ] && . /etc/bash.bashrc
[ -f /etc/bash_completion ] && . /etc/bash_completion
alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'
PS1='\[\\e[1;32m\]\u@\h\[\\e[0m\]:\[\\e[1;34m\]\w\[\\e[0m\]\$ '
BASHRC

echo "==> DNS 兜底配置（DHCP 分配后会被覆盖）"
cat > /etc/resolv.conf << 'RESOLV'
nameserver 223.5.5.5
nameserver 223.6.6.6
RESOLV

echo "==> 深度清理（极致精简）"

# [优化3] --purge 彻底移除自动安装包及其配置
apt-get autoremove -y --purge
apt-get clean

# [优化4] 清理 apt 缓存和列表
rm -rf /var/lib/apt/lists/* /var/tmp/* /tmp/* /root/.cache 2>/dev/null || true

# [优化5] 兜底清理 dpkg 排除规则可能遗漏的残留
rm -rf /usr/share/doc /usr/share/man /usr/share/info \
       /usr/share/lintian /usr/share/linda /usr/share/groff 2>/dev/null || true

# [优化6] 清理 systemd 中不必要的组件
rm -rf /usr/lib/systemd/catalog \
       /usr/lib/systemd/systemd-analyze \
       /usr/lib/systemd/systemd-boot* 2>/dev/null || true

# [优化7] 清理 Python 编译缓存
find /usr/lib -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || true
find /usr/lib -name '*.pyc' -delete 2>/dev/null || true

# [优化8] 精简 bash-completion，只保留常用工具补全
if [ -d /usr/share/bash-completion/completions ]; then
  cd /usr/share/bash-completion/completions
  _KEEP="apt apt-get apt-cache dpkg ssh scp systemctl journalctl hostname ip curl wget less vim htop"
  for _f in *; do
    _keep=0
    for _k in $_KEEP; do
      [ "$_f" = "$_k" ] && _keep=1 && break
    done
    [ "$_keep" -eq 0 ] && rm -f "$_f"
  done
  cd /
fi

# [优化9] 清空构建期日志
: > /var/log/bootstrap.log 2>/dev/null || true
: > /var/log/apt/history.log 2>/dev/null || true
: > /var/log/apt/term.log 2>/dev/null || true
: > /var/log/dpkg.log 2>/dev/null || true
: > /var/log/alternatives.log 2>/dev/null || true
rm -f /var/log/*.gz /var/log/*.old /var/log/*.1 2>/dev/null || true

# [优化10] 移除 qemu 静态二进制
rm -f /usr/bin/qemu-arm-static

# [优化11] 删除构建期专用的 APT 精简配置（运行期不需要）
rm -f /etc/apt/apt.conf.d/99minimize /etc/apt/apt.conf.d/99locale-keep

echo "✅ Chroot 内配置完成"
