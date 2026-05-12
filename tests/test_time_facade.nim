## NE-Time-M0 expanded time facade tests.
##
## Covers every Verification entry in the milestone spec
## (`codetracer-specs/Front-Ends/IsoNim/nim-everywhere-Time-Facade.milestones.org`):
##
##   - monotonicNowMs respects the installed FakeAsyncContext.
##   - withTimeout: some on inner-first, none on deadline-first, error
##     propagation when the inner future fails, and the late-completion
##     no-op when the inner finishes after the deadline.
##   - scheduleAt: one-shot semantics + cancellation.
##   - scheduleEvery: periodic firing under fake time + cancel-stop.
##   - cancelTimer: idempotency + pre-firing cancellation.
##   - Real-time fall-through: scheduleAt fires after ~ms ms of real
##     wall-clock when no fake context is installed (gated to backends
##     with an event loop).
##
## Run via the Justfile matrix: `test-time-facade-{default,
## asyncdispatch,chronos,none}` and `test-time-matrix`.

import std/[options, unittest]
import nim_everywhere

when asyncBackend in ["", "asyncdispatch", "chronos"]:
  import std/times  # epochTime; only used by the real-wall-clock test below

# Helper: complete a fake-time-driven cascade through chronos's
# `callSoon` deferral.
#
# Under chronos, completing a future from inside an `advance(...)` call
# queues callbacks via `callSoon` — they only run on the next `poll()`.
# `withTimeout` introduces a two-level cascade (deadline → wrapper →
# user), so a single `advance + runPending + drain` cycle only resolves
# one level. The canonical fix (mirroring `async_drive.flush()` in
# `isonim-examples/tests/helpers/async_drive.nim`) is to run the cycle
# twice. Calling `drainPlatformCallbacks()` more times than necessary
# is fine on asyncdispatch (it's a no-op `poll(0)`) but blocks on
# chronos (a callback-empty `poll()` waits for the next timer), so we
# interleave with `runPending()` to advance the fake-time work between
# drains rather than over-calling drain.
proc flushFake(ctx: FakeAsyncContext) =
  # Two cycles cover up to a one-level chained completion. The
  # `withTimeout` wrapper introduces an extra hop (deadline → wrapper
  # future → user callback), but chronos's `processCallbacks` runs the
  # outgoing callback queue twice per `poll()` — so two drains are
  # enough to flush a two-step cascade. A third drain is unsafe under
  # chronos because, when nothing's pending, `poll()` blocks waiting
  # for the next timer (there is none). Matches the cadence of
  # `async_drive.flush()` in `isonim-examples/tests/helpers/`.
  ctx.runPending()
  drainPlatformCallbacks()
  ctx.runPending()
  drainPlatformCallbacks()

