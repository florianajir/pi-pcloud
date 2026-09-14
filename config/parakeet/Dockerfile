# Parakeet TDT 0.6B v3 (NVIDIA) behind an OpenAI-compatible facade.
#
# Speech-to-text for open-webui's microphone button, split out of the open-webui
# container so the model is sized against its own limit rather than that
# container's 1g - see the parakeet service in compose/ai.yaml for the numbers that
# ruled out the bundled faster-whisper.
FROM python:3.14-slim

# int8 by default: 8.7% WER against fp32's 4.5%, but 1.2GB resident instead of
# 2.3GB and a ~660MB model in the image instead of ~2.5GB. Build with
# --build-arg PARAKEET_QUANTIZATION= (empty) for fp32; the runtime default below
# follows this, so the weights baked in are the weights loaded.
ARG PARAKEET_QUANTIZATION=int8

# Pinned like every other image here. onnx-asr is the runtime wrapper (it owns
# the mel frontend and the TDT decode loop); onnxruntime ships an aarch64 wheel,
# so nothing is compiled.
ARG ONNX_ASR_VERSION=0.12.0

# Uploads arrive as whatever the browser's MediaRecorder produced - webm/opus,
# mp4, or an mp3 open-webui transcoded - and onnx-asr only reads wav. ffmpeg is
# the decoder; see openai_api.py.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ffmpeg \
    && rm -rf /var/lib/apt/lists/*

ENV HF_HOME=/models \
    PARAKEET_QUANTIZATION=${PARAKEET_QUANTIZATION} \
    PYTHONUNBUFFERED=1

RUN pip install --no-cache-dir \
        "onnx-asr[cpu,hub]==${ONNX_ASR_VERSION}" \
        "fastapi==0.141.1" \
        "uvicorn==0.52.4" \
        "python-multipart==0.0.32"

# Baked into the image rather than fetched at start, like piper's voices: the ai
# network is internal and a container that has to reach huggingface.co before it
# can answer is a container that breaks when the WAN does. Loading the model is
# also the build's own smoke test - a bad quantization arg fails here, not at
# three in the morning.
RUN python3 -c "import onnx_asr, os; \
onnx_asr.load_model('nemo-parakeet-tdt-0.6b-v3', \
                    quantization=os.environ['PARAKEET_QUANTIZATION'] or None)"

# Nothing above needs the network again, and a stray download at runtime would
# stall the microphone button rather than fail loudly.
ENV HF_HUB_OFFLINE=1

COPY openai_api.py /app/openai_api.py
WORKDIR /app

# Non-root: it only reads the baked-in model. HF_HUB_OFFLINE above keeps onnx_asr
# off the cache, and decode_audio pipes through ffmpeg rather than a temp file.
RUN useradd --system --no-create-home --shell /usr/sbin/nologin app
USER app

EXPOSE 8000
CMD ["uvicorn", "openai_api:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "1"]
