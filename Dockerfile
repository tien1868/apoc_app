FROM python:3.11-slim

# System deps for rembg (onnxruntime needs libgomp), Pillow, and general build
RUN apt-get update && apt-get install -y --no-install-recommends \
    libgomp1 \
    libglib2.0-0 \
    libgl1-mesa-glx \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install Python deps first (layer cache)
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application code
COPY app.py .

EXPOSE 8080

# Pre-download the u2netp model on build so cold starts are faster
RUN python -c "from rembg import new_session; new_session('u2netp')" || true

CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8080", "--workers", "2"]
