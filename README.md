# pepe

Proyecto de ejemplo que muestra cómo empaquetar una herramienta de línea de
comandos escrita en Python dentro de una imagen Docker **distroless**, usando
[`uv`](https://docs.astral.sh/uv/) tanto para instalar el intérprete como para
instalar el propio proyecto como herramienta.

El programa en sí es deliberadamente trivial —imprime `Hola mundo!!`—: lo
interesante aquí es la construcción de la imagen, no el código.

## Qué demuestra

- Instalar una versión concreta de Python con `uv python install`, sin depender
  del intérprete del sistema.
- Instalar el proyecto como herramienta ejecutable con `uv tool install`.
- Trasladar ambas instalaciones a una imagen final limpia mediante una
  construcción Docker en dos etapas, sin gestor de paquetes, sin shell y sin
  `uv` en el resultado.

## Estructura

| Archivo          | Contenido                                                        |
| ---------------- | ---------------------------------------------------------------- |
| `main.py`        | El programa: una función `main()` que imprime un saludo.         |
| `pyproject.toml` | Metadatos, dependencia de `httpx` y el script `pepe = main:main`. |
| `uv.lock`        | Versiones exactas resueltas por `uv`.                            |
| `Dockerfile`     | Construcción en dos etapas hacia una imagen distroless.          |
| `justfile`       | Recetas para construir y comprobar la imagen.                    |
| `.dockerignore`  | Excluye `.venv/` y otros artefactos del contexto de construcción. |

## Requisitos

- Docker con BuildKit (cualquier versión reciente lo trae activado).
- [`just`](https://github.com/casey/just), opcional, para las recetas.
- No hace falta tener Python ni `uv` instalados en el equipo: la construcción
  los aporta.

## Uso

```sh
just build     # construye la imagen pepe:latest
just run       # la ejecuta -> "Hola mundo!!"
just test      # comprueba la imagen (requiere red)
just verify    # construye y comprueba de una pasada
just --list    # todas las recetas disponibles
```

Sin `just`:

```sh
docker build -t pepe:latest .
docker run --rm pepe:latest
```

## Cómo funciona la construcción

### Etapa 1 — construcción (`debian:bookworm-slim`)

`uv` se copia desde su imagen oficial con la versión fijada, en lugar de
descargarlo con `curl`, para que la construcción sea reproducible y no dependa
de la red ni de certificados.

Tres variables de entorno colocan cada cosa en una ruta conocida, que es lo que
permite copiarlas después:

| Variable                 | Ruta          | Contenido                         |
| ------------------------ | ------------- | --------------------------------- |
| `UV_PYTHON_INSTALL_DIR`  | `/opt/python` | El intérprete                     |
| `UV_TOOL_DIR`            | `/opt/tools`  | El entorno virtual de la herramienta |
| `UV_TOOL_BIN_DIR`        | `/opt/bin`    | El lanzador ejecutable            |

Después, `uv python install` trae la versión indicada y `uv tool install .`
instala el proyecto con sus dependencias en ese entorno.

### Etapa 2 — imagen final (`gcr.io/distroless/cc-debian12:nonroot`)

Se copian las tres rutas anteriores, se añade `/opt/bin` al `PATH` y el
`ENTRYPOINT` apunta al lanzador. El resultado no contiene `uv`, ni gestor de
paquetes, ni shell, y se ejecuta como usuario sin privilegios.

## Dos detalles que explican las decisiones tomadas

**La base es `cc-debian12`, no `static`.** El Python que instala `uv` proviene
de [python-build-standalone](https://github.com/astral-sh/python-build-standalone)
y está enlazado dinámicamente contra glibc y libssl. Sobre
`gcr.io/distroless/static` no arrancaría. La variante `cc` aporta glibc, libgcc
y libssl, y es la imagen distroless más pequeña que sirve. Por el mismo motivo
la etapa de construcción es `bookworm-slim`: así el ABI de glibc coincide en
origen y destino.

**El punto de entrada funciona sin shell.** `/opt/bin/pepe` es un script con
shebang, pero ese shebang apunta directamente al Python del entorno virtual, de
modo que lo resuelve el kernel. No se necesita `sh`, que en distroless no
existe.

## Sobre las comprobaciones

`just test` ejecuta dos recetas, y la distinción importa:

- `test-entrypoint` comprueba que el contenedor arranca y que imprime lo
  esperado.
- `test-deps` importa `httpx`, consulta la versión de OpenSSL y realiza una
  petición HTTPS real.

La segunda es la que valida de verdad la imagen distroless. `main.py` importa
`httpx` pero nunca lo usa, así que el punto de entrada pasaría igualmente
aunque faltara una biblioteca dinámica o los certificados del sistema:
justamente el riesgo de copiar un intérprete entre imágenes. `test-deps`
requiere acceso a la red; para comprobar sin red, usa `just test-entrypoint`.

## Tamaño de la imagen

Unos 143 MB, de los cuales ~116 MB son el intérprete y su biblioteca estándar
en `/opt/python`. Si el tamaño fuese una prioridad, la vía con más margen es
podar `test/`, `idlelib/`, `tkinter/` y los archivos `.a` de esa ruta durante la
etapa de construcción, lo que la deja en torno a 90–100 MB. Este ejemplo no lo
hace: prioriza que el Dockerfile se lea con claridad.

Usa `just size` para ver el desglose por capas.

## Adaptarlo a otro proyecto

1. Cambia `name` y el script de `[project.scripts]` en `pyproject.toml`; el
   `ENTRYPOINT` y la ruta de `test-deps` usan ese nombre.
2. Ajusta `PYTHON_VERSION` en el `justfile` (se propaga al `Dockerfile` como
   `--build-arg`).
3. Si tus dependencias incluyen extensiones compiladas, añade en la primera
   etapa las cabeceras necesarias para construirlas; la imagen final no las
   necesita, porque solo recibe el resultado.
