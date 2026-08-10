# pepe

Example project showing how to package a Python command-line tool into a
**distroless** Docker image, using [`uv`](https://docs.astral.sh/uv/) both to
install the interpreter and to install the project itself as a tool.

The program is deliberately trivial — it prints `Hello world!!` — because the
interesting part here is how the image is built, not the code.

## What it demonstrates

- Installing a specific Python version with `uv python install`, without
  relying on a system interpreter.
- Installing the project as an executable tool with `uv tool install`.
- Moving both installations into a clean final image via a two-stage Docker
  build, leaving no package manager, no shell and no `uv` in the result.

## Layout

| File             | Contents                                                       |
| ---------------- | -------------------------------------------------------------- |
| `main.py`        | The program: a `main()` function that prints a greeting.       |
| `pyproject.toml` | Metadata, the `httpx` dependency and the `pepe = main:main` script. |
| `uv.lock`        | Exact versions resolved by `uv`.                               |
| `Dockerfile`     | Two-stage build targeting a distroless image.                  |
| `justfile`       | Recipes to build, check and clean up.                          |
| `.dockerignore`  | Keeps `.venv/` and other artifacts out of the build context.   |
| `README.md`      | This document.                                                 |

## Requirements

- Docker with BuildKit (enabled by default in any recent version).
- [`just`](https://github.com/casey/just), optional, for the recipes.
- No local Python or `uv` installation needed: the build provides them.

## Usage

```sh
just build     # build the pepe:latest image
just run       # run it -> "Hello world!!"
just test      # check the image (requires network access)
just verify    # build and check in one go
just size      # size and per-layer breakdown
just compare   # size with and without pruning
just clean     # remove the project's images
just --list    # all available recipes
```

`just clean` discovers images by repository, so it removes every tag the
recipes produce (`latest`, `builder`, `unpruned`) without having to enumerate
them. It leaves other projects' images alone, even similarly named ones such as
`pepe-other`.

There is also `just clean-all`, but it's worth knowing what it does before
reaching for it: on top of the images, it clears the BuildKit build cache for
**every project on the machine**, not just this one. That isn't a shortcoming
of the recipe but of BuildKit: the cache is indexed by layer hash with no link
to a repository, and base-image layers are shared across projects. That's why
the recipe reports how much space is at stake and asks for explicit
confirmation. To clean up only this project, use `just clean`.

Without `just`:

```sh
docker build -t pepe:latest .
docker run --rm pepe:latest
```

## How the build works

### Stage 1 — build (`debian:bookworm-slim`)

`uv` is copied from its official image at a pinned version rather than
downloaded with `curl`, so the build is reproducible and needs neither network
access nor certificates.

Three environment variables put each piece at a known path, which is what makes
them copyable later:

| Variable                | Path          | Contents                    |
| ----------------------- | ------------- | --------------------------- |
| `UV_PYTHON_INSTALL_DIR` | `/opt/python` | The interpreter             |
| `UV_TOOL_DIR`           | `/opt/tools`  | The tool's virtual environment |
| `UV_TOOL_BIN_DIR`       | `/opt/bin`    | The executable launcher     |

`uv python install` then fetches the requested version, and `uv tool install .`
installs the project with its dependencies into that environment.

### Stage 2 — final image (`gcr.io/distroless/cc-debian12:nonroot`)

The three paths above are copied over, `/opt/bin` is added to `PATH`, and
`ENTRYPOINT` points at the launcher. The result contains no `uv`, no package
manager and no shell, and runs as an unprivileged user.

## Two details behind the choices made

**The base is `cc-debian12`, not `static`.** The Python that `uv` installs comes
from [python-build-standalone](https://github.com/astral-sh/python-build-standalone)
and is dynamically linked against glibc and libssl. It would not start on
`gcr.io/distroless/static`. The `cc` variant provides glibc, libgcc and libssl,
and is the smallest distroless image that works. For the same reason the build
stage is `bookworm-slim`: that way the glibc ABI matches on both ends.

**The entry point works without a shell.** `/opt/bin/pepe` is a script with a
shebang, but that shebang points straight at the virtual environment's Python,
so the kernel resolves it. No `sh` is required — and distroless has none.

## About the checks

`just test` runs three recipes, and the distinction matters:

- `test-entrypoint` checks that the container starts and prints what's
  expected.
- `test-deps` imports `httpx`, reads the OpenSSL version and makes a real HTTPS
  request.
- `test-stdlib` imports 24 standard-library modules, to catch whether the size
  pruning removed something needed.

The second one is what actually validates the distroless image. `main.py`
imports `httpx` but never uses it, so the entry point would pass even with a
missing shared library or missing system certificates — precisely the risk of
copying an interpreter between images. `test-deps` needs network access; to
check without it, use `just test-entrypoint`.

## Image size

About **90 MB**, down from 143 MB unpruned. Almost all of what remains is the
interpreter and its standard library under `/opt/python`, which goes from
123 MB to 66 MB.

Pruning happens in the `Dockerfile`'s first stage, before the copies, and can be
disabled with `--build-arg PRUNE=0` (or `just build-unpruned`). Where the
savings come from, as measured on this image:

| Removed                        | Saved | Reason                             |
| ------------------------------ | ----: | ---------------------------------- |
| `lib/libpython3.13.so.1.0`     | 33 MB | Copy for embedding Python          |
| `tcl/tk`, `tkinter`, `idlelib`  | 13 MB | GUI toolkit: there is no X server  |
| `share/terminfo`               |  8 MB | No interactive terminal            |
| `include/`, `.a`, `config-*`   |  4 MB | Only needed to compile extensions  |
| `ensurepip`, `pip`             |  2 MB | The final image is immutable       |
| `share/man`, `pkgconfig`       | ~1 MB | Documentation and linker metadata  |

The big one deserves an explanation: `libpython3.13.so.1.0` is a **second full
copy** of the interpreter, meant for embedding Python into another program. The
`bin/python3.13` binary does not link against it, and no `lib-dynload` module
needs it. You can verify that:

```sh
docker build --target builder -t pepe:builder .
docker run --rm --entrypoint /bin/sh pepe:builder \
    -c 'ldd /opt/python/*/bin/python3.13'   # libpython does not appear
```

Pruning an interpreter is exactly the kind of change that breaks things in
production rather than at startup, so there are two safety nets: the
`Dockerfile` imports `ssl`, `httpx` and `sysconfig` during the build stage
itself (if pruning removed something essential, the build fails instead of the
deployment), and `just test-stdlib` imports 24 standard-library modules against
the final image.

Use `just size` for the per-layer breakdown and `just compare` to see both
variants side by side.

### What does not need pruning

Current `uv` builds already ship without the standard library's `test/`
directory and without `lib2to3`, and the `.a` files add up to barely 1 MB. If
you want to trim further, measure first instead of copying generic recipes:

```sh
docker run --rm --entrypoint /bin/sh pepe:builder \
    -c 'cd /opt/python/*/ && du -sm ./* && du -sm lib/* | sort -rn | head'
```

## Adapting it to another project

1. Change `name` and the `[project.scripts]` entry in `pyproject.toml`; the
   `ENTRYPOINT` and the `test-deps` path both use that name.
2. Adjust `PYTHON_VERSION` in the `justfile` (it propagates to the `Dockerfile`
   as a `--build-arg`).
3. If your dependencies include compiled extensions, add the headers needed to
   build them to the first stage; the final image doesn't need them, since it
   only receives the result.
