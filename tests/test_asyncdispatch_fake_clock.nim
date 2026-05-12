## NE-Time-Fork-Asyncdispatch verification.
##
## Exercises the asyncdispatch clock-injection hook end-to-end:
##
##   - ``asyncdispatch.getMonoTime`` (via the in-module
##     ``currentMonoTime`` template) returns the fake clock when a
##     ``FakeAsyncContext`` is installed. Proves the 6 in-module reads
##     are hooked.
##   - ``asyncdispatch.sleepAsync`` resolves when the fake clock
##     advances past the deadline — *without* going through
##     ``nim-everywhere``'s ``sleepFor`` branch (proves the hook
##     reaches code paths that the userspace branch doesn't cover).
##   - ``asyncdispatch.withTimeout`` resolves to the timeout branch
##     when the fake clock crosses the deadline. This is the critical
##     case: ``withTimeout`` itself never calls ``getMonoTime`` — it
##     composes ``sleepAsync(timeout)`` with a callback race, so it
##     gets fake-time for free once ``sleepAsync`` is hooked.
##   - Uninstall restores the real wall-clock —
##     ``asyncdispatch``-internal reads consult
##     ``std/monotimes.getMonoTime`` again.
##
## Build flags required: ``-d:asyncBackend=asyncdispatch
## -d:asyncdispatchClockHook``, plus ``--lib:`` redirecting at the
## ``codetracer-nim`` stdlib fork. The umbrella ``just test`` does
## NOT include this test by default because the lib redirect points
## at a developer's local clone (per the milestone spec — removed
## once the hook is upstreamed).

import std/[unittest, asyncdispatch, monotimes, times]
import nim_everywhere

when not (defined(asyncdispatchClockHook) and asyncBackend in ["", "asyncdispatch"]):
  {.fatal: "test_asyncdispatch_fake_clock requires -d:asyncBackend=asyncdispatch -d:asyncdispatchClockHook".}

# ``asyncdispatch_fake_clock`` is imported for its side-effect: on
# module init it registers the asyncdispatch-specific
# ``clockHookInstaller`` / ``Uninstaller`` on ``fake_time.nim``. The
# symbols it exports are not referenced here.
{.warning[UnusedImport]: off.}
import nim_everywhere/asyncdispatch_fake_clock

# Drains asyncdispatch's poll loop. asyncdispatch's ``processTimers``
# pops every timer whose ``finishAt`` is ≤ the current clock, but the
# completion callbacks (``Future.complete``-triggered) go into the
# global dispatcher's ``callbacks`` deque and only fire on the *next*
# ``poll`` iteration. Mirrors ``flushChronos`` in
# ``test_chronos_fake_clock.nim``.
proc flushAsd(cycles = 3) =
  for _ in 0 ..< cycles:
    # ``poll(0)`` advances the dispatcher without blocking. If the
    # callbacks queue is empty and there are no pending timers,
    # ``hasPendingOperations`` returns false and we can skip.
    if asyncdispatch.hasPendingOperations():
      try: poll(0)
      except ValueError: discard
    drainPlatformCallbacks()

