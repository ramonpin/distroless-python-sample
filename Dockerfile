# syntax=docker/dockerfile:1

##############################################
# Etapa 1: construcción
##############################################
# Se usa bookworm-slim porque comparte glibc con la imagen distroless
# cc-debian12 de la etapa final: el Python que instala 'uv' está enlazado
# dinámicamente y debe encontrar el mismo ABI en destino.
FROM debian:bookworm-slim AS builder

# 'uv' se copia desde su imagen oficial en lugar de descargarlo con curl:
# es reproducible (versión fijada) y no requiere red ni certificados.
COPY --from=ghcr.io/astral-sh/uv:0.11.21 /uv /usr/local/bin/uv

# UV_PYTHON_INSTALL_DIR: ubicación conocida y copiable de los intérpretes.
# UV_TOOL_DIR:           ubicación del entorno virtual de la herramienta.
# UV_TOOL_BIN_DIR:       ubicación de los lanzadores ejecutables.
# UV_PYTHON_INSTALL_MIRROR no se toca; se usa el índice por defecto.
ENV UV_PYTHON_INSTALL_DIR=/opt/python \
    UV_TOOL_DIR=/opt/tools \
    UV_TOOL_BIN_DIR=/opt/bin \
    UV_LINK_MODE=copy \
    UV_COMPILE_BYTECODE=1 \
    UV_PYTHON_DOWNLOADS=manual

# Versión de Python fijada explícitamente para que la imagen sea reproducible
# y para conocer la ruta exacta que hay que copiar en la etapa final.
ARG PYTHON_VERSION=3.13.7
RUN uv python install "${PYTHON_VERSION}"

WORKDIR /src
COPY pyproject.toml uv.lock main.py ./

# --python: fuerza el uso del intérprete gestionado que acabamos de instalar,
#           no uno del sistema (que no existe en la imagen final).
# El entorno de la herramienta queda en /opt/tools/pepe y su lanzador
# en /opt/bin/pepe.
RUN uv tool install --python "${PYTHON_VERSION}" --no-cache .

# Poda de lo que no se usa en tiempo de ejecución. Se hace aquí, antes de las
# copias, para que la imagen final nunca contenga estos archivos.
#
# libpython3.13.so.1.0 (33 MB) es el mayor ahorro: es una segunda copia
# completa del intérprete, destinada a embeber Python en otro programa. El
# binario bin/python3.13 no la enlaza (no aparece en su 'ldd') y ningún módulo
# de lib-dynload la necesita, así que sobra. Compruébalo con:
#     docker run --rm --entrypoint /bin/sh pepe:builder -c 'ldd /opt/python/*/bin/python3.13'
#
# Nota: los builds actuales de uv ya vienen sin el directorio 'test/' de la
# biblioteca estándar, por eso no aparece aquí.
# Qué se elimina y por qué:
#   libpython*.so    copia del intérprete, solo útil para embeberlo
#   tcl/tk, tkinter  interfaz gráfica: no hay servidor X
#   ensurepip, pip   la imagen final es inmutable
#   include, *.a     solo hacen falta para compilar extensiones
#   share/terminfo   no hay terminal interactiva
ARG PRUNE=1
RUN set -eu; \
    if [ "${PRUNE}" != "1" ]; then echo "poda omitida"; exit 0; fi; \
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

# Comprobación en la propia etapa de construcción: si la poda se hubiera
# llevado algo imprescindible, la construcción falla aquí en lugar de producir
# una imagen rota. Se importan los módulos que el proyecto usa de verdad.
RUN /opt/bin/pepe \
    && /opt/tools/pepe/bin/python -c "import ssl, httpx, encodings, sysconfig; print('poda verificada')"

##############################################
# Etapa 2: imagen final distroless
##############################################
# cc-debian12 aporta glibc, libgcc y libssl, que son las dependencias
# dinámicas del intérprete standalone. La variante :static no funcionaría.
FROM gcr.io/distroless/cc-debian12:nonroot

# Intérprete gestionado por uv.
COPY --from=builder /opt/python /opt/python
# Entorno virtual de la herramienta (incluye httpx y el propio proyecto).
COPY --from=builder /opt/tools /opt/tools
# Lanzadores ejecutables (bin/pepe).
COPY --from=builder /opt/bin /opt/bin

# El lanzador de /opt/bin es un script con shebang; en distroless no hay
# intérprete de shell, pero el shebang apunta directamente al python del
# entorno virtual, por lo que el kernel lo resuelve sin necesidad de sh.
ENV PATH="/opt/bin:$PATH" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

ENTRYPOINT ["/opt/bin/pepe"]
