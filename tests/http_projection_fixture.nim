## Compiles the real facade and (candidate builds only) its extracted composition.
## JS harness supplies genuine native Promises/Responses; narrow synchronous
## throw injection probes the Promise-executor rejection boundary, not transport.
import std/jsffi
import nim_everywhere/[http, platform, async_compat]
proc request(url: cstring; body: cstring): PlatformFuture[HttpResponse] =
  fetchHttpRaw(rawBackendAccess, HttpRequest(url: $url, httpMethod: hmPost,
    body: $body, headers: @[HttpHeader(name: "x-z", value: "first"),
      HttpHeader(name: "x-a", value: "middle"),
      HttpHeader(name: "x-z", value: "last")]))
{.emit: "globalThis.httpFacade = `request`;".}
when defined(extractedHttpComposition):
  proc composition(url: cstring; body: cstring): PlatformFuture[HttpResponse] =
    let parts = prepareHttpRequestRaw(rawBackendAccess,
      HttpRequest(url: $url, httpMethod: hmPost, body: $body,
        headers: @[HttpHeader(name: "x-z", value: "first"),
          HttpHeader(name: "x-a", value: "middle"),
          HttpHeader(name: "x-z", value: "last")]))
    newPromise proc(resolve: proc(response: HttpResponse)) =
      let init = buildHttpRequestInitRaw(rawBackendAccess, parts)
      let pending = fetchBrowserResponseRaw(rawBackendAccess, parts.url, init)
      projectHttpResponseRaw(rawBackendAccess, pending, resolve)
  {.emit: "globalThis.httpComposition = `composition`;".}
when defined(rawPrepareEffectCeiling):
  proc component() {.tags: [].} =
    discard prepareHttpRequestRaw(rawBackendAccess, HttpRequest())
  component()
when defined(rawInitEffectCeiling):
  let parts = prepareHttpRequestRaw(rawBackendAccess, HttpRequest())
  proc component() {.tags: [].} =
    discard buildHttpRequestInitRaw(rawBackendAccess, parts)
  component()
when defined(rawProjectEffectCeiling):
  proc component() {.tags: [].} =
    projectHttpResponseRaw(rawBackendAccess, PlatformFuture[JsObject](nil),
      proc(response: HttpResponse) = discard)
  component()
proc requestRaw(input: HttpRequest): PlatformFuture[HttpResponse] =
  fetchHttpRaw(rawBackendAccess, input)
{.emit: "globalThis.httpRawRequest = `requestRaw`;".}
when defined(extractedHttpComposition):
  proc trustedProjection() {.tags: [RawNondet].} =
    let parts = prepareHttpRequestRaw(rawBackendAccess, HttpRequest())
    let init = buildHttpRequestInitRaw(rawBackendAccess, parts)
    let pending = fetchBrowserResponseRaw(rawBackendAccess, parts.url, init)
    projectHttpResponseRaw(rawBackendAccess, pending,
      proc(response: HttpResponse) = discard)
