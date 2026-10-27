import ./raw_nondet
export raw_nondet

import nim_everywhere/[async_compat, platform, backend]
when defined(js):
  import std/jsffi

  proc browserFetch(url: cstring; init: JsObject): PlatformFuture[JsObject]
      {.importjs: "fetch(#, #)", tags: [RawNondet].}

  proc fetchBrowserResponseRaw*(access: RawBackendAccess; url: cstring;
      init: JsObject): PlatformFuture[JsObject] {.tags: [RawNondet].} =
    ## Browser backend primitive: return the original fetch Promise/Response,
    ## before any buffered facade reads its body or projects its metadata.
    ## No observer, extra read, continuation or rejection conversion is added.
    browserFetch(url, init)

  when defined(isonimStrictNondet):
    proc fetchBrowserResponseRaw*(url: cstring; init: JsObject): PlatformFuture[JsObject]
        {.error: "isonimStrictNondet: raw platform binding fetchBrowserResponseRaw; use the nondeterminism seam".}
  else:
    proc fetchBrowserResponseRaw*(url: cstring; init: JsObject): PlatformFuture[JsObject]
        {.tags: [RawNondet].} =
      fetchBrowserResponseRaw(rawBackendAccess, url, init)

type HttpAsyncTransport* = proc(request: HttpRequest): PlatformFuture[HttpResponse] {.closure.}

proc response*(status: int; body = ""; headers: seq[HttpHeader] = @[]): HttpResponse =
  HttpResponse(status: status, headers: headers, body: body)

proc requestAsync*(transport: HttpAsyncTransport;
                   request: HttpRequest): PlatformFuture[HttpResponse] =
  transport(request)

proc asyncTransport*(fake: FakeHttp): HttpAsyncTransport =
  proc(request: HttpRequest): PlatformFuture[HttpResponse] =
    newCompletedFuture(fake.transport().request(request))

proc fakeHttpAsyncTransport*(responses: seq[HttpResponse]): HttpAsyncTransport =
  newFakeHttp(responses).asyncTransport()

proc fetchHttpRaw*(access: RawBackendAccess; request: HttpRequest): PlatformFuture[HttpResponse] {.tags: [RawNondet].} =
  {.cast(tags: []).}:

    when defined(js):
      let url = request.url.cstring
      let methodName = request.httpMethod.httpMethodName().cstring
      let body = request.body.cstring
      var names, values: seq[cstring]
      for header in request.headers:
        names.add(header.name.cstring)
        values.add(header.value.cstring)
      result = newPromise proc(resolve: proc(response: HttpResponse)) =
        let finish = proc(status: int; text: cstring;
                          headerNames, headerValues: seq[cstring]) =
          var response = HttpResponse(status: status, body: $text)
          for i, name in headerNames:
            response.headers.add(HttpHeader(name: $name, value: $headerValues[i]))
          resolve(response)
        var init: JsObject
        {.emit: """
          var headers = {};
          for (var i = 0; i < `names`.length; i++) headers[`names`[i]] = `values`[i];
          `init` = { method: `methodName`, headers: headers };
          if (`body`.length > 0) `init`.body = `body`;
        """.}
        let pending = fetchBrowserResponseRaw(access, url, init)
        {.emit: """
          `pending`.then(function(resp) {
            return resp.text().then(function(text) {
              var hn = [], hv = [];
              resp.headers.forEach(function(v,k) { hn.push(k); hv.push(v); });
              `finish`(resp.status, text, hn, hv);
            });
          }).catch(function(error) {
            `finish`(599, String(error && error.message || error), [], []);
          });
        """.}

    else:
      newFailedFuture[HttpResponse]("native fetch transport is not attached")

when defined(isonimStrictNondet):
  proc fetchHttpRaw*(request: HttpRequest): PlatformFuture[HttpResponse] {.error: "isonimStrictNondet: raw platform binding fetchHttpRaw; use the nondeterminism seam".}
else:
  proc fetchHttpRaw*(request: HttpRequest): PlatformFuture[HttpResponse] {.tags: [RawNondet].} =
    fetchHttpRaw(rawBackendAccess, request)

proc fetchHttp*(request: HttpRequest): PlatformFuture[HttpResponse] =
  if currentBackendHook != nil and currentBackendHook.fetch != nil:
    return currentBackendHook.fetch(request)
  fetchHttpRaw(rawBackendAccess, request)

proc fetchHttpTransport*(): HttpAsyncTransport =
  proc(request: HttpRequest): PlatformFuture[HttpResponse] =
    fetchHttp(request)
