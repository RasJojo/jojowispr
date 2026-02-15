# WisprLocal

Local voice transcription using [faster-whisper](https://github.com/SYSTRAN/faster-whisper) with GPU acceleration. Push-to-talk dictation that transcribes speech and inserts text into any application — no cloud services required.

## Architecture

```
┌──────────────────────────┐
│   Backend (FastAPI)      │  Docker + NVIDIA CUDA
│   faster-whisper GPU     │  Port 8010
└────────────┬─────────────┘
             │ POST /transcribe
      ┌──────┼──────┐
      │      │      │
   macOS   Client  Frontend
   App     Mac     (Web)
  (Swift)  (CLI)   (Vite)
```

- **backend/** — Transcription API (FastAPI + faster-whisper)
- **macos/** — Native macOS menu bar app (SwiftUI, push-to-talk with overlay)
- **client-mac/** — Python CLI push-to-talk client
- **frontend/** — Web interface for testing
- **scripts/** — Build, install and debug helper scripts for the macOS app

## Prerequisites

- Docker with NVIDIA GPU support ([nvidia-container-toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html))
- Xcode (for the macOS app)
- Python 3.9+ (for the CLI client)
- Node.js (for the web frontend)

## Installation

### 1. Backend (GPU server)

```bash
cp .env.example .env
# Edit .env with your API key and preferences

docker compose -f docker-compose.server.yml up -d --build
```

Check that it's running:

```bash
curl http://localhost:8010/health
```

### 2. macOS app (recommended)

A native menu bar app is available in `macos/WisprLocal/`. The fastest way to install it:

```bash
./scripts/macos_install_release.sh
```

The script will:
- Build the app in Release mode
- Prompt for server URL, language, and API key
- Store the API key in Keychain
- Codesign and install to `/Applications`
- Open macOS privacy settings for Microphone and Accessibility permissions

Alternatively, open `macos/WisprLocal/WisprLocal.xcodeproj` in Xcode and build manually.

**Default hotkeys:**
- Hold-to-talk: `⌥ Space`
- Toggle dictation: `⌥ ⇧ Space`

**Settings** (accessible from the menu bar icon):
- Server URL and API key
- Language (auto-detect, fr, en, es, de, it)
- Insertion mode (type or paste)
- Pause media while dictating
- Smart formatting (voice punctuation commands)

> Note: the "Pause media" option uses the private MediaRemote framework — this build is for personal use (not App Store compatible).

### 3. CLI client (alternative)

```bash
cd client-mac
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt

python wispr_client.py --api-key "your-key" --language fr
```

Hold **F8** to talk, release to transcribe and paste.

```bash
# Options
python wispr_client.py --hotkey f9 --dry-run --server-url http://192.168.1.100:8010/transcribe
```

### 4. Web frontend

```bash
cd frontend
npm install
npm run dev
```

Open http://localhost:5173, set the endpoint to `http://<SERVER_IP>:8010/transcribe` and the API key.

## API

### `GET /health`

Returns model status and device config.

### `POST /transcribe`

| Parameter | Type | Description |
|-----------|------|-------------|
| `file` | form-data | Audio file (wav, webm, etc.) |
| `language` | query | Force language (optional) |
| `task` | query | `transcribe` or `translate` |
| `X-API-Key` | header | API key (if configured) |

## Configuration (.env)

| Variable | Default | Description |
|----------|---------|-------------|
| `WISPR_PORT` | `8010` | Exposed port |
| `MODEL_SIZE` | `large-v3` | Whisper model |
| `WHISPER_DEVICE` | `cuda` | `cuda` or `cpu` |
| `WHISPER_COMPUTE_TYPE` | `float16` | GPU precision |
| `WHISPER_BEAM_SIZE` | `1` | Beam size (1 = fast) |
| `WHISPER_VAD_FILTER` | `true` | Voice activity filter |
| `WISPR_API_KEY` | — | Authentication key |

## Helper scripts

| Script | Description |
|--------|-------------|
| `scripts/macos_install_release.sh` | Build, sign, and install the macOS app |
| `scripts/macos_setup_and_run.sh` | Dev setup and run |
| `scripts/macos_show_wispr_logs.sh` | Stream app logs |
| `scripts/macos_capture_wispr_debug.sh` | Capture debug info |
| `scripts/macos_reset_accessibility.sh` | Reset accessibility permissions |
