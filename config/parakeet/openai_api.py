"""OpenAI-compatible STT facade over Parakeet TDT 0.6B v3 (onnx-asr).

Open WebUI's "OpenAI" speech-to-text engine posts the recording to one endpoint
on its configured base URL, so that is what this serves:

    POST /v1/audio/transcriptions   multipart: file, model, language -> {"text": ...}

`language` is accepted and ignored. Parakeet v3 has no language conditioning -
it was trained on 25 European languages and picks one acoustically - which is
the point here: whisper's failure mode on a short French clip is to decide the
audio is English and transliterate it, and there is no such decision to get
wrong. Nothing has to be configured when someone dictates a sentence in English.

Transcription is CPU-bound and holds the GIL, hence the single worker and the
lock: on this Pi the point is to never take more than the three cores llama-cpp
is already sharing.
"""

from __future__ import annotations

import logging
import os
import subprocess
import threading
from contextlib import asynccontextmanager

import numpy as np
import onnx_asr
import onnxruntime as ort
from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import JSONResponse

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("parakeet-openai")

MODEL_NAME = os.environ.get("PARAKEET_MODEL", "nemo-parakeet-tdt-0.6b-v3")
# Empty string means fp32; see the build arg of the same name in the Dockerfile.
QUANTIZATION = os.environ.get("PARAKEET_QUANTIZATION", "int8") or None
# Matches the cpuset in compose/ai.yaml. Left to onnxruntime it would size the pool
# from the host's core count and oversubscribe the cgroup.
THREADS = int(os.environ.get("PARAKEET_THREADS", "3"))
SAMPLE_RATE = 16000
# A long upload is transcribed in windows rather than in one pass. This ONNX
# export degrades sharply past ~30s of audio in a single call - it stops
# transcribing part of it. Measured against 57s of continuous French, one
# speaker, with a known reference of 163 words:
#
#   window   words returned   WER
#     10s        157          20.2%
#     20s        162          15.3%
#     30s        160          16.6%
#     60s         75          73.0%   <- half the audio simply missing
#
# 20s sits at the bottom of that curve with margin before the cliff, and keeps
# the encoder's working set near 1.3GB; a single 120s pass took the container
# past 2GB and the kernel killed it. A dictated sentence is one window and
# reaches none of this.
CHUNK_SECONDS = int(os.environ.get("PARAKEET_CHUNK_SECONDS", "20"))
# How far either side of a window boundary to hunt for a quiet frame to cut on.
# Cutting mid-word costs the word, and worse, leaves the next window opening on
# half a syllable: Parakeet picks its language acoustically, and a window that
# starts without context is the one that comes back in English ("It has de
# nombreuses repercussions"). Aligning the cut to a pause is a few lines of
# numpy here rather than a second model to load and feed, and on 113s of French
# spliced to cut badly on purpose it took the transcript from 33.7% WER to 19.5%.
CHUNK_SEARCH_SECONDS = float(os.environ.get("PARAKEET_CHUNK_SEARCH_SECONDS", "2.5"))
# open-webui splits anything over 25MB itself before it gets here.
MAX_UPLOAD_BYTES = int(os.environ.get("PARAKEET_MAX_UPLOAD_BYTES", str(64 * 1024 * 1024)))

_model = None
_infer_lock = threading.Lock()


def load_model():
    """Load once, at startup, and keep resident.

    Deliberately not lazy: it costs ~5s, and paying that on the first press of
    the microphone button reads as the feature being broken. Uvicorn does not
    accept connections until this returns, so the container's healthcheck is
    also its readiness signal.
    """
    opts = ort.SessionOptions()
    opts.intra_op_num_threads = THREADS
    opts.inter_op_num_threads = 1
    log.info("loading %s (quantization=%s, threads=%d)", MODEL_NAME, QUANTIZATION or "fp32", THREADS)
    model = onnx_asr.load_model(MODEL_NAME, quantization=QUANTIZATION, sess_options=opts)
    log.info("model ready")
    return model


@asynccontextmanager
async def lifespan(app: FastAPI):
    global _model
    _model = load_model()
    yield


app = FastAPI(title="Parakeet OpenAI-compatible STT", lifespan=lifespan)


