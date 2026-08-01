FROM public.ecr.aws/docker/library/python:3.11-slim AS builder

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir --target=/app/deps -r requirements.txt

FROM public.ecr.aws/docker/library/python:3.11-slim

RUN useradd --create-home appuser
WORKDIR /app

COPY --from=builder /app/deps /app/deps
COPY . .

ENV PYTHONPATH="/app/deps:${PYTHONPATH}"
ENV PYTHONUNBUFFERED=1
ENV STREAMLIT_SERVER_PORT=8501
ENV STREAMLIT_SERVER_ADDRESS=0.0.0.0
ENV STREAMLIT_SERVER_HEADLESS=true
ENV STREAMLIT_GLOBAL_DEVELOPMENT_MODE=false
ENV STREAMLIT_BROWSER_GATHER_USAGE_STATS=false

USER appuser
EXPOSE 8501

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8501/_stcore/health')"

CMD ["python", "-m", "streamlit", "run", "app.py"]
