FROM python:3.11-slim

WORKDIR /app

# Install deps first (layer caching)
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy source
COPY . .

# Non-root user — satisfies restricted Pod Security Standard
RUN groupadd --gid 1001 appgroup \
 && useradd --uid 1001 --gid 1001 --no-create-home appuser

USER appuser

EXPOSE 8000

HEALTHCHECK --interval=15s --timeout=5s --retries=3 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8000/healthz')"

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