def decode_audio(raw: bytes) -> np.ndarray:
    """Any container ffmpeg knows -> mono 16kHz float32, which is all onnx-asr takes."""
    try:
        proc = subprocess.run(
            ["ffmpeg", "-hide_banner", "-loglevel", "error", "-i", "pipe:0",
             "-f", "s16le", "-ac", "1", "-ar", str(SAMPLE_RATE), "pipe:1"],
            input=raw, capture_output=True, timeout=300,
        )
    except subprocess.TimeoutExpired:
        raise HTTPException(status_code=400, detail="Audio decoding timed out") from None

    if proc.returncode != 0:
        detail = proc.stderr.decode("utf-8", "replace").strip().splitlines()
        raise HTTPException(
            status_code=400,
            detail=f"Could not decode audio: {detail[-1] if detail else 'ffmpeg failed'}",
        )

    samples = np.frombuffer(proc.stdout, dtype=np.int16)
    if samples.size == 0:
        raise HTTPException(status_code=400, detail="Audio contains no samples")
    return samples.astype(np.float32) / 32768.0


def split_on_pauses(waveform: np.ndarray) -> list[np.ndarray]:
    """Cut into ~CHUNK_SECONDS windows, each boundary nudged to the nearest pause."""
    window = CHUNK_SECONDS * SAMPLE_RATE
    if waveform.size <= window:
        return [waveform]

    search = int(CHUNK_SEARCH_SECONDS * SAMPLE_RATE)
    frame = SAMPLE_RATE // 20  # 50ms, short enough to land inside a pause between words

    # Energy per frame, once for the whole clip: the boundary search is then a
    # slice and an argmin rather than a pass over the samples each time.
    usable = waveform.size - (waveform.size % frame)
    energy = np.abs(waveform[:usable].reshape(-1, frame)).mean(axis=1)

    chunks, start = [], 0
    while waveform.size - start > window:
        target = start + window
        lo = max(start + frame, target - search) // frame
        hi = min(waveform.size - frame, target + search) // frame
        cut = (lo + int(np.argmin(energy[lo:hi]))) * frame if hi > lo else target
        chunks.append(waveform[start:cut])
        start = cut
    chunks.append(waveform[start:])
    return chunks


def transcribe(waveform: np.ndarray) -> str:
    chunks = split_on_pauses(waveform)
    with _infer_lock:
        parts = [_model.recognize(c, sample_rate=SAMPLE_RATE) for c in chunks]
    return " ".join(p.strip() for p in parts if p and p.strip())


# Deliberately `def` and not `async def`: ffmpeg and the inference loop below are
# both blocking, and on the event loop they would hold it for the whole call -
# ~19s for a 113s recording - which is longer than the healthcheck's timeout, so
# the container would report itself unhealthy for dictating a long note. A plain
# def runs in Starlette's threadpool instead, leaving /health answerable and
# letting concurrent uploads queue on _infer_lock, which is where they belong.
@app.post("/v1/audio/transcriptions")
def transcriptions(
    file: UploadFile = File(...),
    model: str | None = Form(None),
    language: str | None = Form(None),
) -> JSONResponse:
    # Read in bounded chunks and stop one byte past the limit. `read()` then
    # checking the length buffers the whole upload first, so a body larger than
    # the container's mem_limit is an OOM kill before the check ever runs.
    chunks = []
    total = 0
    while True:
        chunk = file.file.read(1024 * 1024)
        if not chunk:
            break
        total += len(chunk)
        if total > MAX_UPLOAD_BYTES:
            raise HTTPException(status_code=413, detail="Audio file too large")
        chunks.append(chunk)
    raw = b"".join(chunks)
    if not raw:
        raise HTTPException(status_code=400, detail="Empty upload")

    waveform = decode_audio(raw)
    seconds = waveform.size / SAMPLE_RATE
    text = transcribe(waveform)
    log.info("transcribed %s (%.1fs) -> %d chars", file.filename, seconds, len(text))
    return JSONResponse({"text": text})


@app.get("/health")
def health() -> JSONResponse:
    if _model is None:
        raise HTTPException(status_code=503, detail="Model not loaded")
    return JSONResponse({"status": "ok", "model": MODEL_NAME, "quantization": QUANTIZATION or "fp32"})
