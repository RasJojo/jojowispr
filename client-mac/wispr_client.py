#!/usr/bin/env python3
import argparse
import os
import subprocess
import tempfile
import threading
import wave
from typing import Optional, Union

import numpy as np
import requests
import sounddevice as sd
from pynput import keyboard


class Recorder:
    def __init__(self, sample_rate: int = 16000, channels: int = 1) -> None:
        self.sample_rate = sample_rate
        self.channels = channels
        self._frames: list[np.ndarray] = []
        self._stream: Optional[sd.InputStream] = None
        self._lock = threading.Lock()
        self._recording = False

    def _callback(self, indata, frames, time_info, status) -> None:
        del frames, time_info
        if status:
            print(f"[audio] {status}")
        with self._lock:
            if self._recording:
                self._frames.append(indata.copy())

    def start(self) -> bool:
        with self._lock:
            if self._recording:
                return False
            self._frames = []
            self._stream = sd.InputStream(
                samplerate=self.sample_rate,
                channels=self.channels,
                dtype="int16",
                callback=self._callback,
            )
            self._stream.start()
            self._recording = True
            return True

    def stop(self) -> Optional[np.ndarray]:
        with self._lock:
            if not self._recording:
                return None
            self._recording = False
            stream = self._stream
            self._stream = None

        if stream is not None:
            stream.stop()
            stream.close()

        with self._lock:
            if not self._frames:
                return None
            audio = np.concatenate(self._frames, axis=0)
            self._frames = []
            return audio


def save_wav(path: str, audio: np.ndarray, sample_rate: int, channels: int) -> None:
    audio = np.ascontiguousarray(audio.astype(np.int16))
    with wave.open(path, "wb") as wav_file:
        wav_file.setnchannels(channels)
        wav_file.setsampwidth(2)
        wav_file.setframerate(sample_rate)
        wav_file.writeframes(audio.tobytes())


def transcribe(
    server_url: str,
    audio: np.ndarray,
    sample_rate: int,
    channels: int,
    timeout: float,
    api_key: Optional[str] = None,
    language: Optional[str] = None,
) -> dict:
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=True) as tmp:
        save_wav(tmp.name, audio, sample_rate, channels)
        with open(tmp.name, "rb") as file_obj:
            files = {"file": ("audio.wav", file_obj, "audio/wav")}
            params = {"language": language} if language else None
            headers = {"X-API-Key": api_key} if api_key else None
            response = requests.post(
                server_url,
                files=files,
                params=params,
                headers=headers,
                timeout=timeout,
            )
            response.raise_for_status()
            return response.json()


def paste_text_mac(text: str) -> None:
    subprocess.run(["pbcopy"], input=text.encode("utf-8"), check=True)
    subprocess.run(
        [
            "osascript",
            "-e",
            'tell application "System Events" to keystroke "v" using command down',
        ],
        check=True,
    )


def notify(title: str, message: str) -> None:
    script = f'display notification "{message}" with title "{title}"'
    subprocess.run(["osascript", "-e", script], check=False)


def parse_hotkey(raw: str) -> Union[keyboard.Key, keyboard.KeyCode]:
    key_name = raw.strip().lower().replace("key.", "")
    if len(key_name) == 1:
        return keyboard.KeyCode.from_char(key_name)
    if hasattr(keyboard.Key, key_name):
        return getattr(keyboard.Key, key_name)
    raise ValueError(
        f"Unsupported hotkey '{raw}'. Example: f8, f9, ctrl_l, option_l, a"
    )


def key_matches(
    key: Union[keyboard.Key, keyboard.KeyCode],
    target: Union[keyboard.Key, keyboard.KeyCode],
) -> bool:
    if isinstance(target, keyboard.KeyCode):
        return (
            isinstance(key, keyboard.KeyCode)
            and key.char is not None
            and target.char is not None
            and key.char.lower() == target.char.lower()
        )
    return key == target


def main() -> None:
    parser = argparse.ArgumentParser(description="Wispr-like push-to-talk Mac client")
    parser.add_argument(
        "--server-url",
        default="http://127.0.0.1:8010/transcribe",
        help="Server transcription endpoint URL",
    )
    parser.add_argument(
        "--hotkey",
        default="f8",
        help="Hold this key to record (e.g. f8, f9, option_l, ctrl_l, a)",
    )
    parser.add_argument("--sample-rate", type=int, default=16000)
    parser.add_argument("--channels", type=int, default=1)
    parser.add_argument("--timeout", type=float, default=30.0)
    parser.add_argument("--language", default=None, help="Force language, e.g. fr, en")
    parser.add_argument(
        "--api-key",
        default=os.getenv("WISPR_API_KEY"),
        help="Optional API key. Fallback: WISPR_API_KEY env var",
    )
    parser.add_argument("--dry-run", action="store_true", help="Do not paste text")
    parser.add_argument("--no-notify", action="store_true")
    args = parser.parse_args()

    target_key = parse_hotkey(args.hotkey)
    recorder = Recorder(sample_rate=args.sample_rate, channels=args.channels)
    transcribe_lock = threading.Lock()
    held = False

    print(f"[ready] Hold '{args.hotkey}' to talk. Release to transcribe.")
    print(f"[server] {args.server_url}")

    def process_audio(audio: np.ndarray) -> None:
        with transcribe_lock:
            try:
                result = transcribe(
                    args.server_url,
                    audio,
                    args.sample_rate,
                    args.channels,
                    timeout=args.timeout,
                    api_key=args.api_key,
                    language=args.language,
                )
                text = result.get("text", "").strip()
                elapsed_ms = result.get("elapsed_ms")

                if not text:
                    print("[result] No speech detected")
                    if not args.no_notify:
                        notify("Wispr Local", "No speech detected")
                    return

                if args.dry_run:
                    print(f"[text] {text}")
                else:
                    paste_text_mac(text)
                    print(f"[pasted] {text}")

                if elapsed_ms is not None:
                    print(f"[latency] {elapsed_ms} ms")
                if not args.no_notify:
                    notify("Wispr Local", "Transcription complete")
            except Exception as exc:
                print(f"[error] {exc}")
                if not args.no_notify:
                    notify("Wispr Local", "Transcription failed")

    def on_press(key: Union[keyboard.Key, keyboard.KeyCode]) -> None:
        nonlocal held
        if key_matches(key, target_key) and not held:
            held = True
            if recorder.start():
                print("[recording] start")

    def on_release(key: Union[keyboard.Key, keyboard.KeyCode]) -> None:
        nonlocal held
        if key_matches(key, target_key) and held:
            held = False
            audio = recorder.stop()
            if audio is None or audio.size == 0:
                print("[recording] empty")
                return
            print("[recording] stop -> transcribing")
            thread = threading.Thread(target=process_audio, args=(audio,), daemon=True)
            thread.start()

    with keyboard.Listener(on_press=on_press, on_release=on_release) as listener:
        listener.join()


if __name__ == "__main__":
    main()
