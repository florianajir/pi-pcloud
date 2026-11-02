# Built rather than pulled: every off-the-shelf equivalent (node-exporter,
# glances) speaks Prometheus or its own JSON, not the OpenAPI shape Open WebUI
# discovers tools from.
FROM python:3.15-slim

ENV PYTHONUNBUFFERED=1 \
    HOSTFS=/hostfs

RUN pip install --no-cache-dir \
        "fastapi==0.141.1" \
        "uvicorn==0.52.4"

COPY app.py /app/app.py
WORKDIR /app

EXPOSE 8000
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "1"]
