#!/bin/bash
# Build the cs-OS Linux guest for one architecture. LINUX ONLY.
#
#   ./build-guest.sh arm64|x86_64  [outdir]
#
# Produces, in <outdir>/<arch>/:
#   kernel              uncompressed Image (arm64) / bzImage (x86_64)
#   initramfs.cpio.gz   busybox + paned, enough to pivot into the rootfs
#   rootfs.erofs        read-only Alpine userland
#   overlay-seed.ext4   empty 64MB ext4, sparse-grown and resize2fs'd on boot
#
# This never runs on macOS: it needs a Linux kernel build toolchain. CI does it
# (.github/workflows/guest.yml) and publishes the result as a release asset,
# which `make guest` downloads. That is what keeps the macOS side free of
# Docker and sudo.
#
# Requires (Debian/Ubuntu): build-essential bc bison flex libelf-dev libssl-dev
#   cpio erofs-utils e2fsprogs musl-tools curl xz-utils
# Cross-building also needs gcc-aarch64-linux-gnu or gcc-x86-64-linux-gnu.

set -euo pipefail

ARCH="${1:?usage: build-guest.sh arm64|x86_64 [outdir]}"
OUT_ROOT="${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dist}"
OUT="$OUT_ROOT/$ARCH"

KERNEL_VER="${KERNEL_VER:-6.12.41}"          # LTS
ALPINE_BRANCH="${ALPINE_BRANCH:-v3.21}"
ALPINE_VER="${ALPINE_VER:-3.21.3}"
BUSYBOX_VER="${BUSYBOX_VER:-1.36.1}"

WORK="${WORK:-$(mktemp -d)}"
log() { printf '\033[38;5;110m==>\033[0m %s\n' "$*"; }
die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Linux" ] || die "this script only runs on Linux (found $(uname -s))."

case "$ARCH" in
  arm64)
    KARCH=arm64; KIMAGE=arch/arm64/boot/Image
    ALPINE_ARCH=aarch64
    [ "$(uname -m)" = "aarch64" ] || CROSS=aarch64-linux-gnu-
    ;;
  x86_64)
    KARCH=x86_64; KIMAGE=arch/x86/boot/bzImage
    ALPINE_ARCH=x86_64
    [ "$(uname -m)" = "x86_64" ] || CROSS=x86_64-linux-gnu-
    ;;
  *) die "unsupported arch: $ARCH" ;;
esac
CROSS="${CROSS:-}"
MAKEOPTS="-j$(nproc) ARCH=$KARCH ${CROSS:+CROSS_COMPILE=$CROSS}"

mkdir -p "$OUT"

# ------------------------------------------------------------------ kernel

log "building Linux $KERNEL_VER ($ARCH)"
cd "$WORK"
KMAJOR="${KERNEL_VER%%.*}"
curl -fsSL "https://cdn.kernel.org/pub/linux/kernel/v${KMAJOR}.x/linux-${KERNEL_VER}.tar.xz" \
  | tar -xJ
cd "linux-${KERNEL_VER}"

# Start from the smallest sane base, then switch on exactly what a
# Virtualization.framework guest needs. tinyconfig would mean hand-enabling
# hundreds of symbols; defconfig plus subtraction is far more maintainable.
make $MAKEOPTS defconfig

cat > .csos-fragment <<'FRAG'
# --- virtio transport: how the VM talks to us at all ---
CONFIG_VIRTIO=y
CONFIG_VIRTIO_PCI=y
CONFIG_VIRTIO_MMIO=y
CONFIG_VIRTIO_BLK=y
CONFIG_VIRTIO_NET=y
CONFIG_VIRTIO_CONSOLE=y
CONFIG_HW_RANDOM_VIRTIO=y
CONFIG_VIRTIO_BALLOON=y
# vsock is load-bearing: every terminal tab is one vsock connection.
CONFIG_VSOCKETS=y
CONFIG_VIRTIO_VSOCKETS=y

# --- filesystems: erofs base, ext4 overlay, overlayfs union ---
CONFIG_EROFS_FS=y
CONFIG_EROFS_FS_ZIP=y
CONFIG_EXT4_FS=y
CONFIG_OVERLAY_FS=y
CONFIG_TMPFS=y
CONFIG_TMPFS_POSIX_ACL=y
CONFIG_DEVTMPFS=y
CONFIG_DEVTMPFS_MOUNT=y

# --- ptys: one per tab ---
CONFIG_UNIX98_PTYS=y
CONFIG_LEGACY_PTYS=n

# --- networking: NAT via virtio-net, DHCP from the framework ---
CONFIG_INET=y
CONFIG_IP_PNP=y
CONFIG_IP_PNP_DHCP=y
CONFIG_PACKET=y
CONFIG_UNIX=y

# --- initramfs ---
CONFIG_BLK_DEV_INITRD=y
CONFIG_RD_GZIP=y

# --- strip weight we can never use in a headless VM ---
CONFIG_SOUND=n
CONFIG_DRM=n
CONFIG_FB=n
CONFIG_WIRELESS=n
CONFIG_WLAN=n
CONFIG_BT=n
CONFIG_USB_SUPPORT=n
CONFIG_MEDIA_SUPPORT=n
CONFIG_DEBUG_INFO=n
CONFIG_DEBUG_KERNEL=n
CONFIG_MODULES=n
FRAG

./scripts/kconfig/merge_config.sh -m .config .csos-fragment
make $MAKEOPTS olddefconfig
make $MAKEOPTS "$(basename "$KIMAGE")" || make $MAKEOPTS

