## Fake-time machinery for deterministic async tests.
##
## A `FakeAsyncContext` simulates the passage of time without actually
## sleeping. When installed on the current thread, any call to
## `nim_everywhere/async_compat.sleepFor(ms)` queues a completion into the
## fake context instead of the real backend's sleep primitive. Tests then
## drive simulated time forward with `advance(ms)` + `runPending()` and
## observe the resulting future / signal updates synchronously.
##
## Cascade-handling convention: a fired callback may schedule another
## callback at the current `nowMs`. The drain loop re-checks the queue
## after every callback, so cascaded same-time callbacks fire within the
## same `advance(...)` / `runPending()` call. The canonical drain
## sequence is `advance(X); runPending()` — `runPending()` is a safe
## no-op when the queue is empty and exists so consumers can explicitly
## drain without bumping simulated time.
##
## Stable ordering invariant: when two callbacks are scheduled to fire at
## the same simulated time, they fire in scheduling order. This is
## implemented by tagging each entry with a monotonically-increasing
## sequence number and using it as the tie-breaker during sort.
##
## Nesting: `install` stores the previously-installed context (if any) so
## a later `uninstall` can restore it. This makes it safe for one test
## helper to install a context and call into another helper that
## installs its own.

import std/algorithm

type
  ScheduledEntry* = object
    firesAtMs*: int64
    sequence*: int
    callback*: proc() {.closure.}

  FakeAsyncContext* = ref object
    nowMs*: int64
    scheduled*: seq[ScheduledEntry]
    sequence*: int
    prior: FakeAsyncContext

# Per-thread storage of the currently-installed context. A nil value means
# "no fake context is installed for this thread" — sleepFor falls through
# to the real backend's sleep primitive in that case.
var currentContext {.threadvar.}: FakeAsyncContext

# Backend-specific hooks for native clock injection (NE-Time-Fork-Chronos
# and later NE-Time-Fork-Asyncdispatch). When set, these are invoked from
# `install` / `uninstall` so the backend's own timer wheel observes the
# fake clock — not just code paths that route through `sleepFor`.
#
# The hooks are procedure variables (not direct chronos / asyncdispatch
# imports) so this module remains backend-neutral. The backend-specific
# wiring module (e.g. `chronos_fake_clock.nim`) sets the procs on its
# own module init. Nil-by-default keeps the un-hook path zero-cost.
var clockHookInstaller*: proc(ctx: FakeAsyncContext) {.gcsafe.}
var clockHookUninstaller*: proc(ctx: FakeAsyncContext) {.gcsafe.}

proc newFakeAsyncContext*(): FakeAsyncContext =
  FakeAsyncContext(nowMs: 0, scheduled: @[], sequence: 0, prior: nil)

proc currentFakeContext*(): FakeAsyncContext =
  ## Returns the currently-installed `FakeAsyncContext` for this thread,
  ## or `nil` when no context is installed.
  currentContext

proc install*(ctx: FakeAsyncContext) =
  ## Make `ctx` the active fake context for the current thread. Any
  ## previously-installed context is stored on `ctx.prior` so a later
  ## `uninstall` restores it. Supports nested test contexts.
  ##
  ## When a backend-specific clock hook is registered (currently chronos
  ## via `chronos_fake_clock.nim`), it is invoked here so the backend's
  ## own timer wheel observes the fake clock.
  ctx.prior = currentContext
  currentContext = ctx
  if clockHookInstaller != nil:
    clockHookInstaller(ctx)

proc uninstall*(ctx: FakeAsyncContext) =
  ## Restore the previously-installed context (or `nil`). Calling
  ## `uninstall` on a context that is not currently installed is a no-op
  ## with respect to thread-local state, but still clears the saved
  ## `prior` pointer so the context can be re-installed cleanly.
  if clockHookUninstaller != nil:
    clockHookUninstaller(ctx)
  if currentContext == ctx:
    currentContext = ctx.prior
  ctx.prior = nil

proc now*(ctx: FakeAsyncContext): int64 =
  ctx.nowMs

proc schedule*(ctx: FakeAsyncContext; afterMs: int; callback: proc() {.closure.}) =
  ## Schedule `callback` to fire `afterMs` milliseconds from `ctx.nowMs`.
  ## `afterMs == 0` schedules at the current simulated time and the
  ## callback fires during the next drain (either as part of an
  ## in-progress drain, or on the next `advance` / `runPending` call).
  let entry = ScheduledEntry(
    firesAtMs: ctx.nowMs + afterMs.int64,
    sequence: ctx.sequence,
    callback: callback)
  ctx.sequence += 1
  ctx.scheduled.add(entry)

proc cmpEntries(a, b: ScheduledEntry): int =
  if a.firesAtMs < b.firesAtMs: -1
  elif a.firesAtMs > b.firesAtMs: 1
  elif a.sequence < b.sequence: -1
  elif a.sequence > b.sequence: 1
  else: 0

proc drainAtOrBeforeNow(ctx: FakeAsyncContext) =
  ## Fire all callbacks whose `firesAtMs <= ctx.nowMs`, in stable order.
  ## Newly-scheduled callbacks (added while a callback runs) are picked
  ## up on the next iteration of the outer loop if they qualify.
  while true:
    if ctx.scheduled.len == 0:
      break
    ctx.scheduled.sort(cmpEntries)
    if ctx.scheduled[0].firesAtMs > ctx.nowMs:
      break
    let entry = ctx.scheduled[0]
    ctx.scheduled.delete(0)
    entry.callback()

proc advance*(ctx: FakeAsyncContext; ms: int) =
  ## Advance simulated time by `ms` milliseconds and fire every callback
  ## scheduled at or before the new `nowMs`, in stable order.
  ctx.nowMs += ms.int64
  ctx.drainAtOrBeforeNow()

proc runPending*(ctx: FakeAsyncContext) =
  ## Fire any callbacks at-or-before the current `nowMs`. This is the
  ## drain step that picks up cascaded callbacks scheduled inside a
  ## previously-fired callback at the same simulated time.
  ctx.drainAtOrBeforeNow()
