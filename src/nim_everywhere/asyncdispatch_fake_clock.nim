## asyncdispatch clock-injection wiring for nim-everywhere's
## ``FakeAsyncContext``.
##
## When the build is configured with BOTH ``-d:asyncBackend=asyncdispatch``
## (or the empty default, which resolves to asyncdispatch) AND
## ``-d:asyncdispatchClockHook``, importing this module registers
## installer / uninstaller hooks on ``fake_time.nim`` so that whenever
## a ``FakeAsyncContext`` is installed (or uninstalled) the
## corresponding ``asyncdispatch.setMonoTimeSource`` /
## ``asyncdispatch.clearMonoTimeSource`` call fires under the hood.
## The end result: asyncdispatch's own timer wheel and every internal
## ``getMonoTime()`` consumer observes the fake clock — not just code
## that routes through ``nim-everywhere``'s ``sleepFor`` branch. This
## reaches ``sleepAsync``, ``withTimeout``, ``addTimer``,
## ``processTimers`` (the timer-wheel pop loop), ``drain``'s elapsed
## budget, and ``poll``'s deadline computation in one stroke.
##
## The forked Nim stdlib at ``~/metacraft/codetracer-nim/lib`` is the
## source of the ``setMonoTimeSource`` / ``clearMonoTimeSource`` exports.
## The hook is gated behind ``-d:asyncdispatchClockHook`` on the
## asyncdispatch side too, so unhooked builds of asyncdispatch are
## byte-equivalent to upstream (modulo a handful of file:line-number
## constants in embedded ``assert`` / ``raise`` strings — see
## ``codetracer-nim/RFC-clock-injection-hook.md``). The Nim stdlib
## fork is selected at compile time by passing
## ``--lib:/home/zahary/metacraft/codetracer-nim/lib`` on the command
## line (a ``switch("lib", ...)`` from ``config.nims`` is too late in
## Nim's config load order — see ``config.nims`` for details).
##
## This module is intentionally tiny — it exists so ``fake_time.nim``
## need not import asyncdispatch directly. Backends that don't ship
## the hook are free to compile without ever seeing this module.
##
## Conversion: ``FakeAsyncContext.nowMs`` is milliseconds;
## asyncdispatch's ``MonoTime`` (from ``std/monotimes``) stores
## nanoseconds since an arbitrary epoch (per
## ``std/monotimes.MonoTime.ticks``). ``MonoTime`` has no public
## constructor for arbitrary int64 values, so we synthesise one by
## adding a Duration to a default-initialised ``MonoTime`` (whose
## ``ticks`` field is 0). ``MonoTime() + initDuration(nanoseconds = n)``
## yields a ``MonoTime`` with ``ticks == n`` — the ``+`` operator on
## ``MonoTime`` is public.

import ./async_compat

when defined(asyncdispatchClockHook) and asyncBackend in ["", "asyncdispatch"]:
  # `fake_time`, `std/asyncdispatch`, and `std/monotimes` are only
  # referenced inside the activation block; un-flagged builds compile
  # to an effectively empty module (apart from re-exporting
  # `asyncBackend` via `async_compat`).
  import std/[asyncdispatch, monotimes, times]
  import ./fake_time

  proc installAsdClock(ctx: FakeAsyncContext) {.gcsafe.} =
    # Capture the context by reference so the source proc reads the
    # *current* `nowMs` on every clock consultation. The closure stays
    # alive as long as asyncdispatch holds the proc pointer (set by
    # setMonoTimeSource); `uninstallAsdClock` clears it on uninstall.
    asyncdispatch.setMonoTimeSource(proc(): MonoTime {.gcsafe.} =
      # ms → ns: build a MonoTime with `ticks == ctx.nowMs * 1_000_000`.
      MonoTime() + initDuration(nanoseconds = ctx.nowMs * 1_000_000))

  proc uninstallAsdClock(ctx: FakeAsyncContext) {.gcsafe.} =
    asyncdispatch.clearMonoTimeSource()

  # Wire the hooks on module init. `fake_time.nim` checks these on
  # every install / uninstall — nil-by-default keeps the un-flagged
  # build path zero-cost. Both threadvars are set on each thread that
  # imports this module; asyncdispatch's own `setMonoTimeSource` is
  # also threadvar-backed.
  clockHookInstaller = installAsdClock
  clockHookUninstaller = uninstallAsdClock
