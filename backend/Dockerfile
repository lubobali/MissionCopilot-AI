# The MissionCopilot backend server image (#103 step 2.1). Built from backend/ (the build context);
# tests/unit/test_container_image.py checks every rule written here.
#
# Two stages on the same pinned Python: the venv points at that Python, so the final stage must
# have the very same one. Only the locked runtime packages are installed, the package itself not
# editable, so the final image holds the venv and nothing else: no source tree, no uv, no tests.
#
# Python 3.12.16 fixes critical CVE-2026-115557 and the image's Debian OpenSSL fixes, so this base
# skips the 7-day cooldown (security fixes are not delayed: .github/dependabot.yml).

FROM python:3.12.16-slim-trixie@sha256:b18b261e1b4974b4f321451ad5251ded85abb22c2b8b262da527dda1d031ab30 AS builder
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
# pyxform bundles ODK_Validate.jar (old Jackson and commons-io, high CVEs). The backend only reads
# workbooks (xlsx_to_dict) and the image has no Java, so it can never run: the jar does not ship
# (only the jar: pyxform imports the odk_validate module itself; container_check loads pyxform).
RUN rm /app/.venv/lib/python3.12/site-packages/pyxform/validators/odk_validate/bin/ODK_Validate.jar

FROM python:3.12.16-slim-trixie@sha256:b18b261e1b4974b4f321451ad5251ded85abb22c2b8b262da527dda1d031ab30
LABEL org.opencontainers.image.source="https://github.com/lubobali/MissionCopilot-AI" \
      org.opencontainers.image.description="MissionCopilot backend server" \
      org.opencontainers.image.licenses="MIT"
# 10120: a uid no other app on the server uses (host uids are shared by every container).
RUN groupadd --system --gid 10120 missioncopilot \
    && useradd --system --uid 10120 --gid 10120 --no-create-home --home-dir /nonexistent \
       --shell /usr/sbin/nologin missioncopilot
# Owned by root: the server's user can run the code but never change it.
COPY --from=builder /app/.venv /app/.venv
ENV PATH="/app/.venv/bin:$PATH" PYTHONUNBUFFERED=1
USER 10120:10120
EXPOSE 8110
# No curl in the image: Python asks the server itself; 127.0.0.1 stays in the allowed hosts for it.
HEALTHCHECK --interval=15s --timeout=3s --start-period=20s --retries=3 CMD ["python", "-c", "import sys, urllib.request; sys.exit(urllib.request.urlopen('http://127.0.0.1:8110/v1/health', timeout=2).status != 200)"]
# Exec form: the server is PID 1 (or under compose's init) and gets the stop signal itself.
CMD ["missioncopilot-backend"]
