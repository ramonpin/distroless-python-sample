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
| `justfile`       | Recetas para construir, comprobar y limpiar.                     |
| `.dockerignore`  | Excluye `.venv/` y otros artefactos del contexto de construcción. |
| `README.md`      | Este documento.                                                  |

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
just size      # tamaño y desglose por capas
just compare   # tamaño con y sin la poda
just clean     # borra las imágenes del proyecto
just --list    # todas las recetas disponibles
```

`just clean` descubre las imágenes por repositorio, así que se lleva todas las
etiquetas que generan las recetas (`latest`, `builder`, `unpruned`) sin tener
que enumerarlas. No toca imágenes de otros proyectos, ni siquiera con nombres
parecidos como `pepe-otro`.

Existe también `just clean-all`, pero conviene saber qué hace antes de usarla:
además de las imágenes, borra la caché de construcción de BuildKit **de todos
los proyectos del equipo**, no solo la de este. No es una limitación de la
receta, sino de BuildKit: la caché se indexa por hash de capa, sin vínculo con
un repositorio, y las capas de las imágenes base se comparten entre proyectos.
Por eso la receta muestra cuánto espacio está en juego y pide confirmación
explícita. Si solo quieres dejar limpio este proyecto, usa `just clean`.

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

`just test` ejecuta tres recetas, y la distinción importa:

- `test-entrypoint` comprueba que el contenedor arranca y que imprime lo
  esperado.
- `test-deps` importa `httpx`, consulta la versión de OpenSSL y realiza una
  petición HTTPS real.
- `test-stdlib` importa 24 módulos de la biblioteca estándar, para detectar si
  la poda de tamaño se ha llevado algo necesario.

La segunda es la que valida de verdad la imagen distroless. `main.py` importa
`httpx` pero nunca lo usa, así que el punto de entrada pasaría igualmente
aunque faltara una biblioteca dinámica o los certificados del sistema:
justamente el riesgo de copiar un intérprete entre imágenes. `test-deps`
requiere acceso a la red; para comprobar sin red, usa `just test-entrypoint`.

## Tamaño de la imagen

Unos **90 MB**, frente a los 143 MB que ocupa sin podar. Casi todo lo que queda
es el intérprete y su biblioteca estándar en `/opt/python`, que pasa de 123 MB a
66 MB.

La poda va en la primera etapa del `Dockerfile`, antes de las copias, y se puede
desactivar con `--build-arg PRUNE=0` (o `just build-unpruned`). Reparto del
ahorro, medido sobre esta imagen:

| Eliminado                        | Ahorro | Motivo                              |
| -------------------------------- | -----: | ----------------------------------- |
| `lib/libpython3.13.so.1.0`       |  33 MB | Copia para embeber Python           |
| `tcl/tk`, `tkinter`, `idlelib`   |  13 MB | Interfaz gráfica: no hay servidor X |
| `share/terminfo`                 |   8 MB | No hay terminal interactiva         |
| `include/`, `.a`, `config-*`     |   4 MB | Solo para compilar extensiones      |
| `share/man`, `pkgconfig`         |  ~1 MB | Documentación y metadatos de enlace |
| `ensurepip`, `pip`               |   2 MB | La imagen final es inmutable        |

El grande merece explicación: `libpython3.13.so.1.0` es una **segunda copia
completa** del intérprete, pensada para embeber Python en otro programa. El
binario `bin/python3.13` no la enlaza y ningún módulo de `lib-dynload` la
necesita. Se comprueba así:

```sh
docker build --target builder -t pepe:builder .
docker run --rm --entrypoint /bin/sh pepe:builder \
    -c 'ldd /opt/python/*/bin/python3.13'   # libpython no aparece
```

Podar un intérprete es exactamente el tipo de cambio que rompe cosas en
producción y no en el arranque, así que hay dos redes de seguridad: el
`Dockerfile` importa `ssl`, `httpx` y `sysconfig` en la propia etapa de
construcción (si la poda se llevara algo imprescindible, falla la construcción,
no el despliegue), y `just test-stdlib` importa 24 módulos de la biblioteca
estándar sobre la imagen final.

Usa `just size` para el desglose por capas y `just compare` para ver las dos
variantes juntas.

### Lo que no hace falta podar

Los builds actuales de `uv` ya vienen sin el directorio `test/` de la
biblioteca estándar ni `lib2to3`, y los archivos `.a` apenas suman 1 MB. Si
buscas recortar más, mídelo antes en lugar de copiar recetas genéricas:

```sh
docker run --rm --entrypoint /bin/sh pepe:builder \
    -c 'cd /opt/python/*/ && du -sm ./* && du -sm lib/* | sort -rn | head'
```

## Adaptarlo a otro proyecto

1. Cambia `name` y el script de `[project.scripts]` en `pyproject.toml`; el
   `ENTRYPOINT` y la ruta de `test-deps` usan ese nombre.
2. Ajusta `PYTHON_VERSION` en el `justfile` (se propaga al `Dockerfile` como
   `--build-arg`).
3. Si tus dependencias incluyen extensiones compiladas, añade en la primera
   etapa las cabeceras necesarias para construirlas; la imagen final no las
   necesita, porque solo recibe el resultado.
