#!/bin/bash
# Copyright (C) 2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
#
# Host driver installer for the Edge AI Demo Studio container. The driver
# section is kept identical to install_dependencies.sh in the main repository.

set -euo pipefail

AUTO_YES=false
AUTO_NO=false

print_usage() {
  cat <<EOF
Usage: sudo $0 [-y|--yes | -n|--no]

Checks the kernel and installs the Intel GPU and NPU drivers:
  GPU: Intel OMIX, https://dgpu-docs.intel.com/installation-guides/installing-omix.html
  NPU: https://github.com/intel/linux-npu-driver/releases/tag/v1.38.0
Everything comes from repositories.intel.com, github.com and the Ubuntu
archive; no Launchpad PPA is used. Must be run as root (sudo).

Options:
  -y, --yes       Install the drivers without asking.
  -n, --no        Skip the driver installation.
  -h, --help      Show this help and exit.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -y|--yes) AUTO_YES=true ;;
    -n|--no) AUTO_NO=true ;;
    -h|--help) print_usage; exit 0 ;;
    *)
      echo "Error: unknown option '$1'" >&2
      print_usage >&2
      exit 1
      ;;
  esac
  shift
done

if [ "$AUTO_YES" = true ] && [ "$AUTO_NO" = true ]; then
  echo "Error: -y and -n are mutually exclusive." >&2
  exit 1
fi

if [ "$EUID" -ne 0 ]; then
  echo "Error: run this script as root: sudo $0" >&2
  exit 1
fi

if [ ! -t 0 ] || [ "$AUTO_YES" = true ] || [ "$AUTO_NO" = true ]; then
  export DEBIAN_FRONTEND="${DEBIAN_FRONTEND:-noninteractive}"
fi

OMIX_VERSION="0.4"
OMIX_DOC_URL="https://dgpu-docs.intel.com/installation-guides/installing-omix.html"

# Intel NPU userspace driver, pinned with the SHA-256 GitHub publishes per asset.
NPU_DRIVER_VERSION="1.38.0"
NPU_DRIVER_BUILD="20260910-34487311128"
NPU_DRIVER_RELEASE_URL="https://github.com/intel/linux-npu-driver/releases/tag/v${NPU_DRIVER_VERSION}"
NPU_DRIVER_SHA256_NOBLE="1efcd4b60c22abee751d8f2705962cbcc2a569de45c7e0e670cf08afbfcdc1d2"
NPU_DRIVER_SHA256_RESOLUTE="83685e6d92f4db1ca65e442846d487c7feb1335634b33994292ceb38f933bcc7"

# Kernel both Intel OMIX (Ubuntu 24.04 HWE) and the NPU driver release are validated on.
MIN_KERNEL_VERSION="7.0"
KERNEL_REBOOT_NEEDED=false

print_driver_manual_hint() {
  echo "You can install the drivers later by following:"
  echo "  GPU: $OMIX_DOC_URL"
  echo "  NPU: $NPU_DRIVER_RELEASE_URL"
  echo ""
}

# Adds the Intel graphics apt repository (repositories.intel.com, no Launchpad
# PPA). It serves Intel OMIX and the Level Zero loader (libze1) the NPU needs.
add_intel_graphics_repo() {
  echo "📥 Adding the Intel graphics repository..."
  if ! apt-get update -y || ! apt-get install -y gnupg wget; then
    echo "❌ ERROR: Failed to install gnupg and wget"
    return 1
  fi

  if ! wget -qO - https://repositories.intel.com/gpu/intel-graphics.key | \
      gpg --yes --dearmor --output /usr/share/keyrings/intel-graphics.gpg; then
    echo "❌ ERROR: Failed to import the Intel graphics GPG key"
    return 1
  fi

  echo "deb [arch=amd64 signed-by=/usr/share/keyrings/intel-graphics.gpg] https://repositories.intel.com/gpu/ubuntu ${VERSION_CODENAME}/intel-omix/${OMIX_VERSION} unified" \
    > "/etc/apt/sources.list.d/intel-gpu-${VERSION_CODENAME}.list"

  # Hosts set up by the edge-developer-kit-reference-scripts installer carry the
  # kobuk-team Launchpad PPA, whose newer builds of the GPU runtime break the exact
  # versions intel-omix depends on. This repository wins for those packages.
  if ! printf '%s\n' \
      "Package: intel-gpu* intel-opencl-icd intel-ocloc* intel-gsc* libze1 libze-* libigc* libigdfcl* libigdgmm* libigsc* libmetee* libxpum* xpu-smi*" \
      "Pin: origin repositories.intel.com" \
      "Pin-Priority: 1001" > /etc/apt/preferences.d/intel-omix; then
    echo "❌ ERROR: Failed to write /etc/apt/preferences.d/intel-omix"
    return 1
  fi

  if ! apt-get update -y; then
    echo "❌ ERROR: Failed to update apt after adding the Intel graphics repository"
    return 1
  fi
}

