alias t := test
alias fmt := format

build: build-native build-js

build-native:
    nim c --path:src tests/test_platform_smoke.nim
    nim c --path:src tests/test_async_http.nim
    nim c --path:src tests/test_async_backend.nim
    nim c --path:src tests/test_fake_time.nim

build-js:
    nim js --path:src tests/test_platform_smoke.nim
    nim js --path:src tests/test_async_http.nim

test: test-native test-js test-async-matrix

test-native:
    nim c -r --path:src tests/test_platform_smoke.nim
    nim c -r --path:src tests/test_async_http.nim

test-js:
    bash tools/nim-js-test-gate.sh --path:src tests/test_platform_smoke.nim
    bash tools/nim-js-test-gate.sh --path:src tests/test_async_http.nim

# Async backend matrix — exercise async_compat + fake_time under each
# supported native backend (default/unset, asyncdispatch, chronos, none).
# The same source files compile and pass under every entry; switching
# only changes the underlying Future / sleep primitive.

test-async-default:
    nim c -r --path:src tests/test_async_backend.nim
    nim c -r --path:src tests/test_fake_time.nim
    nim c -r --path:src tests/test_async_http.nim

test-async-asyncdispatch:
    nim c -r -d:asyncBackend=asyncdispatch --path:src tests/test_async_backend.nim
    nim c -r -d:asyncBackend=asyncdispatch --path:src tests/test_fake_time.nim
    nim c -r -d:asyncBackend=asyncdispatch --path:src tests/test_async_http.nim

# chronos may not be installed in every local dev environment. The
# preamble does a one-shot probe ("does this file compile with `import
# chronos`?") and skips with a printed warning if not. CI environments
# that install chronos explicitly will exercise this path.
test-async-chronos:
    @if nim check --hints:off -d:asyncBackend=chronos --path:src tests/test_async_backend.nim >/dev/null 2>&1; then \
      nim c -r -d:asyncBackend=chronos --path:src tests/test_async_backend.nim && \
      nim c -r -d:asyncBackend=chronos --path:src tests/test_fake_time.nim && \
      nim c -r -d:asyncBackend=chronos --path:src tests/test_async_http.nim; \
    else \
      echo "[test-async-chronos] chronos not available on nimble path; skipping"; \
    fi

test-async-none:
    nim c -r -d:asyncBackend=none --path:src tests/test_fake_time.nim
    nim c -r -d:asyncBackend=none --path:src tests/test_async_backend.nim
    nim c -r -d:asyncBackend=none --path:src tests/test_async_http.nim

test-async-matrix: test-async-default test-async-asyncdispatch test-async-chronos test-async-none

lint: lint-nim lint-nix

lint-nim:
    nim check --path:src tests/test_platform_smoke.nim
    nim check --path:src tests/test_async_http.nim
    nim check --path:src tests/test_async_backend.nim
    nim check --path:src tests/test_fake_time.nim

lint-nix:
    nixfmt --check flake.nix

format: format-nim format-nix

format-nim:
    nimpretty src/nim_everywhere.nim src/nim_everywhere/*.nim tests/test_async_backend.nim tests/test_async_http.nim tests/test_fake_time.nim tests/test_platform_smoke.nim

format-nix:
    nixfmt flake.nix

bump-version version:
    sed -i "s/^version       = .*/version       = \"{{version}}\"/" nim_everywhere.nimble
    printf "%s\n" "{{version}}" > VERSION
