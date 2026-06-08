#!/usr/bin/env bash
#
# inject-ltp.sh — Cross-compile LTP and inject it into an existing rootfs image.
#
# Usage:
#   ./scripts/inject-ltp.sh [OPTIONS]
#
# Options:
#   -a, --arch ARCH       Target architecture (default: aarch64)
#   --ltp-version VER     LTP git tag (default: 20260529)
#   --rootfs PATH         Rootfs image path (default: auto-detected)
#   -f, --force           Overwrite existing LTP installation
#   -h, --help            Show this help
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TEMP_FILES=()
cleanup_temps() {
    for f in "${TEMP_FILES[@]}"; do
        rm -f "$f"
    done
}
trap cleanup_temps EXIT

# Defaults
ARCH="aarch64"
LTP_VERSION="20260529"
ROOTFS_PATH=""
FORCE=0

usage() {
    sed -n '2,/^$/p' "$0" | sed 's/^# //; s/^#//'
    exit 0
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -a|--arch)
                [[ -z "${2:-}" ]] && { echo "Error: --arch requires a value"; exit 1; }
                ARCH="$2"; shift 2 ;;
            --ltp-version)
                [[ -z "${2:-}" ]] && { echo "Error: --ltp-version requires a value"; exit 1; }
                LTP_VERSION="$2"; shift 2 ;;
            --rootfs)
                [[ -z "${2:-}" ]] && { echo "Error: --rootfs requires a value"; exit 1; }
                ROOTFS_PATH="$2"; shift 2 ;;
            -f|--force)       FORCE=1; shift ;;
            -h|--help)        usage ;;
            *) echo "Unknown option: $1"; usage ;;
        esac
    done
}

resolve_arch() {
    case "$ARCH" in
        aarch64)  CROSS_PREFIX="aarch64-linux-gnu" ;;
        riscv64)  CROSS_PREFIX="riscv64-linux-gnu" ;;
        x86_64)   CROSS_PREFIX="x86_64-linux-gnu" ;;
        *) echo "Error: unsupported architecture '$ARCH'"; exit 1 ;;
    esac

    if [[ -z "$ROOTFS_PATH" ]]; then
        ROOTFS_PATH="$WORKSPACE_ROOT/tmp/axbuild/rootfs/rootfs-${ARCH}-debian.img"
    fi
}

check_prerequisites() {
    local missing=0

    if ! command -v "${CROSS_PREFIX}-gcc" &>/dev/null; then
        echo "Error: ${CROSS_PREFIX}-gcc not found in PATH."
        echo "  Install: sudo apt install gcc-${CROSS_PREFIX}"
        missing=1
    fi

    if ! command -v debugfs &>/dev/null; then
        echo "Error: debugfs not found. Install e2fsprogs."
        missing=1
    fi

    if [[ ! -f "$ROOTFS_PATH" ]]; then
        echo "Error: rootfs image not found: $ROOTFS_PATH"
        echo "  Run: cargo starry qemu --arch $ARCH --rootfs debian"
        missing=1
    fi

    if [[ $missing -eq 1 ]]; then
        exit 1
    fi
}

check_ltp_exists() {
    local output
    output=$(debugfs -R "ls /opt/ltp" "$ROOTFS_PATH" 2>&1) || true
    if [[ "$output" != *"File not found"* ]] && [[ -n "$output" ]] && [[ "$output" != *"No such file"* ]]; then
        if [[ $FORCE -eq 1 ]]; then
            echo "==> Removing existing LTP installation (--force)..."
            remove_ltp_from_image
        else
            echo "Error: LTP already exists in $ROOTFS_PATH"
            echo "  Use --force to overwrite."
            exit 1
        fi
    fi
}

remove_ltp_from_image() {
    local image="$ROOTFS_PATH"
    local entries
    entries=$(debugfs -R "ls -r /opt/ltp" "$image" 2>/dev/null) || true
    if [[ -n "$entries" ]]; then
        local cmds_file
        cmds_file=$(mktemp)
        TEMP_FILES+=("$cmds_file")
        while IFS= read -r entry; do
            [[ -z "$entry" ]] && continue
            echo "rm /opt/ltp/${entry}" >> "$cmds_file"
        done <<< "$entries"
        echo "rmdir /opt/ltp" >> "$cmds_file"
        echo "quit" >> "$cmds_file"
        debugfs -w -f "$cmds_file" "$image" 2>/dev/null || true
        rm -f "$cmds_file"
    fi
}

