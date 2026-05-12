# nim-everywhere build configuration.
#
# When `-d:chronosClockHook` is active, the build must resolve `import
# chronos` to the local fork at `~/metacraft/nim-chronos` (which carries
# the setMomentSource / clearMomentSource patch) instead of the nimble-
# installed copy. The path is hard-coded because this is dev-time
# machinery — once the chronos PR lands upstream, this snippet goes
# away.
#
# NE-Time-Fork-Chronos milestone — see
# `codetracer-specs/Front-Ends/IsoNim/nim-everywhere-Time-Facade.milestones.org`.

when defined(chronosClockHook):
  switch("path", "/home/zahary/metacraft/nim-chronos")

# Note on `-d:asyncdispatchClockHook`:
#
# The asyncdispatch clock-injection hook lives in the existing Nim
# fork at `~/metacraft/codetracer-nim/lib`. Activating it requires a
# `--lib:` redirect to that path. Unlike the chronos override above,
# the `--lib:` switch CANNOT be set from `config.nims` — Nim's global
# nim.cfg expands `$lib/pure`, `$lib/std`, etc. into auto-included
# `path=` entries at the time the global config is parsed, which
# happens BEFORE the project's `config.nims` runs (per
# `compiler/nimconf.nim:loadConfigs`). A `switch("lib", ...)` here
# therefore arrives too late — the `$lib/pure` paths have already
# been resolved against the upstream prefix and `import std/private/
# miscdollars` resolves to the upstream copy.
#
# Workaround: the `--lib:` switch is passed on the command line by
# the Justfile recipes `test-time-asyncdispatch-hook` and
# `test-time-facade-asyncdispatch-hook` (and the parent agent passes
# it explicitly when running these tests manually). Cmdline switches
# are processed before any configs, so `$lib` expansion picks them
# up. Once the hook lands upstream this redirect goes away.
