## Cross-target time facade for nim-everywhere.
##
## Builds on `async_compat.nim` (PlatformFuture + onComplete + sleepFor)
## and `fake_time.nim` (FakeAsyncContext) to give downstream IsoNim apps
## a single entry point for every time-related operation they typically
## need:
##
##   sleepFor(ms)            — relocated from async_compat; signature unchanged.
##   monotonicNowMs()        — int64 ms; respects an installed FakeAsyncContext.
##   withTimeout(fut, ms)    — race a future against a deadline; returns Option[T].
##   scheduleAt(afterMs, cb) — one-shot timer with cancellation.
##   scheduleEvery(ms, cb)   — periodic timer with cancellation.
##   cancelTimer(handle)     — stop pending firings; idempotent.
##
## All primitives route through `FakeAsyncContext` when one is installed
## on the current thread; otherwise they fall through to the backend's
## native primitives via `sleepFor`. This means a test that installs a
## fake context controls every clock the app touches through this
## module, without per-call ceremony.
##
## ### Module placement (NE-Time-M0 — Option A1)
##
## `sleepFor` lives here now, not in `async_compat.nim`. The split keeps
## the bare async surface (PlatformFuture, onComplete, newCompletedFuture,
## drainPlatformCallbacks) in `async_compat.nim` so consumers that only
## need the future plumbing don't pull in timer machinery. The umbrella
## `nim_everywhere.nim` re-exports both modules so `import nim_everywhere`
## continues to work for every existing caller (isonim editor's
## streaming_preview, the EX-M17 fake_db, the EX-M18 tests).
##
## ### Cancellation semantics
##
## `TimerHandle` carries a `cancelled` flag the scheduled closure checks
## before firing (one-shot) or before re-scheduling (periodic). Under
## fake time the closure also checks before firing each periodic tick:
## cancelling between an `advance` boundary and the next `runPending`
## drain prevents the queued callback from executing. Under real time
## (no fake context), the implementation uses the same `sleepFor`-backed
## closure pattern — cancellation prevents the *next* firing but a
## firing already mid-`sleepFor` callback continues to completion. Tests
## verify both semantics.
##
## ### Zero-cost-when-no-context
##
## With no fake context installed, every primitive funnels through
## `sleepFor`'s real-backend path — exactly the same path EX-M17/EX-M18
## already use in production. The only allocation per timer is the
## `TimerHandle` ref (necessary for cancellation), which matches the
## allocation profile of `addTimer` in asyncdispatch / chronos.

import std/[monotimes, options]

import ./async_compat
import ./fake_time

export async_compat
export fake_time

# Re-export Option helpers so callers of `withTimeout` don't need a
# separate `import std/options`.
export options.Option
export options.some
export options.none
export options.isSome
export options.isNone
export options.get

# ---------------------------------------------------------------------------
# sleepFor — relocated from async_compat.nim (signature unchanged).
# ---------------------------------------------------------------------------

proc sleepFor*(ms: int): PlatformFuture[void] =
  ## Cross-backend sleep primitive.
  ##
  ## If a `FakeAsyncContext` is installed on the current thread, the
  ## returned future completes when the fake context fires the
  ## scheduled callback (i.e. when test code calls `advance(ms)` +
  ## `runPending()`). The real backend's sleep primitive is bypassed
  ## entirely — this is what makes fake-time tests work uniformly
  ## across the matrix.
  ##
  ## When no fake context is installed, `sleepFor` falls through to:
  ##   - JS: `setTimeout(ms)`-backed Promise
  ##   - asyncdispatch: `std/asyncdispatch.sleepAsync(ms)`
  ##   - chronos: `chronos.sleepAsync(ms.milliseconds)`
  ##   - none: raises a Defect (no event loop, no fake context →
  ##           there is nothing that could wake the sleep)
  let fake = currentFakeContext()
  if fake != nil:
    when defined(js):
      var resolveFn: proc()
      result = newPromise proc(resolve: proc()) =
        resolveFn = resolve
      fake.schedule(ms, proc() = resolveFn())
    else:
      let fut = newFuture[void]("nim-everywhere sleepFor (fake-time)")
      fake.schedule(ms, proc() = fut.complete())
      result = fut
    return

  when defined(js):
    let msArg = ms
    result = newPromise proc(resolve: proc()) =
      {.emit: "setTimeout(function() { `resolve`(); }, `msArg`);".}
  else:
    when asyncBackend in ["", "asyncdispatch"]:
      result = sleepAsync(ms)
    elif asyncBackend == "chronos":
      result = chronos.sleepAsync(chronos.milliseconds(ms))
    elif asyncBackend == "none":
      raise newException(Defect,
        "sleepFor without an installed FakeAsyncContext requires an event loop; " &
        "build with -d:asyncBackend=asyncdispatch|chronos, or install a " &
        "FakeAsyncContext for deterministic tests")