download_ltp() {
    local src_dir="$WORKSPACE_ROOT/tmp/axbuild/ltp-src"

    if [[ -d "$src_dir" ]]; then
        echo "==> LTP source already exists, skipping download."
        return 0
    fi

    echo "==> Downloading LTP $LTP_VERSION..."
    mkdir -p "$(dirname "$src_dir")"
    git clone --depth 1 --branch "$LTP_VERSION" \
        https://github.com/linux-test-project/ltp.git "$src_dir"
}

build_ltp() {
    local src_dir="$WORKSPACE_ROOT/tmp/axbuild/ltp-src"
    local install_dir="$src_dir/_install"

    (
        cd "$src_dir"

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
                RANLIB="${CROSS_PREFIX}-ranlib"
        fi

        echo "==> Building LTP (using $(nproc) cores)..."
        make -j"$(nproc)"

        echo "==> Installing to staging directory..."
        rm -rf "$install_dir"
        make install DESTDIR="$install_dir"
    )

    if [[ ! -d "$install_dir/opt/ltp" ]]; then
        echo "Error: LTP install failed."
        exit 1
    fi

    local count
    count=$(find "$install_dir/opt/ltp" -type f | wc -l)
    echo "  Staged $count files"
}

inject_ltp() {
    local src_dir="$WORKSPACE_ROOT/tmp/axbuild/ltp-src"
    local install_dir="$src_dir/_install/opt/ltp"
    local image="$ROOTFS_PATH"
    local backup="${image}.bak"

    echo "==> Backing up image..."
    cp --sparse=always "$image" "$backup"

    echo "==> Generating debugfs commands..."
    local cmds_file
    cmds_file=$(mktemp)
    TEMP_FILES+=("$cmds_file")

    local dir_count=0
    local file_count=0

    # Directories first (parents before children)
    while IFS= read -r dir; do
        [[ -z "$dir" ]] && continue
        local rel="${dir#"$install_dir"}"
        echo "mkdir /opt/ltp${rel}" >> "$cmds_file"
        dir_count=$((dir_count + 1))
    done < <(find "$install_dir" -type d | LC_ALL=C sort)

    # Files with permissions
    while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        local rel="${file#"$install_dir"}"
        local guest="/opt/ltp${rel}"
        local mode
        mode=$(stat -c '%a' "$file")
        echo "rm ${guest}" >> "$cmds_file"
        echo "write ${file} ${guest}" >> "$cmds_file"
        echo "sif ${guest} mode 0${mode}" >> "$cmds_file"
        file_count=$((file_count + 1))
    done < <(find "$install_dir" -type f | LC_ALL=C sort)

    echo "quit" >> "$cmds_file"

    echo "  Dirs: $dir_count, Files: $file_count"
    echo "==> Injecting into rootfs image..."

    local debugfs_output rc
    debugfs_output=$(debugfs -w -f "$cmds_file" "$image" 2>&1) && rc=0 || rc=$?
    rm -f "$cmds_file"

    if [[ $rc -ne 0 ]]; then
        echo "Error: debugfs failed (exit $rc)"
        echo "  Backup: $backup"
        exit 1
    fi

    # Verify
    local verify
    verify=$(debugfs -R "ls /opt/ltp/testcases/bin" "$image" 2>&1) || true
    if [[ "$verify" == *"File not found"* ]] || [[ "$verify" == *"No such file"* ]]; then
        echo "Error: /opt/ltp/testcases/bin not found after injection"
        echo "  Backup: $backup"
        exit 1
    fi

    echo "==> LTP injected successfully!"
    echo "    Image: $image"
}

cleanup() {
    local src_dir="$WORKSPACE_ROOT/tmp/axbuild/ltp-src"
    rm -rf "$src_dir/_install" 2>/dev/null || true
}

main() {
    parse_args "$@"
    resolve_arch
    check_prerequisites
    check_ltp_exists
    download_ltp
    build_ltp
    inject_ltp
    cleanup

    echo ""
    echo "==> Done! Verify with:"
    echo "    cargo starry qemu --arch $ARCH --rootfs debian"
}

main "$@"
