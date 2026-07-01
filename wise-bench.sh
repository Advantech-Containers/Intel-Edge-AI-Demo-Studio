#!/bin/bash
LOG_FILE="/tmp/wise-bench.log"
mkdir -p "$(dirname "$LOG_FILE")"
{
  echo "==========================================================="
  echo ">>> Diagnostic Run Started at: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "==========================================================="
} >> "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
PURPLE='\033[0;35m'
NC='\033[0m'

# Config
CONTAINER_NAME="${EDGE_AI_CONTAINER:-edge-ai-demo-studio}"
IMAGE_NAME="harbor.edgesync.cloud/intel/edge-ai-demo-studio:v1.0.0"
WEB_PORT="${EDGE_AI_PORT:-8080}"

clear
echo -e "${BLUE}${BOLD}+------------------------------------------------------+${NC}"
echo -e "${BLUE}${BOLD}|   ${PURPLE}Intel Edge AI Demo Studio Diagnostics Tool${BLUE}         |${NC}"
echo -e "${BLUE}${BOLD}+------------------------------------------------------+${NC}"
echo
echo -e "${BLUE}"
echo "      ██╗███╗   ██╗████████╗███████╗██╗     "
echo "      ██║████╗  ██║╚══██╔══╝██╔════╝██║     "
echo "      ██║██╔██╗ ██║   ██║   █████╗  ██║     "
echo "      ██║██║╚██╗██║   ██║   ██╔══╝  ██║     "
echo "      ██║██║ ╚████║   ██║   ███████╗███████╗"
echo "      ╚═╝╚═╝  ╚═══╝   ╚═╝   ╚══════╝╚══════╝"
echo -e "${NC}"
echo -e "${YELLOW}${BOLD}▶ Starting Intel hardware acceleration diagnostics...${NC}"
echo

print_table_header() {
    echo "+--------------------------------------------------+"
    echo "| $1$(printf '%*s' $((47 - ${#1})) | tr ' ' ' ')|"
    echo "+--------------------------------------------------+"
}
print_table_row() {
    printf "| %-25s | %-19s|\n" "$1" "$2"
}
print_table_footer() {
    echo "+--------------------------------------------------+"
}
print_header() {
    echo
    echo -e "${CYAN}${BOLD}+--- $1 ---+${NC}"
    echo
}

# ── Section 1: System Info ──────────────────────────────────────
print_header "SYSTEM INFORMATION"
print_table_header "SYSTEM DETAILS"
print_table_row "Hostname" "$(hostname)"
print_table_row "OS" "$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d'"' -f2)"
print_table_row "Kernel" "$(uname -r)"
print_table_row "Architecture" "$(uname -m)"
print_table_row "CPU" "$(lscpu | grep 'Model name' | cut -d':' -f2- | sed 's/^[ \t]*//' | head -1)"
print_table_row "Memory" "$(free -h | awk '/^Mem:/ {print $3 " used of " $2}')"
print_table_row "Date" "$(date '+%a %b %d %H:%M:%S %Y')"
print_table_footer

# ── Section 1b: Host Packages ───────────────────────────────────
print_header "HOST PACKAGES"
print_table_header "REQUIRED HOST SOFTWARE"
DOCKER_VER=$(docker --version 2>/dev/null | sed 's/Docker version //;s/,.*//')
if [ -n "$DOCKER_VER" ]; then
    print_table_row "Docker Engine" "✓ $DOCKER_VER"
    DOCKER_PKG=1
else
    print_table_row "Docker Engine" "⚠ Not installed"
    DOCKER_PKG=0
fi
COMPOSE_VER=$(docker compose version --short 2>/dev/null)
if [ -n "$COMPOSE_VER" ]; then
    print_table_row "Compose Plugin" "✓ $COMPOSE_VER"
    COMPOSE_PKG=1
else
    print_table_row "Compose Plugin" "⚠ Not installed"
    COMPOSE_PKG=0
fi
CLINFO_DEV=$(command -v clinfo >/dev/null 2>&1 && clinfo 2>/dev/null | grep -ci "intel" || echo 0)
[ "$CLINFO_DEV" -gt 0 ] && print_table_row "OpenCL (Intel)" "✓ Available" || print_table_row "OpenCL (Intel)" "⚠ Not found"
[ -e /dev/dri/renderD128 ] && print_table_row "GPU Render Node" "✓ /dev/dri" || print_table_row "GPU Render Node" "⚠ Missing"
[ -e /dev/accel/accel0 ] && print_table_row "NPU Accel Node" "✓ /dev/accel" || print_table_row "NPU Accel Node" "⚠ Missing"
# uv (used for OpenVINO/PyTorch device verification)
WB_TMP="$(mktemp -d)"
UV_DIR="$WB_TMP/uv"
export UV_CACHE_DIR="$WB_TMP/uv-cache"
export TMPDIR="$WB_TMP"
cleanup() { rm -rf "$WB_TMP" 2>/dev/null; }
trap cleanup EXIT INT TERM
UV_BIN=""
UV_URL="https://releases.astral.sh/github/uv/releases/download/0.11.25/uv-x86_64-unknown-linux-gnu.tar.gz"
if command -v uv >/dev/null 2>&1; then
    UV_BIN="$(command -v uv)"
