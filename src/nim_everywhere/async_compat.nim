## Cross-target async primitives for nim-everywhere.
##
## On JS, this module re-exports `std/asyncjs` (Promise) and provides
## helpers that play nicely with the browser microtask queue.
##
## On native, the backend is chosen at compile time via the wider
## Nim-ecosystem `-d:asyncBackend` convention (see
## `nim-faststreams/faststreams/async_backend.nim`):
##
##   -d:asyncBackend=asyncdispatch   # std/asyncdispatch (default)
##   -d:asyncBackend=chronos         # nim-chronos
##   -d:asyncBackend=none            # sync stubs (no event loop)
##
## When the flag is unset, native defaults to `asyncdispatch`. This
## deviates from faststreams (whose default is `none`) because the
## audience for nim-everywhere is consumed by IsoNim apps that always
## want async; the conservative default would only force every consumer
## to pass an extra `-d:` flag.
##
## The public surface — `PlatformFuture[T]`, `onComplete`,
## `onCompleteVoid`, `newCompletedFuture`, `newFailedFuture`,
## `drainPlatformCallbacks` — is stable across all backends.
##
## `sleepFor(ms)` returns a `PlatformFuture[void]` that completes after
## `ms` milliseconds. When a `FakeAsyncContext` (from `fake_time.nim`)
## is installed on the current thread, `sleepFor` detours through the
## fake context regardless of the underlying real backend. This is what
## lets fake-time tests run identically across the matrix.

import ./fake_time
export fake_time

const asyncBackend* {.strdefine.} = ""
  ## Public so consuming tests can branch on the active native backend.

when defined(js):
  import std/asyncjs
  export asyncjs

  type PlatformFuture*[T] = Future[T]

  var pendingCallbacks*: seq[proc()] = @[]

  proc drainCallbacks*() =
    while pendingCallbacks.len > 0:
      let callback = pendingCallbacks[0]
      pendingCallbacks.delete(0)
      callback()

  proc isSyncResolved*(future: PlatformFuture): bool =
    var resolved: bool
    {.emit: "`resolved` = (`future`.__syncResolved === true);".}
    resolved

  proc isSyncFailed*(future: PlatformFuture): bool =
    var failed: bool
    {.emit: "`failed` = (`future`.__syncFailed === true);".}
    failed

  proc getSyncValue*[T](future: PlatformFuture[T]): T =
    var value: T
    {.emit: "`value` = `future`.__syncValue;".}
    value

  proc getSyncError*(future: PlatformFuture): string =
    var message: string
    {.emit: "`message` = `future`.__syncError;".}
    message

else:
  when asyncBackend in ["", "asyncdispatch"]:
    import std/asyncdispatch
    export asyncdispatch
    type PlatformFuture*[T] = Future[T]

  elif asyncBackend == "chronos":
    import chronos
    export chronos
    type PlatformFuture*[T] = chronos.Future[T]

  elif asyncBackend == "none":
    # Sync-stub backend. There is no event loop driving completion —
    # futures are completed by the producer code at the call site.
    # Mirrors faststreams' `nginx` backend at
    # `faststreams/async_backend.nim` (the relevant section starts at the
    # `asyncBackend == "nginx"` branch).
    type
      FutureState* = enum
        fsPending, fsCompleted, fsFailed

      FutureBase* = ref object of RootObj
        state*: FutureState
        error*: ref CatchableError
        callbacks*: seq[proc() {.closure, gcsafe.}]

      Future*[T] = ref object of FutureBase
        value*: T

      PlatformFuture*[T] = Future[T]

    proc newFuture*[T](fromProc: static string = ""): Future[T] =
      Future[T](state: fsPending)

    proc complete*[T](future: Future[T]; val: T) =
      future.state = fsCompleted
      future.value = val
      for cb in future.callbacks:
        cb()
      future.callbacks.setLen(0)

    proc complete*(future: Future[void]) =
      future.state = fsCompleted
      for cb in future.callbacks:
        cb()
      future.callbacks.setLen(0)

    proc fail*(future: FutureBase; error: ref CatchableError) =
      future.state = fsFailed
      future.error = error
      for cb in future.callbacks:
        cb()
      future.callbacks.setLen(0)

    proc failed*(future: FutureBase): bool =
      future.state == fsFailed

    proc finished*(future: FutureBase): bool =
      future.state != fsPending

    proc addCallback*(future: FutureBase; cb: proc() {.closure, gcsafe.}) =
      if future.state != fsPending:
        cb()
      else:
        future.callbacks.add(cb)

    proc read*[T](future: Future[T]): T =
      if future.state == fsFailed:
        raise future.error
      elif future.state == fsPending:
        raise newException(ValueError, "Future is still pending")
      future.value

    proc read*(future: Future[void]) =
      if future.state == fsFailed:
        raise future.error
      elif future.state == fsPending:
        raise newException(ValueError, "Future is still pending")

    proc readError*(future: FutureBase): ref CatchableError =
      future.error

  else:
    {.fatal: "unrecognized -d:asyncBackend=" & asyncBackend &
             " (expected: asyncdispatch | chronos | none).".}

