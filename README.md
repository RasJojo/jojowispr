# jojowispr

Transcription vocale locale utilisant [faster-whisper](https://github.com/SYSTRAN/faster-whisper) avec accélération GPU.

## Architecture

```
┌──────────────────────┐
│  Backend (FastAPI)   │  Docker + NVIDIA CUDA
│  faster-whisper GPU  │  Port 8010
└──────────┬───────────┘
           │ POST /transcribe
     ┌─────┴─────┐
     │           │
  Frontend    Client Mac
  (Web/Vite)  (Push-to-talk)
```

- **backend/** — API de transcription (FastAPI + faster-whisper)
- **frontend/** — Interface web pour tester (Vite, vanilla JS)
- **client-mac/** — Client macOS push-to-talk, colle le texte directement

## Prérequis

- Docker avec support NVIDIA GPU ([nvidia-container-toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html))
- Python 3.9+ (pour le client Mac)
- Node.js (pour le frontend)

## Installation

### 1. Backend (serveur GPU)

```bash
cp .env.example .env
# Éditer .env avec ta clé API et tes préférences

docker compose -f docker-compose.server.yml up -d --build
```

Vérifier que ça tourne :

```bash
curl http://localhost:8010/health
```

### 2. Frontend web

```bash
cd frontend
npm install
npm run dev
```

Ouvrir http://localhost:5173, configurer l'endpoint `http://<IP_SERVEUR>:8010/transcribe` et la clé API.

### 3. Client Mac (push-to-talk)

```bash
cd client-mac
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt

python wispr_client.py --api-key "ta-cle" --language fr
```

Maintenir **F8** pour parler, relâcher pour transcrire et coller.

Options utiles :

```bash
python wispr_client.py --hotkey f9 --dry-run --server-url http://192.168.1.100:8010/transcribe
```

## API

### `GET /health`

Retourne le statut et la config du modèle.

### `POST /transcribe`

| Paramètre | Type | Description |
|-----------|------|-------------|
| `file` | form-data | Fichier audio (wav, webm, etc.) |
| `language` | query | Langue forcée (optionnel) |
| `task` | query | `transcribe` ou `translate` |
| `X-API-Key` | header | Clé API (si configurée) |

## Configuration (.env)

| Variable | Défaut | Description |
|----------|--------|-------------|
| `WISPR_PORT` | `8010` | Port exposé |
| `MODEL_SIZE` | `large-v3` | Modèle Whisper |
| `WHISPER_DEVICE` | `cuda` | `cuda` ou `cpu` |
| `WHISPER_COMPUTE_TYPE` | `float16` | Précision GPU |
| `WHISPER_BEAM_SIZE` | `1` | Beam size (1 = rapide) |
| `WHISPER_VAD_FILTER` | `true` | Filtre d'activité vocale |
| `WISPR_API_KEY` | — | Clé d'authentification |
