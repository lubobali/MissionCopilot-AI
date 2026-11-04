# The MissionCopilot backend server image (#103 step 2.1). Built from backend/ (the build context);
# tests/unit/test_container_image.py checks every rule written here.
#
# Two stages on the same pinned Python: the venv points at that Python, so the final stage must
# have the very same one. Only the locked runtime packages are installed, the package itself not
# editable, so the final image holds the venv and nothing else: no source tree, no uv, no tests.

FROM python:3.12.14-slim-trixie@sha256:f77ac9e44ae96ef2c90b8053ea08c31f8be030f824196b0ae4db6d462c84e51f AS builder
COPY --from=ghcr.io/astral-sh/uv:0.13.6@sha256:af22a52f5eafef3d78e551599d405c02df61919d18028f0cea8eda93bc9986d0 /uv /bin/uv
ENV UV_COMPILE_BYTECODE=1 UV_LINK_MODE=copy UV_PYTHON_DOWNLOADS=0 UV_NO_DEV=1
WORKDIR /app
# Dependencies first (only the lockfile decides them), so a code change reuses this layer.
RUN --mount=type=cache,target=/root/.cache/uv \
    --mount=type=bind,source=uv.lock,target=uv.lock \
    --mount=type=bind,source=pyproject.toml,target=pyproject.toml \
    uv sync --locked --no-install-project --no-editable
COPY pyproject.toml uv.lock README.md ./
COPY src ./src
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --locked --no-editable

FROM python:3.12.14-slim-trixie@sha256:f77ac9e44ae96ef2c90b8053ea08c31f8be030f824196b0ae4db6d462c84e51f
LABEL org.opencontainers.image.source="https://github.com/lubobali/MissionCopilot-AI" \
      org.opencontainers.image.description="MissionCopilot backend server" \
      org.opencontainers.image.licenses="MIT"
RUN groupadd --system --gid 10001 missioncopilot \
    && useradd --system --uid 10001 --gid 10001 --no-create-home --home-dir /nonexistent \
       --shell /usr/sbin/nologin missioncopilot
# Owned by root: the server's user can run the code but never change it.
COPY --from=builder /app/.venv /app/.venv
ENV PATH="/app/.venv/bin:$PATH" PYTHONUNBUFFERED=1
USER 10001:10001
EXPOSE 8110
# No curl in the image: Python asks the server itself; 127.0.0.1 stays in the allowed hosts for it.
HEALTHCHECK --interval=15s --timeout=3s --start-period=20s --retries=3 CMD ["python", "-c", "import sys, urllib.request; sys.exit(urllib.request.urlopen('http://127.0.0.1:8110/v1/health', timeout=2).status != 200)"]
# Exec form: the server is PID 1 (or under compose's init) and gets the stop signal itself.
CMD ["missioncopilot-backend"]
