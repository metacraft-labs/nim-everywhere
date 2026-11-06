## Optional platform interception, independent of consumer frameworks.
## Raw facade functions let implementations delegate without recursion.
import ./[async_compat, platform]

type PlatformBackendHook* = ref object
  monotonicNowMs*: proc(): int64
  schedule*: proc(afterMs: int; cb: proc()): proc()
  fetch*: proc(request: HttpRequest): PlatformFuture[HttpResponse]

var currentBackendHook* {.threadvar.}: PlatformBackendHook

proc installBackendHook*(hook: PlatformBackendHook) =
  ## Install nil to restore platform defaults. FakeAsyncContext retains
  ## precedence for time operations so existing fake-time consumers work.
  currentBackendHook = hook
