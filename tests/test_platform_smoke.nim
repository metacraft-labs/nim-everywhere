import std/json
import unittest
import nim_everywhere

suite "nim_everywhere_native_and_js_platform_smoke":
  test "capabilities report target and deterministic seams":
    let caps = platformCapabilities()
    check caps.realClock
    check caps.queuedEventLoop
    check caps.deterministicFakes
    when defined(js):
      check caps.backend == pbJs
      check not caps.filesystemRead
    else:
      check caps.backend == pbNative
      check caps.filesystemRead

  test "json, http, clock, and event loop seams":
    let clock = fixedClock(1234)
    check clock.nowUnixMillis() == 1234
    let node = parseJsonText("""{"ok":true,"n":3}""")
    check node["ok"].getBool()
    check toJsonText(node).len > 0

    let fake = newFakeHttp(@[
      HttpResponse(status: 200, body: """{"answer":42}""")
    ])
    let transport = fake.transport()
    let response = transport.request(newRequest(hmPost, "/echo", """{"x":1}"""))
    check response.status == 200
    check parseJsonText(response.body)["answer"].getInt() == 42
    check fake.requests.len == 1
    check fake.requests[0].body == """{"x":1}"""

    var fired = false
    let loop = queuedEventLoop()
    loop.scheduleSoon(proc() = fired = true)
    check not fired
    loop.runOnce()
    check fired

  test "filesystem seam compiles on native and JS":
    let mem = memoryFileSystem([("config.json", """{"enabled":true}""")])
    check mem.exists("config.json")
    check parseJsonText(mem.readText("config.json"))["enabled"].getBool()
    mem.writeText("out.txt", "done")
    check mem.readText("out.txt") == "done"

    let fs = nativeFileSystem()
    when defined(js):
      expect PlatformError:
        discard fs.readText("not-used-in-js")
    else:
      check fs.exists(".")
