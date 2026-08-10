IMAGE := "pepe"
TAG := "latest"
PYTHON_VERSION := "3.13.7"

# List the available recipes.
default:
    @just --list

# Build the image.
build:
    docker build \
        --build-arg PYTHON_VERSION={{PYTHON_VERSION}} \
        -t {{IMAGE}}:{{TAG}} .

# Build without using the layer cache.
rebuild:
    docker build --no-cache \
        --build-arg PYTHON_VERSION={{PYTHON_VERSION}} \
        -t {{IMAGE}}:{{TAG}} .

# Run the tool in a container. Takes arguments: just run --help
run *ARGS:
    docker run --rm {{IMAGE}}:{{TAG}} {{ARGS}}

# Check that the entry point starts and prints the expected output.
test-entrypoint:
    #!/usr/bin/env bash
    # The expected string must match main.py; changing the greeting in one
    # place without the other makes this check fail.
    set -euo pipefail
    output="$(docker run --rm {{IMAGE}}:{{TAG}})"
    echo "${output}"
    if [[ "${output}" != "Hello world!!" ]]; then
        echo "FAIL: unexpected output from the entry point" >&2
        exit 1
    fi
    echo "OK: entry point"

# Check that the interpreter and its native dependencies (SSL) work.
test-deps:
    #!/usr/bin/env bash
    # This is the check that really validates the distroless image: a missing
    # shared library or missing certificates would fail here, not at the
    # entry point.
    set -euo pipefail
    docker run --rm --entrypoint /opt/tools/pepe/bin/python {{IMAGE}}:{{TAG}} -c '
    import ssl, sys
    import httpx
    print("python", sys.version.split()[0])
    print("httpx ", httpx.__version__)
    print(ssl.OPENSSL_VERSION)
    r = httpx.get("https://example.com")
    assert r.status_code == 200, r.status_code
    print("HTTPS request:", r.status_code)
    '
    echo "OK: interpreter and dependencies"

# Check that the Dockerfile pruning did not break the standard library.
test-stdlib:
    #!/usr/bin/env bash
    set -euo pipefail
    docker run --rm --entrypoint /opt/tools/pepe/bin/python {{IMAGE}}:{{TAG}} -c '
    import importlib
    modules = ["venv", "pydoc", "sqlite3", "ssl", "ctypes", "multiprocessing",
               "asyncio", "xml.etree.ElementTree", "concurrent.futures",
               "http.server", "logging.handlers", "pickle", "socket",
               "subprocess", "tempfile", "uuid", "zoneinfo", "decimal",
               "lzma", "bz2", "zlib", "hashlib", "email", "unittest"]
    broken = []
    for m in modules:
        try:
            importlib.import_module(m)
        except Exception as e:
            broken.append(f"{m}: {type(e).__name__}: {e}")
    if broken:
        raise SystemExit("modules broken by pruning:\n" + "\n".join(broken))
    print(f"{len(modules)} modules imported without error")
    '
    echo "OK: standard library intact"

# Run every check. test-deps requires network access.
test: test-entrypoint test-deps test-stdlib
    @echo "OK: all checks"

# Build and check in one go.
verify: build test

# Build without the size pruning, for comparison.
build-unpruned:
    docker build \
        --build-arg PYTHON_VERSION={{PYTHON_VERSION}} \
        --build-arg PRUNE=0 \
        -t {{IMAGE}}:unpruned .

# Compare the size with and without pruning.
compare: build build-unpruned
    @docker images {{IMAGE}} --format '{{{{.Tag}}\t{{{{.Size}}' | grep -E 'latest|unpruned'

# Show the image size and its layers.
size:
    @docker images {{IMAGE}}:{{TAG}} --format 'image: {{{{.Size}}'
    @docker history {{IMAGE}}:{{TAG}} --human --format '{{{{.Size}}\t{{{{.CreatedBy}}' | head -20

# Open a shell in the build stage (the final image has no shell).
debug:
    docker build --target builder -t {{IMAGE}}:builder .
    docker run --rm -it --entrypoint /bin/bash {{IMAGE}}:builder

# Remove every image belonging to this project, whatever its tag.
clean:
    #!/usr/bin/env bash
    # Images are discovered by repository instead of enumerating tags by hand,
    # so this recipe needs no update whenever another one produces a new tag
    # (latest, builder, unpruned...). The 'reference' filter matches the whole
    # repository name, so it leaves similarly named images such as
    # 'otherpepe' or 'pepe-otherproject' alone.
    set -euo pipefail
    images="$(docker images --filter reference='{{IMAGE}}' --format '{{{{.Repository}}:{{{{.Tag}}' | grep -v '<none>' || true)"
    if [[ -z "${images}" ]]; then
        echo "no {{IMAGE}} images to remove"
    else
        echo "${images}" | xargs -r docker rmi -f
    fi

# Remove the images and, once confirmed, the machine's WHOLE BuildKit cache.
clean-all: clean
    #!/usr/bin/env bash
    # The prune cannot be scoped to this project: BuildKit indexes the cache by
    # layer hash with no link to a repository, and base-image layers are shared
    # across projects. Hence the confirmation prompt and the size report up
    # front, rather than just passing --force.
    set -euo pipefail
    docker buildx du 2>/dev/null | tail -3 || true
    echo
    echo "This will clear the build cache of EVERY project on this machine."
    read -r -p "Continue? [y/N] " answer
    case "${answer}" in
        y|Y|yes|YES) docker builder prune --force ;;
        *) echo "cancelled; the {{IMAGE}} images were removed" ;;
    esac
