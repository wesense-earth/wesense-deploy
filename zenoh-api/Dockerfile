# WeSense Zenoh API — HTTP Query Frontend
# Build context: parent directory (wesense-project/)
# Build: docker build -f wesense/zenoh-api/Dockerfile -t wesense-zenoh-api .
#
# Flask app that translates REST requests into Zenoh distributed queries.
# Returns aggregated JSON from all responding stations/ingesters.

FROM python:3.11-slim

WORKDIR /app

# Copy dependency files first for better layer caching
COPY wesense-ingester-core/ /tmp/wesense-ingester-core/

# Install gcc, build all pip packages, then remove gcc in one layer
RUN apt-get update && \
    apt-get install -y --no-install-recommends gcc && \
    pip install --no-cache-dir "/tmp/wesense-ingester-core[p2p]" && \
    pip install --no-cache-dir flask waitress && \
    apt-get purge -y --auto-remove gcc && \
    rm -rf /var/lib/apt/lists/* /tmp/wesense-ingester-core

# Copy application code
COPY wesense/zenoh-api/zenoh_api.py .

# Create directories for logs
RUN mkdir -p /app/logs

ENV TZ=UTC

CMD ["python", "-u", "zenoh_api.py"]
