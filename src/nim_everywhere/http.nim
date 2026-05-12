import nim_everywhere/[async_compat, platform]

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

proc fetchHttp*(request: HttpRequest): PlatformFuture[HttpResponse] =
  when defined(js):
    let url = request.url.cstring
    let methodName = request.httpMethod.httpMethodName().cstring
    let body = request.body.cstring
    result = newPromise proc(resolve: proc(response: HttpResponse)) =
      {.emit: """
        var headers = {};
        for (var i = 0; i < `request`.headers.length; i++) {
          var header = `request`.headers[i];
          headers[header.name] = header.value;
        }
        var init = { method: `methodName`, headers: headers };
        if (`body`.length > 0) init.body = `body`;
        fetch(`url`, init)
          .then(function(resp) {
            return resp.text().then(function(text) {
              `resolve`({status: resp.status, headers: [], body: text});
            });
          })
          .catch(function(error) {
            `resolve`({status: 599, headers: [], body: String(error && error.message || error)});
          });
      """.}
  else:
    newFailedFuture[HttpResponse]("native fetch transport is not attached")

proc fetchHttpTransport*(): HttpAsyncTransport =
  proc(request: HttpRequest): PlatformFuture[HttpResponse] =
    fetchHttp(request)
