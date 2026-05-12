when defined(js):
  import std/asyncjs
  export asyncjs
else:
  import std/asyncdispatch
  export asyncdispatch

type PlatformFuture*[T] = Future[T]

when defined(js):
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

proc drainPlatformCallbacks*() =
  when defined(js):
    drainCallbacks()
  else:
    try:
      poll(0)
    except ValueError:
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
    future.addCallback proc() =
      {.cast(gcsafe).}:
        if future.failed:
          onError(future.readError.msg)
        else:
          onSuccess()

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
