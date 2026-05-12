# nim-everywhere

Shared Nim platform seams for code that must compile on native and JavaScript backends.

Commands:
- `just build`: compile native and JS smoke targets.
- `just test`: run native and JS smoke tests.
- `just lint`: run Nim and Nix checks.
- `just format`: format Nim and Nix sources.

Structure:
- `src/nim_everywhere.nim`: public export surface.
- `src/nim_everywhere/async_compat.nim`: `PlatformFuture[T]` aliasing,
  `onComplete` / `onCompleteVoid`, `newCompletedFuture`,
  `newFailedFuture`, `drainPlatformCallbacks`.
- `src/nim_everywhere/time.nim` (NE-Time-M0): the expanded time facade —
  `sleepFor`, `monotonicNowMs`, `withTimeout`, `scheduleAt`,
  `scheduleEvery`, `cancelTimer`, `TimerHandle`. Every primitive routes
  through `FakeAsyncContext` when one is installed; otherwise falls
  through to the backend's native primitives.
- `src/nim_everywhere/fake_time.nim`: `FakeAsyncContext` with
  `install`/`uninstall`/`advance`/`runPending`/`now`.
- `src/nim_everywhere/platform.nim`: filesystem, clock, HTTP, JSON, and
  event-loop seams.
- `src/nim_everywhere/http.nim`: cross-target HTTP transport.
- `tests/`: deterministic native/JS smoke tests + backend matrix.

Backend matrix (asyncdispatch / chronos / none / unset default) is
exercised via `just test-async-matrix` and `just test-time-matrix`. The
top-level `just test` includes both.

Keep this repo independent from IsoNim Editor and CodeTracer modules. Public APIs should remain backend-neutral and deterministic in tests.