proc drainPlatformCallbacks*() =
  when defined(js):
    drainCallbacks()
  else:
    when asyncBackend in ["", "asyncdispatch"]:
      try:
        poll(0)
      except ValueError:
        discard
    elif asyncBackend == "chronos":
      try:
        poll()
      except CatchableError:
        discard
    elif asyncBackend == "none":
      discard

proc onComplete*[T](future: PlatformFuture[T]; onSuccess: proc(value: T);
                    onError: proc(message: string)) =
  when defined(js):
    if isSyncResolved(future):
      let value = getSyncValue[T](future)
      pendingCallbacks.add(proc() = onSuccess(value))
    elif isSyncFailed(future):
      let message = getSyncError(future)
      pendingCallbacks.add(proc() = onError(message))
    else:
      proc success(value: T) = onSuccess(value)
      proc failure(error: Error) = onError($error.message)
      discard future.then(success, failure)
  else:
    when asyncBackend == "chronos":
      # chronos's `addCallback` takes a `CallbackFunc = proc(arg: pointer)
      # {.gcsafe, raises: [].}`. We capture the producer's Nim callbacks
      # in a closure and wrap them in a raises-[] shim that re-acquires
      # the future state and dispatches. The captured callbacks are not
      # constrained to `raises: []`, so we cast to gcsafe and swallow any
      # propagating exceptions inside the trampoline. The bare `except
      # Exception` arms are deliberate (final safety net so the trampoline
      # never re-raises across the chronos boundary) and locally suppressed.
      let f = future
      {.push warning[BareExcept]: off.}
      proc trampoline(arg: pointer) {.gcsafe, raises: [].} =
        {.cast(gcsafe).}:
          try:
            if f.failed:
              onError(f.readError.msg)
            else:
              onSuccess(f.read)
          except CatchableError as exc:
            try: onError(exc.msg)
            except CatchableError: discard
            except Exception: discard
          except Exception as exc:
            try: onError(exc.msg)
            except CatchableError: discard
            except Exception: discard
      {.pop.}
      f.addCallback(trampoline, cast[pointer](f))
    else:
      future.addCallback proc() =
        {.cast(gcsafe).}:
          if future.failed:
            onError(future.readError.msg)
          else:
            onSuccess(future.read)

