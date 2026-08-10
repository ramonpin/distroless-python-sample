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

# Ejecuta todas las comprobaciones. Requiere red para test-deps.
test: test-entrypoint test-deps
    @echo "OK: todas las comprobaciones"

# Construye y comprueba de una pasada.
verify: build test

# Muestra el tamaño de la imagen y sus capas.
size:
    @docker images {{IMAGE}}:{{TAG}} --format 'imagen: {{{{.Size}}'
    @docker history {{IMAGE}}:{{TAG}} --human --format '{{{{.Size}}\t{{{{.CreatedBy}}' | head -20

# Abre una shell en la etapa de construcción (la imagen final no tiene shell).
debug:
    docker build --target builder -t {{IMAGE}}:builder .
    docker run --rm -it --entrypoint /bin/bash {{IMAGE}}:builder

# Elimina las imágenes generadas.
clean:
    -docker rmi {{IMAGE}}:{{TAG}} {{IMAGE}}:builder