else
    mkdir -p "$UV_DIR"
    echo "▶ Downloading portable uv (please wait)..."
    if curl -LsSf "$UV_URL" 2>/dev/null | tar -xz -C "$UV_DIR" --strip-components=1 >/dev/null 2>&1; then
        UV_BIN="$UV_DIR/uv"
    fi
fi
[ -n "$UV_BIN" ] && [ -x "$UV_BIN" ] && print_table_row "uv" "✓ Ready" || print_table_row "uv" "⚠ Unavailable"
print_table_footer

# ── Section 2: Intel GPU Device ─────────────────────────────────
print_header "INTEL GPU DEVICE"

OV_DEVICES=""
OV_GPUS=""
TORCH_GPUS=""
if [ -n "$UV_BIN" ] && [ -x "$UV_BIN" ]; then
    echo "▶ Installing OpenVINO and querying devices (please wait)..."
    OV_DEVICES=$("$UV_BIN" run --quiet --with openvino python3 -c "from openvino import Core; print(','.join(Core().available_devices))" 2>/dev/null || echo "")
    OV_GPUS=$("$UV_BIN" run --quiet --with openvino python3 -c "from openvino import Core; c=Core(); [print(d+': '+c.get_property(d,'FULL_DEVICE_NAME')) for d in c.available_devices if d.startswith('GPU')]" 2>/dev/null || echo "")
    echo "▶ Installing PyTorch (XPU) and checking XPU support (please wait)..."
    TORCH_GPUS=$("$UV_BIN" run --quiet --with torch --with torchvision --with torchaudio --index-url https://download.pytorch.org/whl/xpu python3 -c "import torch; n=torch.xpu.device_count() if hasattr(torch,'xpu') else 0; [print(torch.xpu.get_device_name(i)) for i in range(n)]" 2>/dev/null || echo "")
    echo "▶ Done gathering device info."
fi

print_table_header "GPU DETAILS"

if [ -d /dev/dri ] && ls /dev/dri/render* >/dev/null 2>&1; then
    print_table_row "/dev/dri" "✓ Present"
    lsmod 2>/dev/null | grep -qi 'i915\|xe' && print_table_row "Intel GPU Driver" "✓ Loaded" || print_table_row "Intel GPU Driver" "⚠ Not detected"

    GPU_NAMES=$(clinfo -l 2>/dev/null | grep -i 'device' | sed 's/.*Device[[:space:]]*#[0-9]*:[[:space:]]*//' | grep -i intel | awk '!seen[$0]++')
    if [ -n "$GPU_NAMES" ]; then
        i=0
        while IFS= read -r g; do
            print_table_row "GPU $i" "$g"
            i=$((i+1))
        done <<< "$GPU_NAMES"
    else
        print_table_row "GPU" "$(lspci 2>/dev/null | grep -i 'vga\|display\|3d' | grep -i intel | head -1 | cut -d':' -f3- | sed 's/^[ \t]*//')"
    fi

    # OpenVINO GPU verification (pass = all GPUs detected by OpenVINO)
    if [ -n "$OV_GPUS" ]; then
        while IFS= read -r d; do
            print_table_row "OpenVINO" "✓ ${d:0:17}"
        done <<< "$OV_GPUS"
        GPU_DETECTED=1
    else
        print_table_row "OpenVINO GPU" "⚠ Not listed"
        GPU_DETECTED=0
    fi

    # PyTorch GPU verification (optional - informational only)
    if [ -n "$TORCH_GPUS" ]; then
        j=0
        while IFS= read -r d; do
            print_table_row "PyTorch XPU $j" "✓ ${d:0:15}"
            j=$((j+1))
        done <<< "$TORCH_GPUS"
    else
        print_table_row "PyTorch XPU" "⚠ N/A (optional)"
    fi

    [ "$GPU_DETECTED" -eq 1 ] && print_table_row "Status" "✓ Detected" || print_table_row "Status" "⚠ CPU only"
else
    print_table_row "/dev/dri" "⚠ Not found"
    print_table_row "Status" "⚠ CPU only"
    GPU_DETECTED=0
fi
print_table_footer

# ── Section 3: Intel NPU Device ─────────────────────────────────
print_header "INTEL NPU DEVICE"
print_table_header "NPU DETAILS"
NPU_DETECTED=0

# 3a. Driver / device node check
if [ -e /dev/accel/accel0 ] || ls /dev/accel* >/dev/null 2>&1; then
    print_table_row "/dev/accel" "✓ Present"
    NPU_NODE=1
else
    print_table_row "/dev/accel" "⚠ Not found"
    NPU_NODE=0
fi
if lsmod 2>/dev/null | grep -qi 'intel_vpu\|intel_npu'; then
    print_table_row "Intel NPU Driver" "✓ Loaded"
elif dmesg 2>/dev/null | grep -qi 'intel_vpu\|intel.*npu'; then
    print_table_row "Intel NPU Driver" "✓ Present"
else
    print_table_row "Intel NPU Driver" "⚠ Not detected"
fi

# 3b. Verify NPU via OpenVINO using uv
if [ -n "$UV_BIN" ] && [ -x "$UV_BIN" ]; then
    print_table_row "uv" "✓ Ready"
    if [ -n "$OV_DEVICES" ]; then
        print_table_row "OpenVINO Devices" "$OV_DEVICES"
        if echo "$OV_DEVICES" | grep -qi "NPU"; then
            print_table_row "NPU via OpenVINO" "✓ Detected"
            print_table_row "Status" "✓ Detected"
            NPU_DETECTED=1
        else
            print_table_row "NPU via OpenVINO" "⚠ Not listed"
            print_table_row "Status" "⚠ Not available"
        fi
    else
        print_table_row "OpenVINO Devices" "⚠ Unavailable"
        print_table_row "Status" "⚠ Not available"
    fi
else
    print_table_row "uv" "⚠ Unavailable"
    print_table_row "Status" "⚠ Skipped"
fi
print_table_footer

# ── Section 4: Docker Container ─────────────────────────────────
print_header "DOCKER CONTAINER"
print_table_header "CONTAINER STATUS"
CONTAINER_STATUS=$(docker inspect --format='{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo "not found")
if [ "$CONTAINER_STATUS" = "running" ]; then
    print_table_row "Container" "✓ Running"
    CONTAINER_OK=1
else
    print_table_row "Container" "⚠ $CONTAINER_STATUS"
    CONTAINER_OK=0
fi
IMAGE_INFO=$(docker images "$IMAGE_NAME" --format "{{.Size}}" 2>/dev/null || echo "not found")
print_table_row "Image Size" "${IMAGE_INFO:-not found}"
print_table_footer

# ── Section 5: Web UI / API Check ───────────────────────────────
print_header "WEB UI / API CHECK"
print_table_header "SERVICE DETAILS"
if curl --silent --fail "http://localhost:${WEB_PORT}" > /dev/null 2>&1; then
    print_table_row "Web UI ($WEB_PORT)" "✓ Reachable"
    WEBUI_STATUS=1
else
    print_table_row "Web UI ($WEB_PORT)" "⚠ Not reachable"
    WEBUI_STATUS=0
fi
print_table_footer

# ── Section 7: Service Validation Run ───────────────────────────
print_header "SERVICE VALIDATION RUN"
print_table_header "ONE-TIME SERVICE TEST"
echo "▶ Probing service once to confirm it is valid..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 30 "http://localhost:${WEB_PORT}" 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "302" ] || [ "$HTTP_CODE" = "301" ]; then
    print_table_row "HTTP Response" "✓ $HTTP_CODE"
    print_table_row "Service Run" "✓ Valid"
    SERVICE_RUN=1
else
    print_table_row "HTTP Response" "⚠ $HTTP_CODE"
    print_table_row "Service Run" "⚠ Failed"
    SERVICE_RUN=0
fi
print_table_footer

# ── Section 8: Summary ──────────────────────────────────────────
print_header "DIAGNOSTICS SUMMARY"
print_table_header "OVERALL STATUS"
print_table_row "Intel GPU /dev/dri" "$([[ $GPU_DETECTED -eq 1 ]] && echo '✓ OK' || echo '⚠ Missing')"
print_table_row "Intel NPU /dev/accel" "$([[ $NPU_DETECTED -eq 1 ]] && echo '✓ OK' || echo '⚠ Missing')"
print_table_row "Docker Container" "$([[ $CONTAINER_OK -eq 1 ]] && echo '✓ Running' || echo '⚠ Stopped')"
print_table_row "Web UI / API" "$([[ $WEBUI_STATUS -eq 1 ]] && echo '✓ OK' || echo '⚠ Down')"
print_table_row "Service Run" "$([[ $SERVICE_RUN -eq 1 ]] && echo '✓ OK' || echo '⚠ Failed')"

TOTAL=$((GPU_DETECTED + NPU_DETECTED + CONTAINER_OK + WEBUI_STATUS + SERVICE_RUN))
MAX=5
PERCENTAGE=$((TOTAL * 100 / MAX))

BAR_SIZE=20
FILLED=$((BAR_SIZE * TOTAL / MAX))
EMPTY=$((BAR_SIZE - FILLED))
BAR=""
for ((i=0; i<FILLED; i++)); do BAR="${BAR}█"; done
for ((i=0; i<EMPTY; i++)); do BAR="${BAR}░"; done

print_table_row "Overall Score" "$PERCENTAGE% ($TOTAL/$MAX)"
print_table_row "Progress" "$BAR"
print_table_footer

echo
echo -e "${GREEN}${BOLD}✓ Diagnostics complete. Log saved to: $LOG_FILE${NC}"
echo
