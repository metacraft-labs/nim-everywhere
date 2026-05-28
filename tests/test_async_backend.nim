## NE-Async-M0 backend matrix tests.
##
## Verifies the public `async_compat` surface — `PlatformFuture`,
## `onComplete`, `newCompletedFuture`, `newFailedFuture`,
## `drainPlatformCallbacks`, and `sleepFor` — under every native
## backend (`asyncdispatch`, `chronos`, `none`) and the default (no
## `-d:asyncBackend`).
##
## Run via the Justfile matrix targets:
##   just test-async-default
##   just test-async-asyncdispatch
##   just test-async-chronos
##   just test-async-none

import std/unittest
import nim_everywhere
when asyncBackend in ["", "asyncdispatch", "chronos"]:
  import std/times  # epochTime; only used by the real-sleep test below

suite "nim-everywhere async backend (matrix)":
  test "default backend exposes PlatformFuture and onComplete":
    var seen = 0
    var errSeen = ""
    newCompletedFuture(42).onComplete(
      proc(v: int) = seen = v,
      proc(m: string) = errSeen = m)
    drainPlatformCallbacks()
    check seen == 42
    check errSeen == ""

  test "newFailedFuture surfaces error message":
    var seen = 0
    var err = ""
    newFailedFuture[int]("boom").onComplete(
      proc(v: int) = seen = v,
      proc(m: string) = err = m)
    drainPlatformCallbacks()
    check seen == 0
    check err == "boom"

  test "void future completes via onComplete(proc())":
    let fut = newCompletedFuture()
    var done = false
    var err = ""
    fut.onComplete(
      proc() = done = true,
      proc(m: string) = err = m)
    drainPlatformCallbacks()
    check done
    check err == ""

  test "real sleepFor advances real wall clock when no fake context installed":
    # The `none` backend has no event loop, so the real-sleep path is
    # not available. Skip that backend; the fake-time test in
    # test_fake_time.nim covers the `none` backend instead.
    when asyncBackend in ["", "asyncdispatch", "chronos"]:
      let started = epochTime()
      let fut = sleepFor(30)
      waitFor fut
      let elapsed = epochTime() - started
      check elapsed >= 0.025  # tolerant lower bound
      check elapsed < 0.500   # tolerant upper bound
    else:
      check true  # backend has no real sleep path; covered by fake-time tests
