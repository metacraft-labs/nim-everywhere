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


when defined(js):
  type HttpRequestPartsRaw* = object
    ## Fixed browser request conversion, prepared before Promise construction.
    url*: cstring
    methodName, body: cstring
    names, values: seq[cstring]

  proc prepareHttpRequestRaw*(access: RawBackendAccess;
      request: HttpRequest): HttpRequestPartsRaw {.tags: [RawNondet].} =
    ## Convert a buffered request without moving conversion errors into a Promise.
    result.url = request.url.cstring
    result.methodName = request.httpMethod.httpMethodName().cstring
    result.body = request.body.cstring
    for header in request.headers:
      result.names.add(header.name.cstring)
      result.values.add(header.value.cstring)

  proc buildHttpRequestInitRaw*(access: RawBackendAccess;
      parts: HttpRequestPartsRaw): JsObject {.tags: [RawNondet].} =
    ## Build inside the caller's Promise executor, retaining native assignment
    ## order, duplicate replacement and omission of an empty buffered body.
    let names = parts.names
    let values = parts.values
    let methodName = parts.methodName
    let body = parts.body
    {.emit: """
      var headers = {};
      for (var i = 0; i < `names`.length; i++) headers[`names`[i]] = `values`[i];
      `result` = { method: `methodName`, headers: headers };
      if (`body`.length > 0) `result`.body = `body`;
    """.}

  proc projectHttpResponseRaw*(access: RawBackendAccess;
      pending: PlatformFuture[JsObject];
      resolve: proc(response: HttpResponse)) {.tags: [RawNondet].} =
    ## Consume once and complete the existing buffered result. Returning no new
    ## Promise avoids adding a continuation between projection and completion.
    let finish = proc(status: int; text: cstring;
                      headerNames, headerValues: seq[cstring]) =
      var response = HttpResponse(status: status, body: $text)
      for i, name in headerNames:
        response.headers.add(HttpHeader(name: $name, value: $headerValues[i]))
      resolve(response)
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
      let parts = prepareHttpRequestRaw(access, request)
      result = newPromise proc(resolve: proc(response: HttpResponse)) =
        let init = buildHttpRequestInitRaw(access, parts)
        let pending = fetchBrowserResponseRaw(access, parts.url, init)
        projectHttpResponseRaw(access, pending, resolve)

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
