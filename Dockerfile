# syntax=docker/dockerfile:1

##############################################
# Stage 1: build
##############################################
# bookworm-slim is used because it shares glibc with the cc-debian12 distroless
# image of the final stage: the Python that 'uv' installs is dynamically linked
# and must find the same ABI at the destination.
FROM debian:bookworm-slim AS builder

# 'uv' is copied from its official image instead of downloaded with curl:
# reproducible (pinned version) and needs neither network nor certificates.
COPY --from=ghcr.io/astral-sh/uv:0.11.21 /uv /usr/local/bin/uv

# UV_PYTHON_INSTALL_DIR: known, copyable location for the interpreters.
# UV_TOOL_DIR:           location of the tool's virtual environment.
# UV_TOOL_BIN_DIR:       location of the executable launchers.
# UV_PYTHON_INSTALL_MIRROR is left alone; the default index is used.
ENV UV_PYTHON_INSTALL_DIR=/opt/python \
    UV_TOOL_DIR=/opt/tools \
    UV_TOOL_BIN_DIR=/opt/bin \
    UV_LINK_MODE=copy \
    UV_COMPILE_BYTECODE=1 \
    UV_PYTHON_DOWNLOADS=manual

# The Python version is pinned explicitly so the image is reproducible and so we
# know the exact path to copy in the final stage.
ARG PYTHON_VERSION=3.13.7
RUN uv python install "${PYTHON_VERSION}"

WORKDIR /src
COPY pyproject.toml uv.lock main.py ./

# --python: forces the managed interpreter we just installed to be used, not a
#           system one (which does not exist in the final image).
# The tool environment ends up in /opt/tools/pepe and its launcher in
# /opt/bin/pepe.
RUN uv tool install --python "${PYTHON_VERSION}" --no-cache .

# Prune what is unused at runtime. Done here, before the copies, so the final
# image never contains these files at all.
#
# What is removed and why:
#   libpython*.so    a copy of the interpreter, only useful for embedding it
#   tcl/tk, tkinter  GUI toolkit: there is no X server
#   ensurepip, pip   the final image is immutable
#   include, *.a     only needed to compile extensions
#   share/terminfo   there is no interactive terminal
#
# libpython3.13.so.1.0 (33 MB) is the single biggest saving: it is a second full
# copy of the interpreter, meant for embedding Python into another program. The
# bin/python3.13 binary does not link against it (it is absent from its 'ldd')
# and no lib-dynload module needs it, so it is dead weight. Verify with:
#     docker run --rm --entrypoint /bin/sh pepe:builder -c 'ldd /opt/python/*/bin/python3.13'
#
# Note: current uv builds already ship without the standard library's 'test/'
# directory, which is why it does not appear here.
ARG PRUNE=1
RUN set -eu; \
    if [ "${PRUNE}" != "1" ]; then echo "pruning skipped"; exit 0; fi; \
    PY_ROOT="$(dirname "$(dirname "$(readlink -f /opt/tools/pepe/bin/python)")")"; \
    cd "${PY_ROOT}"; \
    rm -f lib/libpython3*.so lib/libpython3*.so.*; \
    rm -rf lib/tcl* lib/tk* lib/thread* lib/itcl* \
           lib/libtcl* lib/libtk* \
           lib/python3.13/tkinter lib/python3.13/idlelib \
           lib/python3.13/turtledemo lib/python3.13/lib-dynload/_tkinter*.so \
           bin/idle*; \
    rm -rf lib/python3.13/ensurepip bin/pip*; \
    rm -rf include share/man lib/pkgconfig lib/python3.13/config-*; \
    find . -name '*.a' -delete; \
    rm -rf share/terminfo

# Check inside the build stage itself: if pruning removed something essential,
# the build fails here instead of producing a broken image. The modules the
# project actually relies on are imported.
RUN /opt/bin/pepe \
    && /opt/tools/pepe/bin/python -c "import ssl, httpx, encodings, sysconfig; print('pruning verified')"

##############################################
# Stage 2: final distroless image
##############################################
# cc-debian12 provides glibc, libgcc and libssl, which are the standalone
# interpreter's dynamic dependencies. The :static variant would not work.
FROM gcr.io/distroless/cc-debian12:nonroot

# The uv-managed interpreter.
COPY --from=builder /opt/python /opt/python
# The tool's virtual environment (includes httpx and the project itself).
COPY --from=builder /opt/tools /opt/tools
# The executable launchers (bin/pepe).
COPY --from=builder /opt/bin /opt/bin

# The launcher in /opt/bin is a script with a shebang; distroless has no shell
# interpreter, but the shebang points straight at the virtual environment's
# python, so the kernel resolves it without needing sh.
ENV PATH="/opt/bin:$PATH" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

ENTRYPOINT ["/opt/bin/pepe"]
