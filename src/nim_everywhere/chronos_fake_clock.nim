## Chronos clock-injection wiring for nim-everywhere's FakeAsyncContext.
##
## When the build is configured with BOTH `-d:asyncBackend=chronos` AND
## `-d:chronosClockHook`, importing this module registers installer /
## uninstaller hooks on `fake_time.nim` so that whenever a
## `FakeAsyncContext` is installed (or uninstalled) the corresponding
## `chronos.setMomentSource` / `chronos.clearMomentSource` call fires
## under the hood. The end result: chronos's own timer wheel and every
## internal `Moment.now()` consumer observes the fake clock — not just
## code that routes through `nim-everywhere`'s `sleepFor` branch.
##
## The forked chronos at `metacraft-labs/nim-chronos` is the source of
## `setMomentSource` / `clearMomentSource`. The hook is gated behind
## `-d:chronosClockHook` on the chronos side too, so unhooked builds of
## chronos are byte-identical to upstream.
##
## This module is intentionally tiny — it exists so `fake_time.nim` need
## not import chronos directly. Backends that don't ship the hook are
## free to compile without ever seeing this module.
##
## Conversion: `FakeAsyncContext.nowMs` is milliseconds; chronos's
## `Moment` value is nanoseconds (per `chronos/timer.nim`'s
## `fastEpochTimeNano`). The hook multiplies by 1_000_000 to scale.

import ./async_compat

when defined(chronosClockHook) and asyncBackend == "chronos":
  # `fake_time` and `chronos` are only referenced inside the activation
  # block; un-flagged builds compile to an effectively empty module
  # (apart from re-exporting `asyncBackend` via `async_compat`).
  import ./fake_time
  import chronos

  proc installChronosClock(ctx: FakeAsyncContext) {.gcsafe.} =
    # Capture the context by reference so the source proc reads the
    # *current* `nowMs` on every `Moment.now()` call. The closure stays
    # alive as long as chronos holds the proc pointer (set by
    # setMomentSource); `uninstallChronosClock` clears it on uninstall.
    chronos.setMomentSource(proc(): chronos.Moment {.gcsafe, raises: [].} =
      chronos.Moment.init(ctx.nowMs * 1_000_000, chronos.Nanosecond))

  proc uninstallChronosClock(ctx: FakeAsyncContext) {.gcsafe.} =
    chronos.clearMomentSource()

  # Wire the hooks on module init. `fake_time.nim` checks these on every
  # install / uninstall — nil-by-default keeps the un-flagged build path
  # zero-cost. Both threadvars are set on each thread that imports this
  # module; chronos's own `setMomentSource` is also threadvar-backed.
  clockHookInstaller = installChronosClock
  clockHookUninstaller = uninstallChronosClock