cp "$KIMAGE" "$OUT/kernel"
log "kernel: $(du -h "$OUT/kernel" | cut -f1)"

# ------------------------------------------------------------- initramfs

log "building busybox + paned"
cd "$WORK"
curl -fsSL "https://busybox.net/downloads/busybox-${BUSYBOX_VER}.tar.bz2" | tar -xj
cd "busybox-${BUSYBOX_VER}"
make $MAKEOPTS defconfig
# Static: the initramfs has no libc of its own.
sed -i 's/^# CONFIG_STATIC is not set/CONFIG_STATIC=y/' .config
sed -i 's/^CONFIG_TC=y/CONFIG_TC=n/' .config    # fails to build on modern headers
make $MAKEOPTS olddefconfig
make $MAKEOPTS busybox
BUSYBOX="$PWD/busybox"

# The guest agent. Static against musl so it needs nothing at runtime.
GUEST_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/src/paned.c"
if command -v musl-gcc >/dev/null 2>&1 && [ -z "$CROSS" ]; then
  musl-gcc -Os -static -o "$WORK/paned" "$GUEST_SRC" -lutil
else
  "${CROSS}gcc" -Os -static -o "$WORK/paned" "$GUEST_SRC" -lutil
fi
"${CROSS}strip" "$WORK/paned"
log "paned: $(du -h "$WORK/paned" | cut -f1)"

log "assembling initramfs"
IRD="$WORK/initramfs"
rm -rf "$IRD"; mkdir -p "$IRD"/{bin,sbin,proc,sys,dev,newroot,mnt}
cp "$BUSYBOX" "$IRD/bin/busybox"
ln -sf busybox "$IRD/bin/sh"
cp "$WORK/paned" "$IRD/sbin/paned"

# Early userspace: mount the erofs base and the ext4 overlay, union them, and
# pivot. paned then runs as PID 1 inside the real rootfs.
cat > "$IRD/init" <<'INIT'
#!/bin/sh
/bin/busybox --install -s /bin 2>/dev/null

mount -t proc  proc  /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs dev /dev 2>/dev/null

# vda = read-only Alpine base, vdb = the user's writable overlay.
mkdir -p /mnt/base /mnt/rw
mount -t erofs -o ro /dev/vda /mnt/base || { echo "cs-OS: cannot mount base rootfs"; sh; }

# The overlay ships as a 64MB seed and is sparse-grown by the host; claim the
# extra space on first boot. macOS has no mkfs.ext4, which is why we grow a
# prebuilt filesystem rather than creating one.
e2fsck -p /dev/vdb >/dev/null 2>&1 || true
resize2fs /dev/vdb >/dev/null 2>&1 || true
mount -t ext4 /dev/vdb /mnt/rw || { echo "cs-OS: cannot mount overlay"; sh; }

mkdir -p /mnt/rw/upper /mnt/rw/work
mount -t overlay overlay \
  -o lowerdir=/mnt/base,upperdir=/mnt/rw/upper,workdir=/mnt/rw/work \
  /newroot || { echo "cs-OS: cannot union mount"; sh; }

mkdir -p /newroot/proc /newroot/sys /newroot/dev
exec switch_root /newroot /sbin/paned
INIT
chmod +x "$IRD/init"
cp "$WORK/paned" "$IRD/sbin/paned"

( cd "$IRD" && find . | cpio -o -H newc --quiet | gzip -9 ) > "$OUT/initramfs.cpio.gz"
log "initramfs: $(du -h "$OUT/initramfs.cpio.gz" | cut -f1)"

# ---------------------------------------------------------------- rootfs

log "building Alpine $ALPINE_VER rootfs ($ALPINE_ARCH)"
ROOTFS="$WORK/rootfs"
rm -rf "$ROOTFS"; mkdir -p "$ROOTFS"
curl -fsSL "https://dl-cdn.alpinelinux.org/alpine/${ALPINE_BRANCH}/releases/${ALPINE_ARCH}/alpine-minirootfs-${ALPINE_VER}-${ALPINE_ARCH}.tar.gz" \
  | tar -xz -C "$ROOTFS"

# paned is PID 1 in the pivoted rootfs too.
cp "$WORK/paned" "$ROOTFS/sbin/paned"
mkdir -p "$ROOTFS/root"

cat > "$ROOTFS/etc/resolv.conf" <<'EOF'
nameserver 8.8.8.8
nameserver 1.1.1.1
EOF

cat > "$ROOTFS/etc/motd" <<EOF
cs-OS — Alpine Linux ${ALPINE_VER} (${ALPINE_ARCH})
Package manager: apk. Try: apk add curl git
EOF

cat > "$ROOTFS/root/.profile" <<'EOF'
export PS1='\w \$ '
[ -f /etc/motd ] && cat /etc/motd
EOF

# erofs with zstd: smaller than squashfs and read-fast enough that the
# difference never shows up in a terminal workload.
mkfs.erofs -zzstd,19 "$OUT/rootfs.erofs" "$ROOTFS" >/dev/null
log "rootfs: $(du -h "$OUT/rootfs.erofs" | cut -f1)"

# ------------------------------------------------------------ overlay seed

log "creating overlay seed"
SEED="$OUT/overlay-seed.ext4"
rm -f "$SEED"
truncate -s 64M "$SEED"
mkfs.ext4 -q -F -m 0 -O ^has_journal -L csos-overlay "$SEED"
log "overlay seed: $(du -h "$SEED" | cut -f1)"

log "done: $OUT"
ls -la "$OUT"
