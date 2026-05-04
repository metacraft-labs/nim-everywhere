import std/json
import std/tables
import std/times

when not defined(js):
  import std/os

type
  PlatformError* = object of CatchableError

  PlatformBackend* = enum
    pbNative = "native"
    pbJs = "js"

  PlatformCapabilities* = object
    backend*: PlatformBackend
    filesystemRead*: bool
    filesystemWrite*: bool
    realClock*: bool
    realHttp*: bool
    queuedEventLoop*: bool
    deterministicFakes*: bool

  FileSystemKind* = enum
    fskNative
    fskMemory

  FileSystem* = ref object
    kind*: FileSystemKind
    files*: Table[string, string]

  Clock* = object
    fixedUnixMillis*: int64

  HttpMethod* = enum
    hmGet = "GET"
    hmPost = "POST"
    hmPut = "PUT"
    hmDelete = "DELETE"
  HttpHeader* = object
    name*: string
    value*: string
  HttpRequest* = object
    httpMethod*: HttpMethod
    url*: string
    headers*: seq[HttpHeader]
    body*: string
  HttpResponse* = object
    status*: int
    headers*: seq[HttpHeader]
    body*: string
  HttpTransport* = proc(request: HttpRequest): HttpResponse {.closure.}

  FakeHttp* = ref object
    responses*: seq[HttpResponse]
    requests*: seq[HttpRequest]
    index*: int

  EventLoopKind* = enum
    elkImmediate
    elkQueued

  EventLoop* = ref object
    kind*: EventLoopKind
    queue*: seq[ScheduledCallback]

  ScheduledCallback* = proc() {.closure.}

proc platformCapabilities*(): PlatformCapabilities =
  when defined(js):
    PlatformCapabilities(
      backend: pbJs,
      filesystemRead: false,
      filesystemWrite: false,
      realClock: true,
      realHttp: false,
      queuedEventLoop: true,
      deterministicFakes: true)
  else:
    PlatformCapabilities(
      backend: pbNative,
      filesystemRead: true,
      filesystemWrite: true,
      realClock: true,
      realHttp: false,
      queuedEventLoop: true,
      deterministicFakes: true)

proc nativeFileSystem*(): FileSystem =
  FileSystem(kind: fskNative)

proc memoryFileSystem*(initial: openArray[(string, string)] = []): FileSystem =
  result = FileSystem(kind: fskMemory)
  for (path, content) in initial:
    result.files[path] = content

proc readText*(fs: FileSystem; path: string): string =
  case fs.kind
  of fskMemory:
    if not fs.files.hasKey(path):
      raise newException(PlatformError, "memory file not found: " & path)
    fs.files[path]
  of fskNative:
    when defined(js):
      raise newException(PlatformError, "native filesystem reads are not available on JS")
    else:
      readFile(path)

proc writeText*(fs: FileSystem; path, content: string) =
  case fs.kind
  of fskMemory:
    fs.files[path] = content
  of fskNative:
    when defined(js):
      raise newException(PlatformError, "native filesystem writes are not available on JS")
    else:
      writeFile(path, content)

proc exists*(fs: FileSystem; path: string): bool =
  case fs.kind
  of fskMemory:
    fs.files.hasKey(path)
  of fskNative:
    when defined(js):
      false
    else:
      fileExists(path) or dirExists(path)

proc systemClock*(): Clock =
  Clock(fixedUnixMillis: 0)

proc fixedClock*(unixMillis: int64): Clock =
  Clock(fixedUnixMillis: unixMillis)

proc nowUnixMillis*(clock: Clock): int64 =
  if clock.fixedUnixMillis != 0:
    clock.fixedUnixMillis
  else:
    (getTime().toUnixFloat() * 1000).int64

proc parseJsonText*(text: string): JsonNode =
  parseJson(text)

proc toJsonText*(node: JsonNode): string =
  $node

proc header*(name, value: string): HttpHeader =
  HttpHeader(name: name, value: value)

proc newRequest*(httpMethod: HttpMethod; url: string; body = "";
    headers: seq[HttpHeader] = @[]): HttpRequest =
  HttpRequest(httpMethod: httpMethod, url: url, headers: headers, body: body)

proc newFakeHttp*(responses: seq[HttpResponse]): FakeHttp =
  FakeHttp(responses: responses)

proc transport*(fake: FakeHttp): HttpTransport =
  proc(request: HttpRequest): HttpResponse =
    fake.requests.add request
    if fake.index >= fake.responses.len:
      return HttpResponse(status: 599, body: "no fake response scripted")
    result = fake.responses[fake.index]
    inc fake.index

proc fakeHttpTransport*(responses: seq[HttpResponse]): HttpTransport =
  newFakeHttp(responses).transport()

proc request*(transport: HttpTransport; req: HttpRequest): HttpResponse =
  transport(req)

proc scheduleSoon*(loop: EventLoop; callback: ScheduledCallback) =
  case loop.kind
  of elkImmediate:
    callback()
  of elkQueued:
    loop.queue.add callback

proc runOnce*(loop: EventLoop) =
  if loop.queue.len == 0:
    return
  let callback = loop.queue[0]
  loop.queue.delete(0)
  callback()

proc runAll*(loop: EventLoop) =
  while loop.queue.len > 0:
    loop.runOnce()

proc immediateEventLoop*(): EventLoop =
  EventLoop(kind: elkImmediate)

proc queuedEventLoop*(): EventLoop =
  EventLoop(kind: elkQueued)
