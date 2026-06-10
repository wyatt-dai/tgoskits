# LTP Integration for StarryOS

## Overview

This document describes the integration of LTP (Linux Test Project) into StarryOS, enabling automated syscall and kernel feature testing via the StarryOS app framework.

## Architecture

```
apps/starry/ltp/
├── prebuild.sh          # Cross-compile LTP, inject into rootfs overlay
├── run-ltp.sh           # Test runner executed inside QEMU
├── qemu-aarch64.toml    # QEMU config for aarch64
├── qemu-riscv64.toml    # QEMU config for riscv64
├── qemu-x86_64.toml     # QEMU config for x86_64
└── README.md            # This file
```

## Hardcoded Values

| Item | Value | Location |
|------|-------|----------|
| LTP version | `20260529` (git tag) | `prebuild.sh` line 7 |
| LTP source | `https://github.com/linux-test-project/ltp.git` | `prebuild.sh` line 13 |
| LTP install prefix | `/opt/ltp` | `prebuild.sh` configure args |
| Cross-compiler prefix | `aarch64-linux-gnu` / `riscv64-linux-gnu` / `x86_64-linux-gnu` | `prebuild.sh` `detect_cross_prefix()` |
| Compile mode | Static (`LDFLAGS=-static`) | `prebuild.sh` configure args |
| Test timeout | 5 seconds per test | `run-ltp.sh` `timeout 5` |
| QEMU timeout | 600 seconds (10 minutes) | `qemu-*.toml` `timeout = 600` |
| Shell prefix | `root@starry:` | `qemu-*.toml` `shell_prefix` |
| Success pattern | `LTP TEST COMPLETE` | `qemu-*.toml` `success_regex` |
| Fail pattern | `(?i)\bpanic(?:ked)?\b` | `qemu-*.toml` `fail_regex` |
| Rootfs | Debian (`rootfs-<arch>-debian.img`) | `qemu-*.toml` drive config |
| Rootfs source | `https://github.com/rcore-os/tgosimages/releases/download/v0.0.5/` | auto-downloaded by framework |

## Build Process

### prebuild.sh Flow

1. **Detect architecture** — maps `STARRY_ARCH` to cross-compiler prefix
2. **Check prerequisites** — verifies `${CROSS_PREFIX}-gcc` is available
3. **Download LTP** — `git clone --depth 1 --branch <tag>` to `apps/starry/ltp/ltp-src/`
4. **Configure** — `./configure --host=<prefix> --prefix=/opt/ltp LDFLAGS=-static`
   - `--without-numa` — avoids libnuma dependency
   - `--without-tirpc` — avoids tirpc dependency
   - `--disable-doc` — skip documentation
   - `LDFLAGS=-static` — produce statically linked binaries (no glibc runtime dependency)
5. **Build** — `make -j$(nproc)`
6. **Install** — `make install DESTDIR=_install`
7. **Expand rootfs** — if LTP size exceeds rootfs free space, `dd` + `resize2fs`
8. **Copy to overlay** — `cp -a _install/opt/ltp/ <overlay>/opt/ltp/`
9. **Copy runner script** — `run-ltp.sh` to `<overlay>/usr/bin/`
10. **Set shell prompt** — `.profile` with `PS1='root@starry:'` to match framework expectation

### Why Static Linking

LTP binaries are compiled with `LDFLAGS=-static` to avoid dynamic library dependency issues:

- The Debian rootfs uses glibc, but the cross-compiler's glibc version may not match
- Static binaries are self-contained and work regardless of rootfs library versions
- Trade-off: larger binary size (~2x), but simpler deployment

### Rootfs Expansion

The pre-built Debian rootfs (~1.1GB) may not have enough free space for LTP (~1.7GB). The prebuild.sh automatically:

1. Calculates LTP install size
2. Checks rootfs free space via `dumpe2fs`
3. Appends zeros with `dd` if needed
4. Expands filesystem with `resize2fs`

## Test Runner (run-ltp.sh)

### Execution Flow

1. Set `trap '' USR1` to ignore SIGUSR1 (workaround for StarryOS signal isolation issue)
2. Iterate all files in `/opt/ltp/testcases/bin/`
3. Skip shell scripts (files starting with `#!`)
4. Skip kernel module tests (`.ko` files — cause kernel panic)
5. Run each test with `timeout 5`
6. Parse LTP output for TPASS/TFAIL/TBROK/TCONF
7. Print structured results
8. Print `LTP TEST COMPLETE` to trigger framework success detection

### Skipped Tests

| Type | Reason | Count |
|------|--------|-------|
| `.sh` scripts | Missing shell library dependencies (`tst_test.sh`, `cgroup_lib.sh`), `/proc/sched_debug` not available | ~460 |
| `.ko` modules | Cause kernel panic in StarryOS | ~11 |
| Total runnable | ELF binaries only | ~2090 |

