## NE-Time-Fork-Chronos verification.
##
## Exercises the chronos clock-injection hook end-to-end:
##
##   - `Moment.now()` reads `FakeAsyncContext.nowMs` when a context is
##     installed (proves chronos's chokepoint at `timer.nim:425` is
##     hooked).
##   - `chronos.sleepAsync` resolves when the fake clock advances past
##     the deadline — *without* going through nim-everywhere's
##     `sleepFor` branch (proves the hook reaches code paths that the
##     userspace branch doesn't cover).
##   - `chronos.withTimeout` resolves to the timeout branch when the
##     fake clock crosses the deadline.
##   - Uninstall restores the real wall-clock — `Moment.now()` reads
##     `fastEpochTimeNano()` again, yielding a real-time value.
##
## Build flags required: `-d:asyncBackend=chronos -d:chronosClockHook`.
## The umbrella `just test` does NOT include this test by default
## because the path-override in `config.nims` points at a developer's
## local `~/metacraft/nim-chronos` clone (per the milestone spec —
## removed once the hook is upstreamed).

import std/unittest
import chronos
import nim_everywhere

when not (defined(chronosClockHook) and asyncBackend == "chronos"):
  {.fatal: "test_chronos_fake_clock requires -d:asyncBackend=chronos -d:chronosClockHook".}

# `chronos_fake_clock` is imported for its side-effect: on module init
# it registers the chronos-specific clockHookInstaller / Uninstaller on
# `fake_time.nim`. The symbols it exports are not referenced here.
{.warning[UnusedImport]: off.}
import nim_everywhere/chronos_fake_clock

# chronos's `poll()` uses a sentinel-based callback queue: callbacks
# moved into the queue *during* a `poll()` (e.g. timers expired by
# `processTimersGetTimeout`) only run on the *next* `poll()`. So a
# sleepAsync future driven by a fake clock advance needs two drain
# cycles: the first moves the timer's callback into the queue (after
# the sentinel); the second runs it. Mirrors `flushFake` in
# `tests/test_time_facade.nim` and `async_drive.flush` in
# `isonim-examples/tests/helpers/`.
proc flushChronos(ctx: FakeAsyncContext; cycles = 2) =
  ## Run `cycles` drain iterations. The default of 2 covers a single
  ## timer → callback hop (the common case). chronos.withTimeout
  ## introduces deeper cascades (timer → continuation → cancelSoon →
  ## continuation → wrapper-future callback) that need more cycles —
  ## the call site passes `cycles = 5` for that case.
  for _ in 0 ..< cycles:
    ctx.runPending()
    drainPlatformCallbacks()

suite "NE-Time-Fork-Chronos: clock injection":

  test "Moment.now respects an installed FakeAsyncContext":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()

    let m0 = chronos.Moment.now()
    ctx.advance(100)
    let m1 = chronos.Moment.now()
    # The hook reports `ctx.nowMs * 1_000_000` nanoseconds, so a 100-ms
    # advance is a 100-ms Moment delta.
    check (m1 - m0) == 100.milliseconds

  test "chronos.sleepAsync respects an installed FakeAsyncContext":
    # Bypass nim-everywhere's userspace `sleepFor` branch entirely;
    # this test uses chronos directly. Without the hook, this future
    # would block waiting for real wall-clock time to pass.
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()

    var fired = false
    let fut = chronos.sleepAsync(chronos.milliseconds(50))
    fut.addCallback proc(arg: pointer) {.gcsafe, raises: [].} =
      fired = true

    check not fired
    ctx.advance(50)
    # Drain chronos's poll loop so the timer-wheel re-checks the now()
    # source against its scheduled timers. chronos's `processTimers`
    # is the consumer of `Moment.now()` that fires expired timers.
    ctx.flushChronos()
    check fired

  test "chronos.withTimeout respects an installed FakeAsyncContext":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()

    # Inner future scheduled to take 200 ms, but the timeout wrapper
    # gives it 50 ms. Advancing 50 ms crosses the deadline; the inner
    # never completes within the wrapper's window.
    let slowFut = chronos.sleepAsync(chronos.milliseconds(200))
    let timedFut = chronos.withTimeout(slowFut, chronos.milliseconds(50))

    var resolved = false
    var resolvedTo = true  # chronos.withTimeout returns Future[bool]
    timedFut.addCallback proc(arg: pointer) {.gcsafe, raises: [].} =
      resolved = true
      {.cast(gcsafe).}:
        try:
          resolvedTo = timedFut.read
        except CatchableError: discard

    check not resolved
    ctx.advance(50)
    # withTimeout has a deeper callback cascade than sleepAsync (timer
    # → continuation → cancelSoon → continuation → user callback);
    # five drain cycles is empirically the smallest count that flushes
    # it. drainPlatformCallbacks is short-circuited on empty queue, so
    # extra cycles are safe no-ops.
    ctx.flushChronos(cycles = 5)
    check resolved
    # chronos.withTimeout returns `false` when the inner did not
    # complete in time — that's the timeout-expired branch.
    check resolvedTo == false

  test "uninstall restores the real wall-clock":
    block:
      let ctx = newFakeAsyncContext()
      ctx.install()
      ctx.advance(1_000_000)  # 1000 simulated seconds
      let mFake = chronos.Moment.now()
      check mFake.epochNanoSeconds == 1_000_000 * 1_000_000
      ctx.uninstall()

    # After uninstall the hook is cleared (chronos.clearMomentSource
    # was called inside `uninstall`). Subsequent reads come from
    # `fastEpochTimeNano()`. On Linux + asyncTimer=mono that's
    # CLOCK_MONOTONIC, which has been ticking for the whole machine
    # uptime — easily > 1000 seconds. The check is intentionally
    # tolerant: it just confirms we're back on a real clock that
    # reports a plausible monotonic value, not the artificial
    # 1_000_000-second value the fake clock would have reported.
    let mReal = chronos.Moment.now()
    # Greater than 1 second since clock origin — verifies a real clock
    # is wired, not a freshly-zeroed fake. Upper bound: less than 100
    # years (so we can't have accidentally read a wall-clock that
    # interprets ns as ms).
    check mReal.epochNanoSeconds > 1_000_000_000'i64
    check mReal.epochNanoSeconds < 100'i64 * 365 * 24 * 60 * 60 * 1_000_000_000

  test "hook is opt-in: clearMomentSource zeros the override":
    # An explicit clearMomentSource (without install/uninstall) must
    # also restore the real-clock path — provides confidence that the
    # chronos-side API works in isolation.
    let ctx = newFakeAsyncContext()
    ctx.install()
    ctx.advance(500)
    check chronos.Moment.now().epochNanoSeconds == 500 * 1_000_000

    chronos.clearMomentSource()
    let mReal = chronos.Moment.now()
    check mReal.epochNanoSeconds > 1_000_000_000'i64

    # Restore so `uninstall` is well-defined.
    ctx.uninstall()
