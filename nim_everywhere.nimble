version       = "0.1.0"
author        = "Metacraft Labs"
description   = "Cross-target Nim platform seams for native and JavaScript backends"
license       = "MIT"
srcDir        = "src"

requires "nim >= 2.0.0"

# chronos is listed as a hard requirement so that consumers who build
# nim-everywhere with `-d:asyncBackend=chronos` do not encounter a
# "missing dependency" error. The dependency is only *imported* when
# `-d:asyncBackend=chronos` is active (see
# `src/nim_everywhere/async_compat.nim`); the default native backend is
# `asyncdispatch` and pulls in no extra deps. Conditional `requires`
# clauses aren't supported by nimble cleanly, so we unconditionally
# declare the dep and let `when asyncBackend == "chronos"` gate the
# actual import.
requires "chronos >= 4.0.0"
