#!/usr/bin/env bash
#
# prebuild.sh — Cross-compile LTP and copy to overlay for rootfs injection.
#
# Environment variables (set by app framework):
#   STARRY_APP_DIR     — path to this app directory
#   STARRY_OVERLAY_DIR — overlay directory to copy files into
#
set -euo pipefail

app_dir="${STARRY_APP_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
overlay_dir="${STARRY_OVERLAY_DIR:-}"

if [[ -z "$overlay_dir" ]]; then
    echo "error: STARRY_OVERLAY_DIR is required" >&2
    exit 1
fi

# --- Configuration ---
LTP_VERSION="20260529"
LTP_SRC_DIR="${app_dir}/ltp-src"
LTP_BUILD_DIR="${LTP_SRC_DIR}/_install"

# Detect cross-compiler from target arch
detect_cross_prefix() {
    local arch="${ARCH:-aarch64}"
    case "$arch" in
        aarch64)  echo "aarch64-linux-gnu" ;;
        riscv64)  echo "riscv64-linux-gnu" ;;
        x86_64)   echo "x86_64-linux-gnu" ;;
        *)        echo "unknown" ;;
    esac
}

CROSS_PREFIX=$(detect_cross_prefix)

# --- Check prerequisites ---
if ! command -v "${CROSS_PREFIX}-gcc" &>/dev/null; then
    echo "Error: ${CROSS_PREFIX}-gcc not found. Install: sudo apt install gcc-${CROSS_PREFIX}" >&2
    exit 1
fi

# --- Download LTP source ---
if [[ ! -d "$LTP_SRC_DIR" ]]; then
    echo "==> Downloading LTP $LTP_VERSION..."
    git clone --depth 1 --branch "$LTP_VERSION" \
        https://github.com/linux-test-project/ltp.git "$LTP_SRC_DIR"
fi

# --- Build LTP ---
(
    cd "$LTP_SRC_DIR"

    if [[ ! -f include/mk/config.mk ]]; then
        echo "==> Configuring LTP..."
        make autotools
        ./configure \
            --host="${CROSS_PREFIX}" \
            --prefix=/opt/ltp \
            --without-numa \
            --without-tirpc \
            --disable-doc \
            CC="${CROSS_PREFIX}-gcc" \
            AR="${CROSS_PREFIX}-ar" \
            RANLIB="${CROSS_PREFIX}-ranlib" \
            LDFLAGS="-static"
    fi

    echo "==> Building LTP..."
    make -j"$(nproc)"

    echo "==> Installing to staging..."
    rm -rf "$LTP_BUILD_DIR"
    make install DESTDIR="$LTP_BUILD_DIR"
)

# --- Copy to overlay ---
ltp_install="${LTP_BUILD_DIR}/opt/ltp"
if [[ ! -d "$ltp_install" ]]; then
    echo "Error: LTP build failed — $ltp_install not found" >&2
    exit 1
fi

# Expand rootfs image if needed
rootfs="${STARRY_ROOTFS:-}"
if [[ -n "$rootfs" && -f "$rootfs" ]]; then
    ltp_size=$(du -sb "$ltp_install" | cut -f1)
    rootfs_free=$(dumpe2fs -h "$rootfs" 2>/dev/null | grep "Free blocks" | awk '{print $3}')
    rootfs_block_size=$(dumpe2fs -h "$rootfs" 2>/dev/null | grep "Block size" | awk '{print $3}')
    if [[ -n "$rootfs_free" && -n "$rootfs_block_size" ]]; then
        free_bytes=$((rootfs_free * rootfs_block_size))
        if [[ $ltp_size -gt $free_bytes ]]; then
            echo "==> Expanding rootfs image (LTP: $((ltp_size/1024/1024))MB, free: $((free_bytes/1024/1024))MB)..."
            need_mb=$(( (ltp_size - free_bytes) / 1024 / 1024 + 512 ))
            dd if=/dev/zero bs=1M count=$need_mb >> "$rootfs" 2>/dev/null
            resize2fs "$rootfs" 2>/dev/null
        fi
    fi
fi

echo "==> Copying LTP to overlay..."
mkdir -p "$overlay_dir/opt"
cp -a "$ltp_install" "$overlay_dir/opt/ltp"

# Copy test runner script
install -Dm0755 "$app_dir/run-ltp.sh" "$overlay_dir/usr/bin/run-ltp.sh"

# Set shell prompt to match what the framework expects
mkdir -p "$overlay_dir/root"
cat > "$overlay_dir/root/.profile" <<'PROFILE'
export PS1='root@starry:'
export HOME=/root
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
PROFILE

echo "==> LTP ready in overlay"
