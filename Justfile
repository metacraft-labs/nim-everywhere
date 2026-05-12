alias t := test
alias fmt := format

build: build-native build-js

build-native:
    nim c --path:src tests/test_platform_smoke.nim
    nim c --path:src tests/test_async_http.nim
    nim c --path:src tests/test_async_backend.nim
    nim c --path:src tests/test_fake_time.nim
    nim c --path:src tests/test_time_facade.nim

build-js:
    nim js --path:src tests/test_platform_smoke.nim
    nim js --path:src tests/test_async_http.nim

test: test-native test-js test-async-matrix test-time-matrix

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

# Time-facade matrix — NE-Time-M0. Exercises the expanded time facade
# (monotonicNowMs, withTimeout, scheduleAt, scheduleEvery, cancelTimer)
# under every supported native backend. Mirrors the structure of
# `test-async-*` above; chronos is gated behind a `nim check` probe
# because it may not be installed in every local dev environment.

test-time-facade-default:
    nim c -r --path:src tests/test_time_facade.nim

test-time-facade-asyncdispatch:
    nim c -r -d:asyncBackend=asyncdispatch --path:src tests/test_time_facade.nim

test-time-facade-chronos:
    @if nim check --hints:off -d:asyncBackend=chronos --path:src tests/test_time_facade.nim >/dev/null 2>&1; then \
      nim c -r -d:asyncBackend=chronos --path:src tests/test_time_facade.nim; \
    else \
      echo "[test-time-facade-chronos] chronos not available on nimble path; skipping"; \
    fi

test-time-facade-none:
    nim c -r -d:asyncBackend=none --path:src tests/test_time_facade.nim

test-time-matrix: test-time-facade-default test-time-facade-asyncdispatch test-time-facade-chronos test-time-facade-none

# NE-Time-Fork-Chronos hook recipes.
#
# Local dev recipes; requires `~/metacraft/nim-chronos` clone on the
# `clock-injection-hook` branch. Not wired into the umbrella `test`
# target because the path override in `config.nims` points at the
# developer's machine — once the hook lands upstream, the override
# goes away and these recipes fold back into the default matrix.

test-time-chronos-hook:
    @if nim check --hints:off -d:asyncBackend=chronos -d:chronosClockHook --path:src tests/test_chronos_fake_clock.nim >/dev/null 2>&1; then \
      nim c -r -d:asyncBackend=chronos -d:chronosClockHook --path:src tests/test_chronos_fake_clock.nim; \
    else \
      echo "[test-time-chronos-hook] chronos hook not available; skipping"; \
    fi

# Re-run the existing time-facade suite under the chronos hook to prove
# no regressions when the hook is engaged.
test-time-facade-chronos-hook:
    @if nim check --hints:off -d:asyncBackend=chronos -d:chronosClockHook --path:src tests/test_time_facade.nim >/dev/null 2>&1; then \
      nim c -r -d:asyncBackend=chronos -d:chronosClockHook --path:src tests/test_time_facade.nim; \
    else \
      echo "[test-time-facade-chronos-hook] chronos hook not available; skipping"; \
    fi

# NE-Time-Fork-Asyncdispatch hook recipes.
#
# Local dev recipes; requires `~/metacraft/codetracer-nim` clone on the
# `clock-injection-hook` branch (the Nim fork carrying the patched
# `lib/pure/asyncdispatch.nim`). The `--lib:` switch must be passed on
# the *command line* — see the `config.nims` comment for why it cannot
# be expressed as `switch("lib", ...)`. Not wired into the umbrella
# `test` target because the path is the developer's machine — once the
# hook lands upstream in Nim, the override goes away and these recipes
# fold back into the default matrix.

asyncdispatch_fork_lib := "/home/zahary/metacraft/codetracer-nim/lib"

test-time-asyncdispatch-hook:
    @if nim check --hints:off --lib:{{asyncdispatch_fork_lib}} -d:asyncBackend=asyncdispatch -d:asyncdispatchClockHook --path:src tests/test_asyncdispatch_fake_clock.nim >/dev/null 2>&1; then \
      nim c -r --lib:{{asyncdispatch_fork_lib}} -d:asyncBackend=asyncdispatch -d:asyncdispatchClockHook --path:src tests/test_asyncdispatch_fake_clock.nim; \
    else \
      echo "[test-time-asyncdispatch-hook] codetracer-nim fork unavailable or asyncdispatch hook not built; skipping"; \
    fi

# Re-run the existing time-facade suite under the asyncdispatch hook to
# prove no regressions when the hook is engaged.
test-time-facade-asyncdispatch-hook:
    @if nim check --hints:off --lib:{{asyncdispatch_fork_lib}} -d:asyncBackend=asyncdispatch -d:asyncdispatchClockHook --path:src tests/test_time_facade.nim >/dev/null 2>&1; then \
      nim c -r --lib:{{asyncdispatch_fork_lib}} -d:asyncBackend=asyncdispatch -d:asyncdispatchClockHook --path:src tests/test_time_facade.nim; \
    else \
      echo "[test-time-facade-asyncdispatch-hook] codetracer-nim fork unavailable or asyncdispatch hook not built; skipping"; \
    fi

lint: lint-nim lint-nix

lint-nim:
    nim check --path:src tests/test_platform_smoke.nim
    nim check --path:src tests/test_async_http.nim
    nim check --path:src tests/test_async_backend.nim
    nim check --path:src tests/test_fake_time.nim
    nim check --path:src tests/test_time_facade.nim

lint-nix:
    nixfmt --check flake.nix

format: format-nim format-nix

format-nim:
    nimpretty src/nim_everywhere.nim src/nim_everywhere/*.nim tests/test_async_backend.nim tests/test_async_http.nim tests/test_fake_time.nim tests/test_platform_smoke.nim tests/test_time_facade.nim

format-nix:
    nixfmt flake.nix

bump-version version:
    sed -i "s/^version       = .*/version       = \"{{version}}\"/" nim_everywhere.nimble
    printf "%s\n" "{{version}}" > VERSION