# Installs the Intel Open Middleware Xe (OMIX) runtime: the Level Zero and OpenCL
# GPU drivers plus the oneAPI Deep Learning Essentials. --allow-downgrades lets
# the pin above replace newer PPA builds.
install_gpu_driver() {
  echo ""
  echo "🚀 [GPU] Installing intel-omix (~6 GB, this may take several minutes)..."
  if ! apt-get install -y --allow-downgrades intel-omix; then
    echo "❌ ERROR: Intel OMIX installation failed"
    return 1
  fi

  if command -v xpu-smi >/dev/null 2>&1; then
    echo "Verifying with xpu-smi..."
    xpu-smi || echo "⚠️  xpu-smi did not list a GPU (expected inside a container without devices)."
  fi
  echo "✅ [GPU] Intel OMIX installed"
}

# Installs the Intel NPU userspace driver from its GitHub release. The release
# notes take libze1 from a Launchpad PPA; it comes from the Intel graphics
# repository here instead, so this works where Launchpad is blocked.
install_npu_driver() {
  echo ""
  local installed_version
  installed_version=$(dpkg-query -W -f='${Version}' intel-level-zero-npu 2>/dev/null || true)
  if [[ "$installed_version" == "${NPU_DRIVER_VERSION}.${NPU_DRIVER_BUILD}"* ]]; then
    echo "✅ [NPU] Intel NPU driver v${NPU_DRIVER_VERSION} already installed"
    return 0
  fi

  echo "🚀 [NPU] Installing Intel NPU driver v${NPU_DRIVER_VERSION}..."

  local ubuntu_tag expected_sha
  case "$VERSION_CODENAME" in
    noble)    ubuntu_tag="ubuntu2404"; expected_sha="$NPU_DRIVER_SHA256_NOBLE" ;;
    resolute) ubuntu_tag="ubuntu2604"; expected_sha="$NPU_DRIVER_SHA256_RESOLUTE" ;;
  esac

  if ! apt-get install -y libtbb12 libze1; then
    echo "❌ ERROR: Failed to install libtbb12 and libze1"
    return 1
  fi

  local archive="linux-npu-driver-v${NPU_DRIVER_VERSION}.${NPU_DRIVER_BUILD}-${ubuntu_tag}.tar.gz"
  local url="https://github.com/intel/linux-npu-driver/releases/download/v${NPU_DRIVER_VERSION}/${archive}"
  local work_dir
  work_dir=$(mktemp -d)

  if ! wget -q --show-progress -O "$work_dir/$archive" "$url"; then
    echo "❌ ERROR: Failed to download $url"
    rm -rf "$work_dir"
    return 1
  fi

  if ! echo "$expected_sha  $work_dir/$archive" | sha256sum -c --quiet -; then
    echo "❌ ERROR: Checksum mismatch for $archive"
    rm -rf "$work_dir"
    return 1
  fi

  if ! tar -xzf "$work_dir/$archive" -C "$work_dir"; then
    echo "❌ ERROR: Failed to extract $archive"
    rm -rf "$work_dir"
    return 1
  fi

  # Older NPU packages block an upgrade, per the release notes.
  dpkg --purge --force-remove-reinstreq intel-driver-compiler-npu intel-fw-npu \
    intel-level-zero-npu intel-level-zero-npu-dbgsym >/dev/null 2>&1 || true

  # The .ddeb debug symbols are not needed at runtime.
  if ! dpkg -i "$work_dir"/*.deb; then
    echo "❌ ERROR: Failed to install the NPU driver packages"
    rm -rf "$work_dir"
    return 1
  fi

  rm -rf "$work_dir"
  echo "✅ [NPU] Intel NPU driver v${NPU_DRIVER_VERSION} installed"
}

# True inside Docker/Podman, where uname reports the host's kernel and only the
# host can change it.
in_container() {
  [ -f /.dockerenv ] || [ -f /run/.containerenv ]
}

# Succeeds when the running kernel is at least MIN_KERNEL_VERSION.
kernel_meets_minimum() {
  local running="${1%%-*}"
  [ "$(printf '%s\n%s\n' "$MIN_KERNEL_VERSION" "$running" | sort -V | head -n1)" = "$MIN_KERNEL_VERSION" ]
}

# Warns when the running kernel is older than the drivers need. On Ubuntu 24.04
# an interactive run offers the HWE kernel from the Ubuntu archive; -y only warns,
# because a kernel change needs a reboot an unattended run should not spring.
check_kernel() {
  local running
  running="$(uname -r)"

  echo "🐧 Checking the kernel (running $running, need $MIN_KERNEL_VERSION or newer)..."

  if in_container; then
    echo "   Inside a container: the host kernel applies; make sure the host runs $MIN_KERNEL_VERSION or newer."
    return 0
  fi

  if kernel_meets_minimum "$running"; then
    echo "✅ Kernel $running is supported"
    return 0
  fi

  echo "⚠️  Kernel $running is older than $MIN_KERNEL_VERSION: the Intel GPU (xe) and NPU (intel_vpu)"
  echo "   kernel drivers may not support your hardware, even with the userspace drivers installed."

  if [ "$VERSION_CODENAME" != "noble" ]; then
    echo "   Update the kernel to $MIN_KERNEL_VERSION or newer and reboot."
    return 0
  fi

  if [ "$AUTO_YES" = true ] || [ ! -t 0 ]; then
    echo "   Install the Ubuntu 24.04 HWE kernel, then reboot:"
    echo "     sudo apt install -y linux-generic-hwe-24.04 && sudo reboot"
    return 0
  fi

  read -p "Install the Ubuntu 24.04 HWE kernel (linux-generic-hwe-24.04) now? (y/N): " -n 1 -r
  echo ""
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "   Skipped. Install it later with: sudo apt install -y linux-generic-hwe-24.04 && sudo reboot"
    return 0
  fi

  if ! apt-get install -y linux-generic-hwe-24.04; then
    echo "❌ ERROR: Failed to install linux-generic-hwe-24.04"
    return 1
  fi
  KERNEL_REBOOT_NEEDED=true
  echo "✅ HWE kernel installed; it takes effect after a reboot"
}

install_drivers() {
  echo ""
  echo "=========================================="
  echo "🔧 Intel GPU & NPU Driver Installation"
  echo "=========================================="
  echo ""
  echo "This installs, from repositories.intel.com and github.com:"
  echo "  1. GPU: Intel OMIX runtime (Level Zero and OpenCL drivers, oneAPI DL Essentials)."
  echo "     Validated on Intel Arc Pro B50/B60/B65/B70."
  echo "  2. NPU: Intel NPU driver v${NPU_DRIVER_VERSION} (Core Ultra NPUs)."
  echo "Supported OS: Ubuntu 24.04 (HWE kernel) or 26.04."
  echo ""

  if [ "$AUTO_NO" = true ]; then
    echo "Auto-skipping driver installation (-n flag set)."
    echo ""
    echo "⚠️  Driver installation skipped."
    print_driver_manual_hint
    return 0
  elif [ "$AUTO_YES" = false ]; then
    if [ ! -t 0 ]; then
      echo "❌ ERROR: No TTY to ask about the driver installation."
      echo "   Re-run with -y (install the drivers) or -n (skip them)."
      return 1
    fi
    read -p "Would you like to install the Intel GPU and NPU drivers now? (y/N): " -n 1 -r
    echo ""

    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      echo ""
      echo "⚠️  Driver installation skipped."
      print_driver_manual_hint
      return 0
    fi
  else
    echo "Auto-accepting driver installation (-y flag set)..."
  fi

  . /etc/os-release
  if [ "${ID:-}" != "ubuntu" ] || { [ "${VERSION_CODENAME:-}" != "noble" ] && [ "${VERSION_CODENAME:-}" != "resolute" ]; }; then
    echo "❌ ERROR: The Intel GPU and NPU drivers support Ubuntu 24.04 (noble) and 26.04 (resolute); found ${PRETTY_NAME:-unknown}."
    print_driver_manual_hint
    return 1
  fi

  echo ""
  if ! check_kernel || ! add_intel_graphics_repo || ! install_gpu_driver || ! install_npu_driver; then
    print_driver_manual_hint
    return 1
  fi

  # GPU and NPU device nodes are owned by the render group.
  local target_user="${SUDO_USER:-}"
  if [ -n "$target_user" ] && [ "$target_user" != "root" ]; then
    usermod -aG render "$target_user" || echo "⚠️  Could not add $target_user to the render group; add it manually."
    echo "Log out and back in for the render group to apply."
  fi
}

main() {
  if ! apt-get update -y; then
    echo "❌ ERROR: Failed to update apt package list"
    exit 1
  fi

  install_drivers || exit 1

  echo ""
  if [ "$KERNEL_REBOOT_NEEDED" = true ]; then
    echo "⚠️  Reboot to boot the new kernel: sudo reboot"
  fi
}

main
