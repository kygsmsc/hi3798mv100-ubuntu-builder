#!/bin/bas
# 所需变量由 common.sh 通过 /usr/bin/env 传入：
#   MODE MIRROR HOSTNAME ROOT_PASSWORD TIMEZONE LOCALES UBUNTU_CODENAME
# lib/rootfs_inner.sh — 在 chroot 内执行的系统配置脚本
# 兼容 Ubuntu 20.04 (focal) / 22.04 (jammy) / 24.04 (noble)

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

CODENAME="${UBUNTU_CODENAME:-focal}"
echo "==> Ubuntu 代号: $CODENAME"
echo "==> 软件源: $MIRROR"

# ========== APT 源格式 ==========
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

# ========== 核心软件包（含 WiFi 脚本依赖）==========
echo "==> 安装核心软件包"
apt-get install -y -qq --no-install-recommends \
  systemd systemd-sysv systemd-timesyncd dbus udev \
  ifupdown isc-dhcp-client iproute2 net-tools iputils-ping iputils-arping ethtool procps \
  openssh-server ssh sudo \
  e2fsprogs ca-certificates \
  vim-tiny less htop wget curl cron rsyslog bash-completion \
  locales tzdata \
  file network-manager wpasupplicant iw rfkill

# ========== USB 存储支持 ==========
echo "==> USB 存储支持"
apt-get install -y -qq --no-install-recommends \
  util-linux usbutils \
  dosfstools ntfs-3g exfat-fuse eject

cat > /etc/modules-load.d/usb-storage.conf << 'MOD'
usb-storage
uas
vfat
nls_cp437
nls_iso8859-1
nls_utf8
fuse
MOD

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

# ========== root 密码 ==========
echo "==> 设置 root 密码（长度 ${#ROOT_PASSWORD} 字符）"
echo "root:$ROOT_PASSWORD" | chpasswd
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config

printf '%s\n' "$ROOT_PASSWORD" > /etc/firstboot-pwd.txt
chmod 600 /etc/firstboot-pwd.txt
chown root:root /etc/firstboot-pwd.txt

cat > /usr/local/sbin/firstboot-password.sh << 'SH'
#!/bin/bash
[ -f /etc/firstboot-pwd.txt ] || exit 0
PWD=$(cat /etc/firstboot-pwd.txt)
echo "root:$PWD" | chpasswd
chage -d "$(date +%Y-%m-%d)" root 2>/dev/null || true
rm -f /etc/firstboot-pwd.txt
touch /var/lib/firstboot-password.done
SH
chmod +x /usr/local/sbin/firstboot-password.sh

cat > /etc/systemd/system/firstboot-password.service << 'SVC'
[Unit]
Description=First boot: force reset root password
ConditionPathExists=!/var/lib/firstboot-password.done
Before=ssh.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/firstboot-password.sh

[Install]
WantedBy=multi-user.target
SVC
systemctl enable firstboot-password.service 2>/dev/null || true
echo "✅ firstboot-password.service 已启用"

# ============================================================
# 【新增】firstboot-apt-update.service
# 首次启动后台刷新 apt 索引，防止保留的 lists 过期
# 如果网络超时或 apt update 失败，不 touch done 标记，下次启动再试
# ============================================================
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

# ========== locale ==========
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
      echo "❌ localedef 也失败"
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

# ========== SSH 主机密钥 ==========
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

SYSTEMD_VER=$(systemctl --version 2>/dev/null | head -1 | awk '{print $2}' | cut -d. -f1)
if [ "${SYSTEMD_VER:-0}" -ge 247 ] 2>/dev/null; then
    mkdir -p /etc/systemd/logind.conf.d
    cat > /etc/systemd/logind.conf.d/99-old-kernel.conf << 'LOGIND'
[Login]
ProtectProc=default
ProcSubset=all
LOGIND
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

# ========== 深度清理 ==========
echo "==> 深度清理"
apt-get autoremove -y --purge
apt-get clean

# 【关键改动】保留 /var/lib/apt/lists/*，这样刷完机可以直接 apt install
# 只清临时文件和缓存
rm -rf /var/tmp/* /tmp/* /root/.cache 2>/dev/null || true

# 注意：不删 /usr/share/i18n（locale 源）和 /var/lib/apt/lists（apt 索引）
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

# ========== 审计 ==========
echo "========== rootfs 审计 =========="
echo "--- Ubuntu 代号 ---"
echo "$CODENAME"
echo "--- APT 源 ---"
if [ "$CODENAME" = "noble" ]; then
    cat /etc/apt/sources.list.d/ubuntu.sources
else
    cat /etc/apt/sources.list
fi
echo "--- APT lists（关键：应非空，刷完机可直接 apt install）---"
du -sh /var/lib/apt/lists/ 2>/dev/null || echo "(MISSING!)"
ls /var/lib/apt/lists/ 2>/dev/null | head -5
echo "--- /root ---"
ls -la /root/
echo "--- /tmp ---"
ls -la /tmp/ 2>/dev/null || echo "(empty)"
echo "--- /home ---"
ls -la /home/
echo "--- locale 数据 ---"
ls /usr/lib/locale/ 2>/dev/null
echo "--- locale 源数据 ---"
ls /usr/share/i18n/locales/ 2>/dev/null | head -5
echo "--- WiFi / NM 命令检查 ---"
for c in file nmtui nmtui-connect nmcli iw rfkill wpa_supplicant; do
  printf '  %-18s ' "$c"
  command -v "$c" 2>/dev/null || echo "(MISSING!)"
done
echo "--- NetworkManager 配置 ---"
cat /etc/NetworkManager/conf.d/99-hinas.conf 2>/dev/null
echo "--- 首次启动服务 ---"
systemctl is-enabled firstboot-password.service 2>/dev/null || true
systemctl is-enabled firstboot-apt-update.service 2>/dev/null || true
echo "--- /etc/shadow 中 root 行（前 30 字符）---"
grep '^root:' /etc/shadow | cut -c1-30
echo "--- SSH 主机密钥 comment ---"
for k in /etc/ssh/ssh_host_*_key.pub; do
  [ -f "$k" ] && ssh-keygen -lf "$k" 2>/dev/null
done
echo "========== 审计结束 =========="

echo "✅ Chroot 内配置完成"
