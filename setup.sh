#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"
COMPOSE_TEMPLATE="$SCRIPT_DIR/docker-compose.template.yml"

# ── Helpers ────────────────────────────────────────────────────────────────────
hr()     { echo ""; echo "──────────────────────────────────────────────────────"; }
banner() { hr; printf "  %s\n" "$1"; hr; echo ""; }

# ── Step 1: Install Intel GPU / NPU host drivers ───────────────────────────────
banner "Step 1/4 — Install Intel GPU / NPU host drivers"
echo "Running the Open Edge Platform main installer (requires sudo)..."
echo "Source: https://github.com/open-edge-platform/edge-developer-kit-reference-scripts"
echo ""

sudo bash -c "$(wget -qLO - https://raw.githubusercontent.com/open-edge-platform/edge-developer-kit-reference-scripts/refs/heads/main/main_installer.sh)"

if [[ -f /var/run/reboot-required ]]; then
    echo ""
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║  REBOOT REQUIRED                                    ║"
    echo "║                                                     ║"
    echo "║  The driver installer updated system components     ║"
    echo "║  (e.g. the kernel) that require a reboot before    ║"
    echo "║  the new drivers become active.                     ║"
    echo "║                                                     ║"
    echo "║  Please reboot now and then re-run this script:     ║"
    echo "║    sudo reboot                                      ║"
    echo "║    bash setup.sh                                    ║"
    echo "╚══════════════════════════════════════════════════════╝"
    echo ""
    exit 0
fi

echo "Note: A reboot may still be required even if no flag was detected."
echo "      If GPU/NPU devices are not found in later steps, reboot and re-run."
echo ""

# ── Step 2: Verify Docker Engine + Compose plugin ─────────────────────────────
banner "Step 2/4 — Check Docker installation"

DOCKER_MISSING=false

if ! command -v docker &>/dev/null; then
    DOCKER_MISSING=true
elif ! docker compose version &>/dev/null 2>&1; then
    DOCKER_MISSING=true
fi

if $DOCKER_MISSING; then
    echo "ERROR: Docker Engine (with the Compose plugin) is not installed or not accessible."
    echo ""
    echo "Please install Docker, then re-run this script:"
    echo ""
    echo "  Official guide : https://docs.docker.com/engine/install/"
    echo "  Quick install  : curl -fsSL https://get.docker.com | sudo sh"
    echo "                   sudo usermod -aG docker \$USER"
    echo "                   (log out and back in after adding yourself to the docker group)"
    echo ""
    exit 1
fi

echo "Docker         : $(docker --version)"
echo "Docker Compose : $(docker compose version)"
echo "Status         : OK"

# ── Step 3: Detect Intel GPU and NPU ──────────────────────────────────────────
banner "Step 3/4 — Detect Intel GPU / NPU hardware"

HAS_GPU=false
HAS_NPU=false

if [[ -e /dev/dri ]]; then
    echo "[GPU] Intel GPU detected  — /dev/dri is present"
    HAS_GPU=true
else
    echo "[GPU] No GPU detected     — /dev/dri not found"
fi

if [[ -e /dev/accel ]]; then
    echo "[NPU] Intel NPU detected  — /dev/accel is present"
    HAS_NPU=true
else
    echo "[NPU] No NPU detected     — /dev/accel not found"
fi

if ! $HAS_GPU && ! $HAS_NPU; then
    echo ""
    echo "Note: If you just installed drivers and hardware is not detected,"
    echo "      reboot the system and re-run this script."
fi

# ── Step 4: Update docker-compose.yml for detected hardware ───────────────────
banner "Step 4/4 — Configure docker-compose.yml"

# Always regenerate docker-compose.yml from the template so each run is clean.
if [[ ! -f "$COMPOSE_TEMPLATE" ]]; then
    echo "ERROR: Template not found: $COMPOSE_TEMPLATE"
    exit 1
fi
cp "$COMPOSE_TEMPLATE" "$COMPOSE_FILE"
echo "Generated       : docker-compose.yml (from docker-compose.template.yml)"

if $HAS_GPU || $HAS_NPU; then
    # Resolve the host render group ID (required for GPU DRM render access)
    RENDER_GROUP_ID=$(getent group render | awk -F: '{printf "%s\n", $3}')
    if [[ -z "$RENDER_GROUP_ID" ]]; then
        echo "Warning: 'render' group not found on this system — defaulting to GID 992."
        RENDER_GROUP_ID=992
    fi
    echo "Render group ID : $RENDER_GROUP_ID"

    # Write / update .env so docker compose resolves RENDER_GROUP_ID at runtime
    ENV_FILE="$SCRIPT_DIR/.env"
    if [[ -f "$ENV_FILE" ]] && grep -q '^RENDER_GROUP_ID=' "$ENV_FILE"; then
        sed -i "s/^RENDER_GROUP_ID=.*/RENDER_GROUP_ID=$RENDER_GROUP_ID/" "$ENV_FILE"
    else
        echo "RENDER_GROUP_ID=$RENDER_GROUP_ID" >> "$ENV_FILE"
    fi
    echo "Written         : .env  (RENDER_GROUP_ID=$RENDER_GROUP_ID)"

    # Uncomment the top-level keys (always required when any accelerator is present)
    sed -i 's|^    # devices:.*$|    devices:|'   "$COMPOSE_FILE"
    sed -i 's|^    # group_add:.*$|    group_add:|' "$COMPOSE_FILE"

    # Uncomment the render group line (uses the docker compose variable reference as-is)
    sed -i 's|^    #   - \${RENDER_GROUP_ID.*$|      - ${RENDER_GROUP_ID:-992}|' "$COMPOSE_FILE"

    # Uncomment device nodes for whichever accelerators are present
    if $HAS_GPU; then
        sed -i 's|^    #   - "/dev/dri:/dev/dri".*$|      - "/dev/dri:/dev/dri"|' "$COMPOSE_FILE"
        echo "Enabled         : GPU passthrough  (/dev/dri)"
    fi

    if $HAS_NPU; then
        sed -i 's|^    #   - "/dev/accel:/dev/accel".*$|      - "/dev/accel:/dev/accel"|' "$COMPOSE_FILE"
        echo "Enabled         : NPU passthrough  (/dev/accel)"
    fi

    echo "Updated         : docker-compose.yml"
else
    echo "No GPU or NPU detected — docker-compose.yml generated in CPU-only mode."
    echo ""
    echo "If you believe GPU/NPU hardware should be present:"
    echo "  1. Reboot: sudo reboot"
    echo "  2. Re-run: bash setup.sh"
fi

# ── Done ───────────────────────────────────────────────────────────────────────
banner "Setup complete"
echo "Start Edge AI Demo Studio with:"
echo ""
echo "  docker compose up -d"
echo ""
echo "Web UI: http://localhost:8080"
echo ""
