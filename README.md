# Edge AI Demo Studio

Edge AI Demo Studio is a toolkit for deploying, managing, and serving AI models on edge platforms. It provides a web-based UI for device, workload, and user management, optimized for Intel hardware and edge environments.

![Demo](./data/images/demo.gif)

---

## 1. Container Functional Overview

Edge AI Demo Studio packages a complete, self-contained edge AI workbench into a single container. From its web UI you can download Hugging Face models, convert them for Intel hardware, and serve them as ready-to-use inference endpoints — without building a bespoke pipeline for each model.

## 2. Container Key Features

- **Easy Model Deployment** — Download, convert, and serve Hugging Face models with minimal setup.
- **Web-Based Management** — Manage devices, workloads, and users through a modern web interface (port `8080`).
- **Edge Optimized** — Built for Intel hardware (CPU, GPU, NPU) and edge environments.
- **Ready-to-use AI Services:**
  - Text Generation (LLM)
  - Text to Speech (TTS)
  - Speech to Text (STT)
  - Embedding
  - Lipsync
  - Image Generation
  - MCP Manager
  - Wake Word Detection
- **Sample Applications** — Example use cases built on the AI services:
  - Digital Avatar
  - RAG Chat
  - [AI Exam Marking](./frontend/src/samples/ai-exam-marking/README.md)

## 3. Supported Host Device List

Edge AI Demo Studio targets **Intel platforms only**. CPU inference works on any supported Intel platform; GPU and NPU acceleration require the corresponding Intel hardware and host drivers (see Section 4).

> Non-Intel CPUs, GPUs, and accelerators (e.g. AMD, NVIDIA, Arm) are **not** supported for acceleration.

## 4. Prerequisite Software Libraries Installed on Host OS

## Requirement

- [Docker Engine](https://www.docker.com/get-started/) + Compose plugin

## Quick Start Guide

### 1. Run the Setup Script

```bash
bash setup.sh
```

This script will:

- Install Intel GPU / NPU host drivers via the [Open Edge Platform installer](https://github.com/open-edge-platform/edge-developer-kit-reference-scripts)
- Verify that Docker Engine (with the Compose plugin) is installed; if not, it prints install instructions and exits
- Detect Intel GPU (`/dev/dri`) and NPU (`/dev/accel`) and automatically enable hardware acceleration in `docker-compose.yml`

> **Reboot required after driver install** — The Open Edge Platform installer may update the kernel or other system components. When this happens the script will detect a reboot-required flag and exit with clear instructions. **Reboot the system and re-run `bash setup.sh`** — the second run will detect your GPU/NPU and configure `docker-compose.yml` automatically. Even if no flag is detected, a reboot is recommended before starting the container if drivers were just installed.

### 2. Start the App

```bash
docker compose up -d
```

Once started, access the web UI at [http://localhost:8080](http://localhost:8080).

### 3. Persistent data

The following Docker volumes persist across restarts:

| Volume   | Mount                 | Contents                      |
| -------- | --------------------- | ----------------------------- |
| `models` | `/home/ubuntu/models` | Downloaded & converted models |
| `logs`   | `/home/ubuntu/logs`   | Application logs              |
| `db`     | `/home/ubuntu/data`   | SQLite database               |

### Architecture Diagram

![Architecture Diagram](./data/images/Architecture.png)

## 8. Best Practice / Known Limitations

**Best practices:**

- Pre-pull the image before deployment: `docker compose pull`.
- Allocate enough RAM and storage for the largest model you intend to run; model conversion needs temporary headroom.
- Use the `models` volume so converted models survive container restarts and upgrades.
- Verify host GPU/NPU drivers are installed and the device nodes (`/dev/dri`, `/dev/accel`) exist before enabling acceleration.

**Known limitations:**

- **Intel hardware only** — GPU/NPU acceleration is not available on non-Intel platforms; such hosts fall back to CPU inference.
- NPU acceleration requires Intel® Core™ Ultra (Meteor Lake) or newer.
- GPU acceleration requires the host render group to be passed into the container.
