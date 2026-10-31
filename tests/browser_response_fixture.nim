## Real-platform integration fixture. Tests call the trusted raw boundary and
## observe the original Response before any buffered HTTP projection.
import std/jsffi
import nim_everywhere/[http, async_compat]
proc start(url: cstring; init: JsObject): PlatformFuture[JsObject] =
  when defined(unqualifiedRawResponse):
    fetchBrowserResponseRaw(url, init)
  else:
    fetchBrowserResponseRaw(rawBackendAccess, url, init)
{.emit: "globalThis.startRawResponse = `start`;".}

when defined(rawResponseEffectCeiling):
  proc component() {.tags: [].} =
    discard fetchBrowserResponseRaw(rawBackendAccess, "/", JsObject{})
  component()
