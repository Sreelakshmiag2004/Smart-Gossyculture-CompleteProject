# syntax=docker/dockerfile:1
#
# Targets:
#   runtime - API/ingest image: runtime dependencies only, non-root user.
#   dev     - runtime + test tooling + tests + dev bootstrap. Used ONLY by deploy/dev/compose.yaml.

FROM python:3.12.14-slim-trixie AS base
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_ROOT_USER_ACTION=ignore \
    PYTHONPATH=/app/src
RUN groupadd --system --gid 10001 gossy \
 && useradd --system --uid 10001 --gid gossy --home-dir /app --no-create-home --shell /usr/sbin/nologin gossy
WORKDIR /app

FROM base AS runtime
COPY requirements.txt constraints.txt ./
RUN pip install -r requirements.txt -c constraints.txt
COPY alembic.ini ./
COPY migrations ./migrations
COPY src ./src
USER gossy
EXPOSE 8000
CMD ["uvicorn", "--factory", "gossy.api.app:create_app", "--host", "0.0.0.0", "--port", "8000", "--no-access-log"]

FROM runtime AS dev
USER root
COPY requirements-dev.txt ./
RUN pip install -r requirements-dev.txt -c constraints.txt
COPY pyproject.toml ./
COPY docs/openapi.json ./docs/openapi.json
COPY tests ./tests
# Development/test failure-injection directory (shared volume between ingest and tests).
RUN mkdir -p /run/gossy-faults && chown gossy:gossy /run/gossy-faults
USER gossy
