#!/bin/bash
# lib/rootfs_inner2.sh.sh — 在 chroot 内执行的系统配置脚本（极致精简版）
# 基于套2优化：保留跨版本兼容性（20.04/22.04/24.04），最大化压缩 rootfs 体积
# 所需变量由 common.sh 通过 /usr/bin/env 传入：
#   MODE MIRROR HOSTNAME ROOT_PASSWORD TIMEZONE LOCALES UBUNTU_CODENAME
# lib/rootfs_inner.sh — 在 chroot 内执行的系统配置脚本
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C LANG=C
export SYSTEMD_OFFLINE=1

echo "==> [${MODE} 模式] 挂载 tmpfs"
mount -t tmpfs tmpfs /tmp 2>/dev/null || true
mkdir -p /var/cache/apt/archives
mount -t tmpfs tmpfs /var/cache/apt/archives 2>/dev/null || true

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
DPkg::Options:: "--path-exclude=/usr/share/i18n/locales/*";
APTCONF

cat > /etc/apt/apt.conf.d/99locale-keep << 'LOCCONF'
DPkg::Options:: "--path-exclude=/usr/share/locale/*";
DPkg::Options:: "--path-include=/usr/share/locale/en/*";
DPkg::Options:: "--path-include=/usr/share/locale/zh_CN/*";
LOCCONF

CODENAME="${UBUNTU_CODENAME:-focal}"
echo "==> Ubuntu 代号: $CODENAME"
echo "==> 软件源: $MIRROR"

cat > /etc/apt/sources.list << SOURCES
deb $MIRROR $CODENAME main restricted universe multiverse
deb $MIRROR $CODENAME-updates main restricted universe multiverse
deb $MIRROR $CODENAME-security main restricted universe multiverse
deb $MIRROR $CODENAME-backports main restricted universe multiverse
SOURCES

apt-get update -qq
apt-get -f install -y -qq 2>&1 || true

echo "==> 安装核心软件包"
apt-get install -y -qq --no-install-recommends \
  systemd systemd-sysv systemd-timesyncd dbus udev \
  ifupdown isc-dhcp-client iproute2 net-tools iputils-ping iputils-arping ethtool procps \
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

# shadow 时间戳修复
echo "root:$ROOT_PASSWORD" | chpasswd
TODAY=$(date +%Y-%m-%d)
chage -d "$TODAY" root 2>/dev/null || true
if ! chage -l root 2>/dev/null | grep -q "$TODAY"; then
  DAYS=$(( $(date +%s) / 86400 ))
  sed -i "s/^root:\([^:]*\):[0-9]*:/\1:$DAYS:/" /etc/shadow
fi
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config

echo "==> 网络配置 (DHCP)"
mkdir -p /etc/network/interfaces.d
if [ -n "${CUSTOM_MAC:-}" ]; then
  echo "自定义 MAC: $CUSTOM_MAC"
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

# locale 三处强制 UTF-8
echo "==> 生成 locale: $LOCALES"
locale-gen $LOCALES >/dev/null 2>&1 || true
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

systemd-machine-id-setup 2>/dev/null || true

# 首次启动时由 ssh.service 按新 hostname 生成（不再预生成，避免 comment 显示 runner 名）
rm -f /etc/ssh/ssh_host_*

echo "==> 服务优化"
systemctl enable ssh networking systemd-timesyncd systemd-resolved 2>/dev/null || true
systemctl mask motd-news.timer motd-news.service 2>/dev/null || true
systemctl mask apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
systemctl mask dpkg-db-backup.timer 2>/dev/null || true
systemctl set-default multi-user.target 2>/dev/null || true

# NTP 国内源
cat > /etc/systemd/timesyncd.conf << 'NTP'
[Time]
NTP=ntp.aliyun.com ntp.tencent.com cn.pool.ntp.org
FallbackNTP=0.cn.pool.ntp.org 1.cn.pool.ntp.org 2.cn.pool.ntp.org 3.cn.pool.ntp.org
NTP

# logind 老内核兼容（4.4 内核不支持 hidepid=invisible）
mkdir -p /etc/systemd/logind.conf.d
cat > /etc/systemd/logind.conf.d/99-old-kernel.conf << 'LOGIND'
[Login]
ProtectProc=default
ProcSubset=all
LOGIND

# DNS
mkdir -p /etc/systemd/resolved.conf.d
cat > /etc/systemd/resolved.conf.d/99-dns.conf << 'DNS'
[Resolve]
DNS=223.5.5.5 223.6.6.6
FallbackDNS=119.29.29.29 1.1.1.1
DNSStubListener=yes
DNS

echo "==> Shell PS1"
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

# 深度清理
echo "==> 深度清理"
apt-get autoremove -y --purge
apt-get clean
rm -rf /var/lib/apt/lists/* /var/tmp/* /tmp/* /root/.cache 2>/dev/null || true
rm -rf /usr/share/doc /usr/share/man /usr/share/info \
       /usr/share/lintian /usr/share/linda /usr/share/groff 2>/dev/null || true
rm -rf /usr/lib/systemd/catalog \
       /usr/lib/systemd/systemd-analyze \
       /usr/lib/systemd/systemd-boot* 2>/dev/null || true
find /usr/lib -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || true
find /usr/lib -name '*.pyc' -delete 2>/dev/null || true

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

: > /var/log/bootstrap.log 2>/dev/null || true
: > /var/log/apt/history.log 2>/dev/null || true
: > /var/log/apt/term.log 2>/dev/null || true
: > /var/log/dpkg.log 2>/dev/null || true
: > /var/log/alternatives.log 2>/dev/null || true
rm -f /var/log/*.gz /var/log/*.old /var/log/*.1 2>/dev/null || true

rm -f /usr/bin/qemu-arm-static
rm -f /etc/apt/apt.conf.d/99minimize /etc/apt/apt.conf.d/99locale-keep

# 防御性清理（白名单式）
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

echo "========== rootfs 审计 =========="
echo "--- /root ---"
ls -la /root/
echo "--- /tmp ---"
ls -la /tmp/ 2>/dev/null || echo "(empty)"
echo "--- /home ---"
ls -la /home/
echo "--- /etc/default/locale ---"
cat /etc/default/locale
echo "========== 审计结束 =========="

echo "✅ Chroot 内配置完成"
