# nim-everywhere

`nim-everywhere` provides small platform seams for Nim libraries that target both native Nim and Nim JS from the same source.

It currently exposes:
- `NativeString`, native collection aliases, and conversion helpers for code
  that should avoid backend-specific string/container choices
- async compatibility helpers for callback-based code that targets both
  native Nim and Nim JS
- a full time-related facade (`sleepFor`, `monotonicNowMs`, `withTimeout`,
  `scheduleAt`, `scheduleEvery`, `cancelTimer`, plus an opaque `TimerHandle`)
  that routes through a thread-local `FakeAsyncContext` when one is installed
  and falls through to backend-native primitives otherwise — see
  [`src/nim_everywhere/time.nim`](src/nim_everywhere/time.nim)
- filesystem read/write/existence helpers with native implementations and browser-safe JS stubs
- deterministic clock injection
- HTTP request/response records with sync and async fake transport support
- a browser `fetch` wrapper exposed as an async transport, with native kept
  pluggable for host-specific HTTP clients
- JSON parse/stringify helpers
- immediate event-loop scheduling usable from native and JS tests

## Time facade

Downstream code should reach for `nim_everywhere/time` (or the umbrella
`nim_everywhere`) for any clock-touching operation. The reason to prefer
this over calling `asyncdispatch.sleepAsync` / `chronos.sleepAsync` /
`addTimer` directly is **fake-time testability**: every primitive in
this facade routes through an installed `FakeAsyncContext` so a test can
drive 200 ms of simulated latency in microseconds of wall-clock without
losing determinism.

```nim
import nim_everywhere/time

# `sleepFor` and the rest of the facade all consult an installed
# `FakeAsyncContext` first; without one they fall through to the
# backend's native primitives (`asyncdispatch.sleepAsync`,
# `chronos.sleepAsync`, JS `setTimeout`, etc.).

let now = monotonicNowMs()                       # int64 ms; fake-aware
discard sleepFor(50)                              # PlatformFuture[void]

let h = scheduleAt(100, proc() = echo "fired")    # one-shot
cancelTimer(h)

let timer = scheduleEvery(500, proc() = echo "tick")
# … later: cancelTimer(timer)

# Race a future against a deadline; returns Option[T].
proc fetchProfile(): PlatformFuture[Profile] = ...
discard withTimeout(fetchProfile(), 200).onComplete(
  proc(result: Option[Profile]) =
    if result.isSome:
      use(result.get)
    else:
      handleTimeout(),
  proc(msg: string) = handleError(msg))
```

Tests install a `FakeAsyncContext` from `nim_everywhere/fake_time` to drive
every primitive synchronously without waiting on the OS clock. See
`tests/test_time_facade.nim` for the canonical patterns and
`isonim-examples/tests/test_async_perf_demo.nim` for downstream usage.

## Development

```sh
direnv exec /home/zahary/metacraft/nim-everywhere just test
direnv exec /home/zahary/metacraft/nim-everywhere just test-js
```
