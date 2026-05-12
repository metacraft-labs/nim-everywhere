import std/unittest
import nim_everywhere

suite "nim_everywhere async and HTTP seams":
  test "NativeString and native collections compile on both targets":
    let greeting = "hello".toNative()
    check greeting == "hello".toNative()
    let combined = greeting & " world".toNative()
    check combined == "hello world".toNative()

    var names = newNativeSeq[string]()
    names.add "alpha"
    check names.len == 1

    var seen = newHashSet[NativeString]()
    seen.incl "alpha".toNative()
    check "alpha".toNative() in seen

    var scores = newHashMap[NativeString, int]()
    scores["alpha".toNative()] = 1
    check scores["alpha".toNative()] == 1

    let refs = newHashMapRef[NativeString, int]()
    refs["beta".toNative()] = 2
    check refs["beta".toNative()] == 2

  test "completed and failed futures have deterministic callbacks":
    var valueSeen = 0
    var errorSeen = ""

    newCompletedFuture(42).onComplete(
      proc(value: int) = valueSeen = value,
      proc(message: string) = errorSeen = message)
    drainPlatformCallbacks()

    check valueSeen == 42
    check errorSeen == ""

    newFailedFuture[int]("planned failure").onComplete(
      proc(value: int) = valueSeen = value,
      proc(message: string) = errorSeen = message)
    drainPlatformCallbacks()

    check errorSeen == "planned failure"

  test "fake HTTP transport supports async request API":
    let fake = newFakeHttp(@[
      response(201, """{"ok":true}""")
    ])
    let transport = fake.asyncTransport()
    var received = response(0)
    var errorSeen = ""

    transport.requestAsync(newRequest(hmPost, "/tasks", "{}")).onComplete(
      proc(value: HttpResponse) = received = value,
      proc(message: string) = errorSeen = message)
    drainPlatformCallbacks()

    check errorSeen == ""
    check received.status == 201
    check parseJsonText(received.body)["ok"].getBool()
    check fake.requests.len == 1
    check fake.requests[0].url == "/tasks"

  test "fetch transport exposes cross-target async wrapper":
    let transport = fetchHttpTransport()
    when defined(js):
      check transport != nil
    else:
      var errorSeen = ""
      transport.requestAsync(newRequest(hmGet, "https://example.invalid")).onComplete(
        proc(value: HttpResponse) = discard,
        proc(message: string) = errorSeen = message)
      drainPlatformCallbacks()
      check errorSeen == "native fetch transport is not attached"