# ---------------------------------------------------------------------------
# monotonicNowMs — int64 milliseconds, respecting the fake clock.
# ---------------------------------------------------------------------------

proc monotonicNowMs*(): int64 =
  ## Monotonic time in milliseconds. Returns `currentFakeContext().nowMs`
  ## when a fake context is installed (so tests advancing the fake clock
  ## see the advanced value); otherwise returns
  ## `getMonoTime().ticks div 1_000_000`. `std/monotimes` works on both
  ## native and JS (the JS backend reads `performance.now()`).
  let fake = currentFakeContext()
  if fake != nil:
    return fake.nowMs
  getMonoTime().ticks div 1_000_000

# ---------------------------------------------------------------------------
# TimerHandle — opaque cancellation handle.
# ---------------------------------------------------------------------------

type
  TimerHandle* = ref object
    ## Opaque cancellation handle. `cancelled` is checked by the
    ## scheduled closure before firing (one-shot) or before each
    ## re-schedule (periodic). The handle is allocated once per
    ## scheduleAt / scheduleEvery call and survives any number of
    ## firings until cancelled.
    cancelled*: bool

proc cancelTimer*(h: TimerHandle) =
  ## Stop pending firings. Idempotent — safe to call on an already-fired
  ## one-shot or an already-cancelled handle. After this call no new
  ## firings will occur, though a periodic firing already in flight (the
  ## user callback currently executing) is not interrupted.
  if h != nil:
    h.cancelled = true

# ---------------------------------------------------------------------------
# withTimeout — race a future against a deadline.
# ---------------------------------------------------------------------------

proc withTimeout*[T](fut: PlatformFuture[T]; ms: int): PlatformFuture[Option[T]] =
  ## Race `fut` against a deadline. Returns `some(value)` if `fut`
  ## completes within `ms` milliseconds, `none(T)` otherwise. If `fut`
  ## fails before the deadline, the wrapper propagates the failure (the
  ## timeout does not suppress errors).
  ##
  ## Late-completion semantics: once the wrapper resolves (either with
  ## `some`, `none`, or an error), it stays resolved. Subsequent
  ## completion of the inner future is observable on the inner future
  ## but does not retroactively update the wrapper. This is the OOO-guard
  ## pattern from `isonim/core/resource.nim`'s generation-counter
  ## (simplified here to a single boolean since there's only one race).
  ##
  ## Future extension (not yet shipped): a `withTimeoutVoid` overload for
  ## `PlatformFuture[void]` returning `PlatformFuture[bool]` (true on
  ## inner success, false on deadline). Add when a real consumer surfaces;
  ## not blocking on it because `withTimeout[int]` covers the canonical
  ## use case and the void path is trivial to derive once needed.
  let resolved = new(bool)
  resolved[] = false

  when defined(js):
    # JS path: build a Promise resolved by whichever onComplete fires
    # first. asyncjs's `newPromise` exposes the resolver to us; we
    # store both resolve and reject in let-bindings and route the
    # input + deadline callbacks through them.
    var resolveFn: proc(value: Option[T])
    var rejectFn: proc(reason: ref CatchableError)
    let outFut = newPromise proc(resolve: proc(value: Option[T])) =
      resolveFn = resolve
    # asyncjs doesn't expose a typed reject in the same proc shape, so
    # we synthesise rejection by raising — wrap that in a thrower.
    rejectFn = proc(reason: ref CatchableError) = raise reason
  else:
    let outFut = newFuture[Option[T]]("nim-everywhere withTimeout")

  let deadline = sleepFor(ms)

  fut.onComplete(
    onSuccess = proc(v: T) =
      if not resolved[]:
        resolved[] = true
        when defined(js):
          resolveFn(some(v))
        else:
          outFut.complete(some(v)),
    onError = proc(msg: string) =
      if not resolved[]:
        resolved[] = true
        when defined(js):
          # On JS, an exception thrown from the resolver body propagates
          # into the Promise's reject path — that's how asyncjs surfaces
          # failed completions.
          rejectFn(newException(CatchableError, msg))
        else:
          outFut.fail(newException(CatchableError, msg)))

  deadline.onCompleteVoid(
    onSuccess = proc() =
      if not resolved[]:
        resolved[] = true
        when defined(js):
          resolveFn(none(T))
        else:
          outFut.complete(none(T)),
    onError = proc(msg: string) = discard)
        # Deadline failure (rare; can only happen when -d:asyncBackend=none
        # raises out of sleepFor on the fake path) should not surface to
        # the wrapper — the inner future still has a chance to succeed.

  outFut