suite "NE-Time-M0: expanded time facade":

  test "monotonicNowMs respects fake context":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    check monotonicNowMs() == 0
    ctx.advance(50)
    check monotonicNowMs() == 50
    ctx.advance(150)
    check monotonicNowMs() == 200

  test "monotonicNowMs falls through to real clock when no fake context":
    # Without an installed fake context, monotonicNowMs reads
    # `getMonoTime`. We assert two reads are monotonically non-decreasing
    # rather than comparing to wall-clock — the test only needs to
    # confirm the real path is taken (the fake-path branch above returned
    # 0; this one cannot return 0 unless something is very wrong).
    let a = monotonicNowMs()
    let b = monotonicNowMs()
    check b >= a
    check a > 0  # process has been alive for at least 1 ms

  test "withTimeout — inner completes first → some":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    let inner = newFuture[int]("inner")
    let wrapper = withTimeout(inner, 50)
    var got: Option[int]
    var errSeen = ""
    wrapper.onComplete(
      proc(v: Option[int]) = got = v,
      proc(m: string) = errSeen = m)

    ctx.schedule(30, proc() = inner.complete(42))
    ctx.advance(30)
    ctx.flushFake()

    check got.isSome
    check got.get == 42
    check errSeen == ""

  test "withTimeout — deadline elapses → none; late inner does not update wrapper":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    let inner = newFuture[int]("inner-late")
    let wrapper = withTimeout(inner, 50)
    var got: Option[int]
    var resolveCount = 0
    var errSeen = ""
    wrapper.onComplete(
      proc(v: Option[int]) =
        got = v
        resolveCount = resolveCount + 1
      ,
      proc(m: string) = errSeen = m)

    # Inner future scheduled to complete at +100; deadline at +50.
    ctx.schedule(100, proc() = inner.complete(99))

    # Cross the deadline.
    ctx.advance(50)
    ctx.flushFake()

    check got.isNone
    check resolveCount == 1
    check errSeen == ""

    # Cross the inner's late firing. The inner future completes (we
    # can observe it directly), but the wrapper MUST NOT update.
    ctx.advance(50)
    ctx.flushFake()

    check got.isNone        # wrapper still none
    check resolveCount == 1  # wrapper resolved exactly once
    check inner.finished
    check not inner.failed
    check inner.read == 99

  test "withTimeout — inner fails before deadline → error propagates":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    let inner = newFuture[int]("inner-fail")
    let wrapper = withTimeout(inner, 50)
    var got: Option[int]
    var errSeen = ""
    wrapper.onComplete(
      proc(v: Option[int]) = got = v,
      proc(m: string) = errSeen = m)

    ctx.schedule(30, proc() =
      inner.fail(newException(CatchableError, "inner exploded")))
    ctx.advance(30)
    ctx.flushFake()

    check got.isNone           # wrapper did not resolve to some(...)
    check errSeen == "inner exploded"

  test "scheduleAt — one-shot fires exactly once at the target tick":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    var fired = 0
    let h = scheduleAt(50, proc() = inc fired)
    check fired == 0

    ctx.advance(49)
    ctx.flushFake()
    check fired == 0

    ctx.advance(1)
    ctx.flushFake()
    check fired == 1

    # Advance well past — does not re-fire.
    ctx.advance(200)
    ctx.flushFake()
    check fired == 1

    # Cancel after firing is a no-op (idempotency).
    cancelTimer(h)
    check fired == 1

  test "scheduleEvery — fires N times during a fake-time advance":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    var count = 0
    let h = scheduleEvery(10, proc() = inc count)

    ctx.advance(100)
    ctx.flushFake()
    check count == 10

    # Cancel — no further firings.
    cancelTimer(h)
    ctx.advance(50)
    ctx.flushFake()
    check count == 10

  test "cancelTimer prevents pending one-shot from firing":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    var fired = false
    let h = scheduleAt(100, proc() = fired = true)
    check not fired

    # Cancel before the target tick.
    cancelTimer(h)
    ctx.advance(200)
    ctx.flushFake()
    check not fired

  test "cancelTimer is idempotent":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    var fired = 0
    let h = scheduleAt(50, proc() = inc fired)
    cancelTimer(h)
    cancelTimer(h)       # second call must not raise
    cancelTimer(nil)     # nil-handle guard

    ctx.advance(100)
    ctx.flushFake()
    check fired == 0

  test "scheduleEvery cancellation does not leak past the current firing":
    # Subtle: when scheduleEvery's callback calls cancelTimer(h) from
    # *inside* its own firing, the next periodic schedule must NOT
    # happen. Without the inner cancellation check, the re-schedule
    # closure would queue a new sleepFor.
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    var count = 0
    var hRef: TimerHandle = nil
    hRef = scheduleEvery(10, proc() =
      inc count
      if count == 3:
        cancelTimer(hRef))

    ctx.advance(200)
    ctx.flushFake()
    # Exactly 3 firings: the self-cancellation inside the 3rd fire
    # prevents the re-schedule from arming a 4th.
    check count == 3

  test "real-time fall-through (no fake context installed)":
    # Without an installed fake context, scheduleAt(30) fires after
    # ~30 ms of real wall-clock. Gated to backends with an event loop;
    # asyncBackend=none has no way to drive the future to completion.
    when asyncBackend in ["", "asyncdispatch", "chronos"]:
      var fired = false
      discard scheduleAt(30, proc() = fired = true)
      let started = epochTime()
      while not fired and (epochTime() - started) < 0.500:
        # drain whatever the backend has ready; sleepFor under real
        # time funnels into the backend's poll loop. Under chronos
        # `poll()` may block until the next timer expires — that's
        # how the wall-clock advances inside the loop.
        drainPlatformCallbacks()
      let elapsed = epochTime() - started
      check fired
      check elapsed >= 0.025   # tolerant lower bound
      check elapsed < 0.500    # tolerant upper bound
    else:
      check true   # no event loop on `asyncBackend=none`; covered by fake-time tests
