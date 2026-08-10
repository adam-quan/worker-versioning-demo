FROM python:3.12-slim

# The Build ID is baked in at image build time by CI. It is the single value
# that distinguishes this Worker Deployment Version from every other one.
ARG BUILD_ID=unversioned
ENV TEMPORAL_BUILD_ID=${BUILD_ID}
ENV PYTHONUNBUFFERED=1

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY activities.py workflows.py run_worker.py starter.py ./

# Run unprivileged so SIGTERM-based draining behaves like a normal workload.
RUN useradd --create-home --uid 10001 worker
USER worker

CMD ["python", "run_worker.py"]
