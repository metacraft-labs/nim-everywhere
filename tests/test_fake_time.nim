## NE-Async-M0 fake-time tests.
##
## Verifies `FakeAsyncContext` and its integration with `sleepFor`
## across every native backend. The "100 ops under 100 ms wall-clock"
## test is the headline assertion for the milestone — it proves that
## the fake clock decouples test time from real time even when the
## underlying async backend is fully real.

import std/[times, unittest]
import nim_everywhere

suite "FakeAsyncContext":
  test "advance fires scheduled callbacks at-or-before the new time":
    let ctx = newFakeAsyncContext()
    var fired = 0
    ctx.schedule(50, proc() = fired = 1)
    check fired == 0
    ctx.advance(49)
    check fired == 0
    ctx.advance(1)
    check fired == 1

  test "install routes sleepFor through fake context":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    var completed = false
    var err = ""
    let fut = sleepFor(50)
    fut.onComplete(proc() = completed = true, proc(m: string) = err = m)
    check not completed
    ctx.advance(50)
    ctx.runPending()
    drainPlatformCallbacks()
    check completed
    check err == ""

  test "stable ordering at same time":
    let ctx = newFakeAsyncContext()
    var order: seq[int] = @[]
    ctx.schedule(10, proc() = order.add 1)
    ctx.schedule(10, proc() = order.add 2)
    ctx.schedule(10, proc() = order.add 3)
    ctx.advance(10)
    check order == @[1, 2, 3]

  test "interleaved operations at different times":
    let ctx = newFakeAsyncContext()
    var fired: seq[string] = @[]
    ctx.schedule(30, proc() = fired.add "a")
    ctx.schedule(80, proc() = fired.add "b")
    ctx.advance(50)
    check fired == @["a"]
    ctx.advance(50)
    check fired == @["a", "b"]

  test "cascaded schedule at same simulated time fires within the same drain":
    let ctx = newFakeAsyncContext()
    var order: seq[int] = @[]
    ctx.schedule(10, proc() =
      order.add 1
      ctx.schedule(0, proc() = order.add 2))
    ctx.advance(10)
    check order == @[1, 2]

  test "uninstall restores prior context (supports nesting)":
    let outer = newFakeAsyncContext()
    let inner = newFakeAsyncContext()
    check currentFakeContext() == nil
    outer.install()
    check currentFakeContext() == outer
    inner.install()
    check currentFakeContext() == inner
    inner.uninstall()
    check currentFakeContext() == outer
    outer.uninstall()
    check currentFakeContext() == nil

  test "100 ops complete in well under 100 ms wall-clock":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    let started = epochTime()
    var completedCount = 0
    for i in 0 ..< 100:
      let fut = sleepFor(30)
      fut.onComplete(
        proc() = completedCount += 1,
        proc(m: string) = discard)
    ctx.advance(30)
    ctx.runPending()
    drainPlatformCallbacks()
    let elapsed = epochTime() - started
    check completedCount == 100
    check elapsed < 0.100  # < 100 ms for 100 simulated 30 ms ops