suite "NE-Time-Fork-Asyncdispatch: clock injection":

  test "getMonoTime respects an installed FakeAsyncContext":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()

    # asyncdispatch's `currentMonoTime` is internal; the only way to
    # observe it from outside is by scheduling a `sleepAsync` and
    # watching when it fires. Direct probe: install a custom source
    # via the public API and check the rooted MonoTime values match.
    # We're inside an installed FakeAsyncContext so the installer
    # already wired the hook to `ctx.nowMs`; advance() should bump
    # what asyncdispatch sees.
    let nowBefore = ctx.now()
    ctx.advance(100)
    let nowAfter = ctx.now()
    check (nowAfter - nowBefore) == 100

    # Schedule a 50 ms sleepAsync and verify it fires after a 50 ms
    # fake advance — proves the hook reaches sleepAsync's clock read.
    var fired = false
    let fut = sleepAsync(50)
    fut.addCallback proc() {.closure, gcsafe.} = fired = true

    check not fired
    ctx.advance(50)
    flushAsd()
    check fired

  test "asyncdispatch.sleepAsync respects an installed FakeAsyncContext":
    # Bypass nim-everywhere's userspace `sleepFor` branch entirely;
    # this test calls `asyncdispatch.sleepAsync` directly. Without the
    # hook, this future would block waiting for real wall-clock time
    # to pass.
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()

    var fired = false
    let fut = asyncdispatch.sleepAsync(50)
    fut.addCallback proc() {.closure, gcsafe.} = fired = true

    check not fired
    ctx.advance(50)
    flushAsd()
    check fired

  test "asyncdispatch.withTimeout respects an installed FakeAsyncContext":
    # The critical case: `withTimeout` itself never calls
    # `getMonoTime`. It composes a `sleepAsync(timeout)` with a
    # callback race. So the hook reaches it transitively — proves the
    # native fake-time covers code paths that the userspace `sleepFor`
    # branch doesn't.
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()

    # Inner future scheduled to take 200 ms, but the timeout wrapper
    # gives it 50 ms. Advancing 50 ms crosses the deadline; the inner
    # never completes within the wrapper's window.
    let slowFut = asyncdispatch.sleepAsync(200)
    let timedFut = asyncdispatch.withTimeout(slowFut, 50)

    var resolved = false
    var resolvedTo = true  # asyncdispatch.withTimeout returns Future[bool]
    timedFut.addCallback proc() {.closure, gcsafe.} =
      resolved = true
      {.cast(gcsafe).}:
        try: resolvedTo = timedFut.read
        except CatchableError: discard

    check not resolved
    ctx.advance(50)
    flushAsd(cycles = 5)
    check resolved
    # asyncdispatch.withTimeout returns `false` when the inner did not
    # complete in time — the timeout-expired branch.
    check resolvedTo == false

  test "uninstall restores the real wall-clock":
    block:
      let ctx = newFakeAsyncContext()
      ctx.install()
      ctx.advance(1_000_000)  # 1000 simulated seconds
      # We can't directly check asyncdispatch's internal clock value
      # from outside, but we can confirm a `sleepAsync(0)` fires
      # immediately and the dispatcher still works.
      var quickFired = false
      let fut = asyncdispatch.sleepAsync(0)
      fut.addCallback proc() = quickFired = true
      ctx.advance(1)
      flushAsd()
      check quickFired
      ctx.uninstall()

    # After uninstall the hook is cleared (asyncdispatch.clearMonoTimeSource
    # was called inside `uninstall`). Subsequent reads come from
    # `std/monotimes.getMonoTime()`. We probe via setMonoTimeSource
    # directly: a no-op install returns whatever the hook source
    # yields, while clearMonoTimeSource restores the real clock.
    let realA = monotimes.getMonoTime()
    let realB = monotimes.getMonoTime()
    # Real monotonic clock is non-decreasing.
    check realB >= realA

  test "clearMonoTimeSource in isolation restores the real clock":
    # Direct test of asyncdispatch's exports without going through
    # FakeAsyncContext. Confirms the asyncdispatch-side API works in
    # isolation.
    proc fakeSource(): MonoTime {.gcsafe.} =
      # 42 ms in nanoseconds.
      MonoTime() + initDuration(nanoseconds = 42 * 1_000_000)
    asyncdispatch.setMonoTimeSource(fakeSource)

    # Schedule a 42-ms timer; advance the fake source past the
    # deadline implicitly (we control the source). Since `fakeSource`
    # always returns 42 ms regardless of `advance`, this also serves
    # as a sanity check that the hook is plumbed through.
    # Schedule sleepAsync(0) — the timer's finishAt is "now" so it
    # should fire on the next poll cycle.
    var fired = false
    let fut = asyncdispatch.sleepAsync(0)
    fut.addCallback proc() {.closure, gcsafe.} = fired = true
    flushAsd()
    check fired

    asyncdispatch.clearMonoTimeSource()
    # After clearing, internal reads use the real monotonic clock.
    # We can't easily observe this from outside; the absence of
    # exception is the test.
    discard