### Resume from Specific Test

The `START` environment variable allows resuming from a specific test number:

```toml
# In qemu-aarch64.toml
shell_init_cmd = "START=570 /usr/bin/run-ltp.sh"
```

This is useful when a test causes QEMU to hang — change `START` to skip past the problematic test.

### Known Issues

1. **Signal isolation** — StarryOS does not properly isolate signals between parent and child processes. Tests sending SIGUSR1 can kill the runner. Mitigated with `trap '' USR1`.

2. **QEMU hangs** — StarryOS QEMU can hang randomly (not just during tests). The 600-second timeout in qemu config handles this, but test results before the hang are lost.

3. **Unsupported ioctl** — Many tests trigger `ioctl command 21505` (TIOCGWINSZ) which StarryOS doesn't support. This produces kernel log noise but doesn't affect test results.

4. **Slow execution** — QEMU emulation of aarch64 on x86_64 is ~5-10x slower than native. Full test suite takes ~20-30 minutes.

## CI Workflow

**File:** `.github/workflows/ltp-test.yml`

- Runs daily at 03:00 Beijing time (UTC 19:00)
- Supports manual trigger via `workflow_dispatch`
- Runs on 3 architectures: aarch64, riscv64, x86_64
- Installs cross-compiler (`gcc-<arch>-linux-gnu`) in CI
- Results uploaded as GitHub Actions artifacts (30-day retention)

### CI Matrix

| Architecture | Cross-compiler | Rootfs |
|-------------|---------------|--------|
| aarch64 | `aarch64-linux-gnu` | `rootfs-aarch64-debian.img` |
| riscv64 | `riscv64-linux-gnu` | `rootfs-riscv64-debian.img` |
| x86_64 | `x86_64-linux-gnu` | `rootfs-x86_64-debian.img` |

## Usage

### Run via app framework

```bash
# Run all architectures
cargo starry app qemu -t ltp --arch aarch64
cargo starry app qemu -t ltp --arch riscv64
cargo starry app qemu -t ltp --arch x86_64
```

### Resume from specific test

Edit `qemu-<arch>.toml`:
```toml
shell_init_cmd = "START=570 /usr/bin/run-ltp.sh"
```

### Manual injection (without app framework)

```bash
# Inject LTP into existing Debian rootfs
./scripts/inject-ltp.sh --arch aarch64

# Boot with injected rootfs
cargo starry qemu --arch aarch64 --rootfs debian
```

### Build Debian rootfs with LTP (alternative)

```bash
# Uses Docker + debootstrap, slower but self-contained
./scripts/build-debian-rootfs.sh --arch aarch64 --with-ltp
```

## Dependencies

| Dependency | Purpose | Install |
|-----------|---------|---------|
| `gcc-<arch>-linux-gnu` | Cross-compile LTP | `sudo apt install gcc-aarch64-linux-gnu` |
| `autoconf`, `automake`, `libtool` | LTP autotools build | `sudo apt install autoconf automake libtool` |
| `bison`, `flex` | LTP build | `sudo apt install bison flex` |
| `debugfs` | Rootfs image manipulation | `sudo apt install e2fsprogs` |
| `git` | Download LTP source | `sudo apt install git` |

## Known Issues

### x86_64 Debian rootfs: `metadata_csum` kernel panic

The x86_64 Debian rootfs uses ext4 `metadata_csum` feature which StarryOS's ext4 driver does not support, causing kernel panic: "failed to determine root device from available block devices". The `prebuild.sh` script automatically removes this feature with `tune2fs -O ^metadata_csum` for x86_64.

### QEMU hangs after ~5 minutes

StarryOS QEMU can randomly hang regardless of test execution. The 600-second timeout in QEMU configs handles this, but test results before the hang are lost. Use `START=N` to resume from a specific test number.

### Signal isolation

StarryOS does not properly isolate signals between parent/child processes. Tests sending SIGUSR1 can kill the test runner. The `run-ltp.sh` script uses `trap '' USR1` to mitigate this.

## Future Work

1. **Shell script tests** — Include `.sh` tests by bundling LTP shell libraries (`testcases/lib/`) in the overlay and fixing PATH
2. **Kernel module tests** — Fix StarryOS kernel module loading to support `.ko` tests
3. **Signal isolation** — Fix StarryOS signal handling to properly isolate parent/child processes
4. **QEMU stability** — Investigate and fix random QEMU hangs in StarryOS
5. **kirk integration** — Install kirk (LTP's official test runner) when Python is available in rootfs
6. **Result persistence** — Extract structured test results from QEMU output for CI reporting
