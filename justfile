IMAGE := "pepe"
TAG := "latest"
PYTHON_VERSION := "3.13.7"

# Lista las recetas disponibles.
default:
    @just --list

# Construye la imagen.
build:
    docker build \
        --build-arg PYTHON_VERSION={{PYTHON_VERSION}} \
        -t {{IMAGE}}:{{TAG}} .

# Construye sin usar la caché de capas.
rebuild:
    docker build --no-cache \
        --build-arg PYTHON_VERSION={{PYTHON_VERSION}} \
        -t {{IMAGE}}:{{TAG}} .

# Ejecuta la herramienta en un contenedor. Acepta argumentos: just run --help
run *ARGS:
    docker run --rm {{IMAGE}}:{{TAG}} {{ARGS}}

# Comprueba que el punto de entrada arranca y devuelve la salida esperada.
test-entrypoint:
    #!/usr/bin/env bash
    set -euo pipefail
    salida="$(docker run --rm {{IMAGE}}:{{TAG}})"
    echo "${salida}"
    if [[ "${salida}" != "Hola mundo!!" ]]; then
        echo "FALLO: salida inesperada del punto de entrada" >&2
        exit 1
    fi
    echo "OK: punto de entrada"

# Comprueba que el intérprete y las dependencias nativas (SSL) funcionan.
test-deps:
    #!/usr/bin/env bash
    # Esta es la prueba que de verdad valida la imagen distroless: si faltara
    # alguna biblioteca dinámica o los certificados, fallaría aquí y no en el
    # punto de entrada.
    set -euo pipefail
    docker run --rm --entrypoint /opt/tools/pepe/bin/python {{IMAGE}}:{{TAG}} -c '
    import ssl, sys
    import httpx
    print("python", sys.version.split()[0])
    print("httpx ", httpx.__version__)
    print(ssl.OPENSSL_VERSION)
    r = httpx.get("https://example.com")
    assert r.status_code == 200, r.status_code
    print("peticion HTTPS:", r.status_code)
    '
    echo "OK: interprete y dependencias"

# Comprueba que la poda del Dockerfile no ha roto la biblioteca estándar.
test-stdlib:
    #!/usr/bin/env bash
    set -euo pipefail
    docker run --rm --entrypoint /opt/tools/pepe/bin/python {{IMAGE}}:{{TAG}} -c '
    import importlib
    modulos = ["venv", "pydoc", "sqlite3", "ssl", "ctypes", "multiprocessing",
               "asyncio", "xml.etree.ElementTree", "concurrent.futures",
               "http.server", "logging.handlers", "pickle", "socket",
               "subprocess", "tempfile", "uuid", "zoneinfo", "decimal",
               "lzma", "bz2", "zlib", "hashlib", "email", "unittest"]
    roto = []
    for m in modulos:
        try:
            importlib.import_module(m)
        except Exception as e:
            roto.append(f"{m}: {type(e).__name__}: {e}")
    if roto:
        raise SystemExit("modulos rotos por la poda:\n" + "\n".join(roto))
    print(f"{len(modulos)} modulos importados sin error")
    '
    echo "OK: biblioteca estandar intacta"

# Ejecuta todas las comprobaciones. Requiere red para test-deps.
test: test-entrypoint test-deps test-stdlib
    @echo "OK: todas las comprobaciones"

# Construye y comprueba de una pasada.
verify: build test

# Construye sin la poda de tamaño, para comparar.
build-unpruned:
    docker build \
        --build-arg PYTHON_VERSION={{PYTHON_VERSION}} \
        --build-arg PRUNE=0 \
        -t {{IMAGE}}:unpruned .

# Compara el tamaño con y sin poda.
compare: build build-unpruned
    @docker images {{IMAGE}} --format '{{{{.Tag}}\t{{{{.Size}}' | grep -E 'latest|unpruned'

# Muestra el tamaño de la imagen y sus capas.
size:
    @docker images {{IMAGE}}:{{TAG}} --format 'imagen: {{{{.Size}}'
    @docker history {{IMAGE}}:{{TAG}} --human --format '{{{{.Size}}\t{{{{.CreatedBy}}' | head -20

# Abre una shell en la etapa de construcción (la imagen final no tiene shell).
debug:
    docker build --target builder -t {{IMAGE}}:builder .
    docker run --rm -it --entrypoint /bin/bash {{IMAGE}}:builder

# Elimina todas las imágenes del proyecto, cualquiera que sea su etiqueta.
clean:
    #!/usr/bin/env bash
    # Las imágenes se descubren por repositorio en lugar de enumerar etiquetas
    # a mano: así no hay que actualizar esta receta cada vez que otra genere
    # una etiqueta nueva (latest, builder, unpruned...). El filtro 'reference'
    # compara el repositorio completo, por lo que no toca imágenes de nombre
    # parecido como 'otropepe' o 'pepe-otroproyecto'.
    set -euo pipefail
    imagenes="$(docker images --filter reference='{{IMAGE}}' --format '{{{{.Repository}}:{{{{.Tag}}' | grep -v '<none>' || true)"
    if [[ -z "${imagenes}" ]]; then
        echo "no hay imagenes de {{IMAGE}} que borrar"
    else
        echo "${imagenes}" | xargs -r docker rmi -f
    fi

# Elimina las imágenes y, tras confirmar, TODA la caché de BuildKit del equipo.
clean-all: clean
    #!/usr/bin/env bash
    # No se puede acotar el prune a este proyecto: BuildKit indexa la caché por
    # hash de capa, sin vincularla a un repositorio, y las capas de imágenes
    # base se comparten entre proyectos. Por eso se pide confirmación y se
    # muestra antes cuánto espacio está en juego, en lugar de usar --force.
    set -euo pipefail
    docker buildx du 2>/dev/null | tail -3 || true
    echo
    echo "Esto borrara la cache de construccion de TODOS los proyectos del equipo."
    read -r -p "Continuar? [s/N] " respuesta
    case "${respuesta}" in
        s|S|si|SI|y|Y) docker builder prune --force ;;
        *) echo "cancelado; las imagenes de {{IMAGE}} si se han borrado" ;;
    esac
