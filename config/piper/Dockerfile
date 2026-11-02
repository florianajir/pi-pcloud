# Piper TTS (OHF-Voice/piper1-gpl) behind an OpenAI-compatible facade.
#
# Upstream publishes no image, and its own HTTP server speaks its own protocol
# (POST / + GET /voices) rather than the /v1/audio/speech shape Open WebUI's
# "OpenAI" TTS engine calls. openai_api.py is that translation layer; it uses
# Piper's Python API directly, so this stays a single process.
FROM python:3.15-slim

# piper-tts publishes a manylinux aarch64 wheel, so nothing is compiled here and
# the image builds in seconds on the Pi. Pinned, like every other image here.
ARG PIPER_VERSION=1.7.0

# Baked into the image rather than downloaded at start: the ai network is
# internal, and three voices are only ~180MB. fr_FR-siwis-medium is the usual
# French reference voice (female), tom is male, upmc is a second female with a
# different timbre. en_US-lessac-medium is there so English text in a reply does
# not get read with a French phonemiser.
ARG VOICES="fr_FR-siwis-medium fr_FR-tom-medium fr_FR-upmc-medium en_US-lessac-medium"

ENV PIPER_VOICE_DIR=/voices \
    PYTHONUNBUFFERED=1

RUN pip install --no-cache-dir \
        "piper-tts==${PIPER_VERSION}" \
        "fastapi==0.141.1" \
        "uvicorn==0.52.4"

RUN mkdir -p "$PIPER_VOICE_DIR" \
    && for voice in $VOICES; do \
        python3 -m piper.download_voices "$voice" --data-dir "$PIPER_VOICE_DIR"; \
    done

COPY openai_api.py /app/openai_api.py
WORKDIR /app

# Non-root: it only reads the baked-in voices and writes to an in-memory buffer.
RUN useradd --system --no-create-home --shell /usr/sbin/nologin app
USER app

EXPOSE 8000
CMD ["uvicorn", "openai_api:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "1"]
