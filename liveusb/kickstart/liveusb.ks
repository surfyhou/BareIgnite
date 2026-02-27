# BareIgnite Live USB Kickstart
# Builds a minimal Rocky 9 Live image with all BareIgnite dependencies.
# Used by liveusb/build.sh with lorax/livemedia-creator.

# System language
lang en_US.UTF-8

# Keyboard layout
keyboard us

# Timezone
timezone Asia/Shanghai --utc

# Root password (default for live environment; user should change)
rootpw --plaintext bareignite

# SELinux in permissive mode (provisioning needs flexible access)
selinux --permissive

# Firewall disabled (control node serves DHCP/TFTP/HTTP/SMB)
firewall --disabled

# Network (DHCP by default; user configures static IP before provisioning)
network --bootproto=dhcp --onboot=yes --activate

# Bootloader
bootloader --location=mbr

# Partitioning (for live image creation)
zerombr
clearpart --all --initlabel
autopart --type=plain

# Do not run firstboot wizard
firstboot --disabled

# Poweroff after install (livemedia-creator will capture the image)
poweroff

# ---------------------------------------------------------------------------
# Package selection
# ---------------------------------------------------------------------------
%packages
@core
@standard

# BareIgnite core services
dnsmasq
nginx
samba
samba-client
socat

# Automation tools
ansible-core
python3-jinja2
python3-pyyaml
python3-pip

# Data processing
yq
jq

# Transfer and progress
pv
curl
wget
rsync

# Editors and terminal tools
vim-enhanced
tmux
screen
bash-completion

# Network diagnostic tools
net-tools
bind-utils
iproute
iputils
tcpdump
nmap-ncat
ethtool
bridge-utils

# Disk and media tools
xorriso
syslinux
grub2-efi-x64
grub2-efi-x64-cdboot
shim-x64
dosfstools
e2fsprogs
xfsprogs
parted
gdisk
lvm2

# System utilities
tar
gzip
bzip2
xz
unzip
cpio
bc
file
findutils
which

# Hardware detection
pciutils
usbutils
lshw
dmidecode

# Python for any helper scripts
python3

# Remove unnecessary packages to save space
-plymouth
-plymouth-core-libs
-plymouth-scripts
-iwl*
-ivtv-firmware
-atmel-firmware
-b43-openfwwf
-libertas-usb8388-firmware
-xorg-x11-drv-*
-gnome-*
-evolution-*
-libreoffice-*
%end

# ---------------------------------------------------------------------------
# Post-install customization
# ---------------------------------------------------------------------------
%post --log=/root/ks-post.log

# Set up BareIgnite directory
mkdir -p /opt/bareignite
mkdir -p /mnt/bareignite-data

# Copy overlay files from install media (placed there by build.sh)
OVERLAY_SRC="/run/install/repo/bareignite-overlay"
if [[ -d "$OVERLAY_SRC" ]]; then
    # Copy init script
    if [[ -f "${OVERLAY_SRC}/bareignite-init.sh" ]]; then
        cp "${OVERLAY_SRC}/bareignite-init.sh" /opt/bareignite/liveusb/overlay/bareignite-init.sh 2>/dev/null || \
        mkdir -p /opt/bareignite/liveusb/overlay && \
        cp "${OVERLAY_SRC}/bareignite-init.sh" /opt/bareignite/liveusb/overlay/bareignite-init.sh
        chmod +x /opt/bareignite/liveusb/overlay/bareignite-init.sh
    fi

    # Copy systemd service files
    if [[ -f "${OVERLAY_SRC}/bareignite-init.service" ]]; then
        cp "${OVERLAY_SRC}/bareignite-init.service" /etc/systemd/system/
    fi
    if [[ -f "${OVERLAY_SRC}/media-loader.service" ]]; then
        cp "${OVERLAY_SRC}/media-loader.service" /etc/systemd/system/
    fi
else
    echo "WARNING: Overlay source not found at ${OVERLAY_SRC}"
fi

# Enable BareIgnite services
systemctl enable bareignite-init.service 2>/dev/null || true

# Configure auto-login on tty1 for interactive media loading
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/override.conf <<'GETTY'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I $TERM
Type=idle
GETTY

# Welcome message (MOTD)
cat > /etc/motd <<'MOTD'
========================================================
  BareIgnite - Offline Bare Metal Server Provisioning

  Quick start:  bareignite.sh --help
  Data dir:     /mnt/bareignite-data
  Logs:         /var/log/bareignite-init.log
========================================================
MOTD

# Shell prompt customization for root
cat >> /root/.bashrc <<'BASHRC'

# BareIgnite environment
export BAREIGNITE_ROOT="/opt/bareignite"
export PATH="${BAREIGNITE_ROOT}:${BAREIGNITE_ROOT}/tools/bin:${PATH}"

# Custom prompt
export PS1='\[\033[1;36m\][BareIgnite]\[\033[0m\] \[\033[1;32m\]\u@\h\[\033[0m\]:\[\033[1;34m\]\w\[\033[0m\]\$ '

# Aliases
alias bi='bareignite.sh'
alias status='bareignite.sh status'
alias ll='ls -la'
BASHRC

# Disable unnecessary services for faster boot
systemctl disable kdump.service 2>/dev/null || true
systemctl disable tuned.service 2>/dev/null || true
systemctl disable sssd.service 2>/dev/null || true

# Enable useful services
systemctl enable sshd.service 2>/dev/null || true

# Clean up
dnf clean all
rm -rf /var/cache/dnf/*

echo "BareIgnite Live USB post-install complete."

%end
