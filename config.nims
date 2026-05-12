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
