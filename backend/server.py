import os
import tempfile
import time
from pathlib import Path
from typing import Optional

from fastapi import FastAPI, File, Header, HTTPException, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse
from faster_whisper import WhisperModel

MODEL_SIZE = os.getenv("MODEL_SIZE", "distil-large-v3")
DEVICE = os.getenv("WHISPER_DEVICE", "cuda")
COMPUTE_TYPE = os.getenv("WHISPER_COMPUTE_TYPE", "float16")
BEAM_SIZE = int(os.getenv("WHISPER_BEAM_SIZE", "1"))
VAD_FILTER = os.getenv("WHISPER_VAD_FILTER", "true").lower() == "true"
API_KEY = os.getenv("WISPR_API_KEY", "").strip() or None
BASE_DIR = Path(__file__).resolve().parent
TEST_PAGE = BASE_DIR / "static" / "test.html"

app = FastAPI(title="Wispr-like Local Transcription API", version="0.1.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)

model = WhisperModel(MODEL_SIZE, device=DEVICE, compute_type=COMPUTE_TYPE)


def validate_api_key(x_api_key: Optional[str]) -> None:
    if API_KEY and x_api_key != API_KEY:
        raise HTTPException(status_code=401, detail="Invalid API key")


@app.get("/health")
def health() -> dict:
    return {
        "status": "ok",
        "model": MODEL_SIZE,
        "device": DEVICE,
        "compute_type": COMPUTE_TYPE,
    }


@app.get("/test", response_class=FileResponse)
def test_page() -> FileResponse:
    if not TEST_PAGE.exists():
        raise HTTPException(status_code=404, detail="Test UI not found")
    return FileResponse(TEST_PAGE)


@app.post("/transcribe")
async def transcribe(
    file: UploadFile = File(...),
    language: Optional[str] = None,
    task: str = "transcribe",
    x_api_key: Optional[str] = Header(default=None, alias="X-API-Key"),
) -> dict:
    validate_api_key(x_api_key)
    if task not in {"transcribe", "translate"}:
        raise HTTPException(status_code=400, detail="Invalid task (use transcribe|translate)")
    suffix = os.path.splitext(file.filename or "audio.wav")[1] or ".wav"

    try:
        with tempfile.NamedTemporaryFile(delete=False, suffix=suffix) as tmp:
            audio_path = tmp.name
            content = await file.read()
            tmp.write(content)

        started = time.perf_counter()
        segments, info = model.transcribe(
            audio_path,
            language=language,
            task=task,
            beam_size=BEAM_SIZE,
            vad_filter=VAD_FILTER,
            condition_on_previous_text=False,
        )
        text = " ".join(segment.text.strip() for segment in segments).strip()
        elapsed_ms = int((time.perf_counter() - started) * 1000)

        return {
            "text": text,
            "language": info.language,
            "language_probability": info.language_probability,
            "elapsed_ms": elapsed_ms,
        }
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f"Transcription failed: {exc}") from exc
    finally:
        if "audio_path" in locals() and os.path.exists(audio_path):
            os.remove(audio_path)