proc onCompleteVoid*(future: PlatformFuture[void]; onSuccess: proc();
                     onError: proc(message: string)) =
  when defined(js):
    if isSyncResolved(future):
      pendingCallbacks.add(proc() = onSuccess())
    elif isSyncFailed(future):
      let message = getSyncError(future)
      pendingCallbacks.add(proc() = onError(message))
    else:
      proc success() = onSuccess()
      proc failure(error: Error) = onError($error.message)
      discard future.then(success, failure)
  else:
    when asyncBackend == "chronos":
      let f = future
      {.push warning[BareExcept]: off.}
      proc trampoline(arg: pointer) {.gcsafe, raises: [].} =
        {.cast(gcsafe).}:
          try:
            if f.failed:
              onError(f.readError.msg)
            else:
              onSuccess()
          except CatchableError as exc:
            try: onError(exc.msg)
            except CatchableError: discard
            except Exception: discard
          except Exception as exc:
            try: onError(exc.msg)
            except CatchableError: discard
            except Exception: discard
      {.pop.}
      f.addCallback(trampoline, cast[pointer](f))
    else:
      future.addCallback proc() =
        {.cast(gcsafe).}:
          if future.failed:
            onError(future.readError.msg)
          else:
            onSuccess()

proc onComplete*(future: PlatformFuture[void]; onSuccess: proc();
                 onError: proc(message: string)) =
  ## Convenience overload for `Future[void]` so callers can write
  ## `fut.onComplete(proc() = ..., proc(m: string) = ...)` symmetrically
  ## with the typed `onComplete[T]` form.
  onCompleteVoid(future, onSuccess, onError)

proc newCompletedFuture*[T](value: T): PlatformFuture[T] =
  when defined(js):
    result = newPromise proc(resolve: proc(value: T)) =
      resolve(value)
    {.emit: "`result`.__syncResolved = true; `result`.__syncValue = `value`;".}
  else:
    result = newFuture[T]("nim-everywhere completed future")
    result.complete(value)

proc newFailedFuture*[T](message: string): PlatformFuture[T] =
  when defined(js):
    result = newPromise proc(resolve: proc(value: T)) =
      raise newException(CatchableError, message)
    {.emit: "`result`.__syncFailed = true; `result`.__syncError = `message`; `result`.catch(function(){});".}
  else:
    result = newFuture[T]("nim-everywhere failed future")
    result.fail(newException(CatchableError, message))

proc sleepFor*(ms: int): PlatformFuture[void] =
  ## Cross-backend sleep primitive.
  ##
  ## If a `FakeAsyncContext` is installed on the current thread, the
  ## returned future completes when the fake context fires the
  ## scheduled callback (i.e. when test code calls `advance(ms)` +
  ## `runPending()`). The real backend's sleep primitive is bypassed
  ## entirely — this is what makes fake-time tests work uniformly
  ## across the matrix.
  ##
  ## When no fake context is installed, `sleepFor` falls through to:
  ##   - JS: `setTimeout(ms)`-backed Promise
  ##   - asyncdispatch: `std/asyncdispatch.sleepAsync(ms)`
  ##   - chronos: `chronos.sleepAsync(ms.milliseconds)`
  ##   - none: raises a Defect (no event loop, no fake context →
  ##           there is nothing that could wake the sleep)
  let fake = currentFakeContext()
  if fake != nil:
    when defined(js):
      # Build a Promise<void> that completes when the fake context fires
      # the scheduled callback. asyncjs's `newPromise` for `Future[void]`
      # takes a `proc(resolve: proc())` resolver.
      var resolveFn: proc()
      result = newPromise proc(resolve: proc()) =
        resolveFn = resolve
      fake.schedule(ms, proc() = resolveFn())
    else:
      let fut = newFuture[void]("nim-everywhere sleepFor (fake-time)")
      fake.schedule(ms, proc() = fut.complete())
      result = fut
    return

  when defined(js):
    let msArg = ms
    result = newPromise proc(resolve: proc()) =
      {.emit: "setTimeout(function() { `resolve`(); }, `msArg`);".}
  else:
    when asyncBackend in ["", "asyncdispatch"]:
      result = sleepAsync(ms)
    elif asyncBackend == "chronos":
      result = chronos.sleepAsync(chronos.milliseconds(ms))
    elif asyncBackend == "none":
      raise newException(Defect,
        "sleepFor without an installed FakeAsyncContext requires an event loop; " &
        "build with -d:asyncBackend=asyncdispatch|chronos, or install a " &
        "FakeAsyncContext for deterministic tests")
