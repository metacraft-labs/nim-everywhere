## Scripted callbacks are intentional: this test verifies interception itself,
## without waiting for wall time or contacting an external HTTP service.
import std/unittest
import nim_everywhere/[backend, time, http, platform]

suite "platform backend hook":
  test "clock timers http and cancellation are intercepted":
    var calls: seq[string]
    var pending: proc()
    installBackendHook(PlatformBackendHook(
      monotonicNowMs: proc(): int64 =
        calls.add("now")
        42,
      schedule: proc(ms: int; cb: proc()): proc() =
        calls.add("timer:" & $ms)
        pending = cb
        result = proc() = calls.add("cancel"),
      fetch: proc(req: HttpRequest): PlatformFuture[HttpResponse] =
        calls.add(req.url)
        newCompletedFuture(response(201, "hook"))))
    defer: installBackendHook(nil)
    check monotonicNowMs() == 42
    var fired = 0
    let handle = scheduleAt(7, proc() = inc fired)
    check fired == 0
    pending()
    check fired == 1
    cancelTimer(handle)
    pending()
    check fired == 1
    discard fetchHttp(HttpRequest(url: "/test"))
    check calls == @["now", "timer:7", "cancel", "/test"]
  test "periodic timers and sleep use the hook":
    var delays: seq[int]
    var pending: proc()
    var cancellations = 0
    installBackendHook(PlatformBackendHook(
      schedule: proc(ms: int; cb: proc()): proc() =
        delays.add(ms)
        pending = cb
        result = proc() = inc cancellations))
    defer: installBackendHook(nil)
    var ticks = 0
    let every = scheduleEvery(5, proc() = inc ticks)
    check ticks == 0
    pending()
    pending()
    check ticks == 2
    check delays == @[5, 5, 5]
    cancelTimer(every)
    pending()
    check ticks == 2
    check cancellations == 1
    discard sleepFor(4)
    check delays == @[5, 5, 5, 4]
    pending()
  test "fake context remains authoritative":
    installBackendHook(PlatformBackendHook(monotonicNowMs: proc(): int64 = 999))
    let fake = newFakeAsyncContext()
    fake.install()
    defer:
      fake.uninstall()
      installBackendHook(nil)
    check monotonicNowMs() == 0
    var fired = 0
    discard scheduleAt(2, proc() = inc fired)
    fake.advance(2)
    fake.runPending()
    check fired == 1

when defined(js):
  proc realFetch() {.async.} =
    # A data URL exercises the real Fetch API without an external service.
    let resp = await fetchHttp(HttpRequest(url: "data:text/plain,real-body"))
    doAssert resp.status == 200
    doAssert resp.body == "real-body"
    doAssert resp.headers.len > 0
    echo "real-fetch: PASS"
  discard realFetch()