# ---------------------------------------------------------------------------
# scheduleAt / scheduleEvery / cancelTimer — timer primitives.
# ---------------------------------------------------------------------------

proc scheduleAt*(afterMs: int; cb: proc()): TimerHandle =
  ## One-shot timer. `cb` fires `afterMs` milliseconds after the call
  ## site. Under fake time, fires when `advance(...)` crosses the target
  ## tick. Under real time, fires after a `sleepFor(afterMs)` completes
  ## on the backend.
  ##
  ## Returns a `TimerHandle` callers can pass to `cancelTimer` to
  ## prevent the firing.
  ##
  ## Under fake time we schedule directly on the FakeAsyncContext so
  ## firing happens *within* the same `advance(...)` call rather than
  ## bouncing through the backend's `addCallback` queue (which would
  ## defer firing until the next `drainPlatformCallbacks`). Under real
  ## time we funnel through `sleepFor` so the backend's native timer
  ## drives the firing.
  let handle = TimerHandle(cancelled: false)
  let fake = currentFakeContext()
  if fake != nil:
    fake.schedule(afterMs, proc() =
      if not handle.cancelled:
        cb())
  else:
    let slept = sleepFor(afterMs)
    slept.onCompleteVoid(
      onSuccess = proc() =
        if not handle.cancelled:
          cb(),
      onError = proc(msg: string) = discard)
  handle

proc scheduleEvery*(intervalMs: int; cb: proc()): TimerHandle =
  ## Periodic timer. `cb` fires every `intervalMs` until cancelled.
  ## Under fake time, `advance(N)` fires the callback `floor(N/intervalMs)`
  ## times. Under real time, each firing schedules the next via
  ## `sleepFor(intervalMs)`.
  ##
  ## The re-scheduling closure checks the `TimerHandle.cancelled` flag
  ## *before* firing the user callback AND before re-scheduling. This
  ## prevents the failure mode where a periodic timer keeps firing after
  ## `cancelTimer` because the next firing was already queued.
  ##
  ## Fake-time path: schedule directly on the FakeAsyncContext so the
  ## re-arm closure runs in the same `advance(...)` window (the drain
  ## loop picks up cascaded same-time entries). Under real time we route
  ## through `sleepFor` which means each re-arm bounces through the
  ## backend's microtask queue — but that's exactly the cadence a real
  ## periodic timer would have.
  let handle = TimerHandle(cancelled: false)
  let fake = currentFakeContext()

  # Forward-declare the proc variable so the closure can refer to
  # itself for re-scheduling.
  var arm: proc()
  if fake != nil:
    # Track the absolute fake-time tick of the next firing so each
    # re-arm schedules relative to the *target* tick, not relative to
    # the current `nowMs` (which has already advanced past prior
    # firings inside the same `advance(...)` window). Without this, a
    # 10 ms periodic timer scheduled at t=0 and advanced through t=100
    # would only fire once (at t=10) before the next re-arm queues a
    # callback at t=110, well past the advance horizon.
    let nextFiresAt = new(int64)
    nextFiresAt[] = fake.nowMs + intervalMs.int64
    let ctx = fake
    arm = proc() =
      if handle.cancelled:
        return
      let delta = max(0, (nextFiresAt[] - ctx.nowMs).int)
      ctx.schedule(delta, proc() =
        if handle.cancelled:
          return
        cb()
        if not handle.cancelled:
          nextFiresAt[] = nextFiresAt[] + intervalMs.int64
          arm())
  else:
    arm = proc() =
      if handle.cancelled:
        return
      let slept = sleepFor(intervalMs)
      slept.onCompleteVoid(
        onSuccess = proc() =
          if handle.cancelled:
            return
          cb()
          if not handle.cancelled:
            arm(),
        onError = proc(msg: string) = discard)
  arm()
  handle
