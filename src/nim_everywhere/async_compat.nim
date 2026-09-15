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
## `sleepFor` and the rest of the time-related facade
## (`monotonicNowMs`, `withTimeout`, `scheduleAt`, `scheduleEvery`,
## `cancelTimer`) live in `nim_everywhere/time.nim`. NE-Time-M0 split
## `sleepFor` out so consumers that only need the bare future surface
## don't have to pull in the timer machinery. The umbrella module
## `nim_everywhere.nim` re-exports both, so `import nim_everywhere`
## continues to work for every existing caller.

import ./fake_time
export fake_time

const asyncBackend* {.strdefine.} = ""
  ## Public so consuming tests can branch on the active native backend.

const platformIsWasm* = defined(wasm32) or defined(emscripten) or defined(wasi)
  ## True on a **linear-memory** target: `nim c --cpu:wasm32` (which defines
  ## `wasm32` on its own), and the two explicit spellings a toolchain adds
  ## (`-d:emscripten`, `-d:wasi`).
  ##
  ## WHY THIS EXISTS AS A THIRD AXIS. `defined(js)` and "native" were the
  ## whole of this module's world, and a WASM build is neither: it takes the
  ## C code path — so `defined(js)` is false and every `else` branch below
  ## applies — while having none of a native host's event loop. The one
  ## primitive where that distinction is load-bearing is
  ## `drainPlatformCallbacks`; see its WASM arm for what changes and what
  ## deliberately does not.
  ##
  ## Public so a consuming test can assert which arm it is grading. A timing
  ## or a dispatcher claim that does not name its target is the §12b trap in
  ## codetracer-specs/Testing/Verification-Harness-Traps.md.

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

    when platformIsWasm:
      # ---------------------------------------------------------------
      # THE WASM ARM OF THE DISPATCHER PUMP.
      # ---------------------------------------------------------------
      #
      # `std/asyncdispatch` is kept as the future implementation on this
      # target, deliberately, and the reason is not convenience: Nim's
      # `{.async.}` / `await` / `waitFor` are `std/asyncmacro` over
      # `asyncdispatch`'s own `Future`, so a bespoke future type here would
      # not be a third arm of one facade — it would be a different language
      # feature for WASM callers, and every suite that writes `await` would
      # have to be rewritten or dropped. Dropping suites is precisely the
      # failure this milestone's gate is about.
      #
      # What DOES have to change is the pump. The native branch below is
      # `poll(0)`, and `poll` is `runOnce(0)`, and `runOnce`'s middle step is
      #
      #     p.selector.selectInto(adjustTimeout(p, timeout, nextTimer), keys)
      #
      # — an `epoll_wait` on the dispatcher's selector. A browser has no
      # pollable descriptor and no `epoll`; there is nothing for a selector
      # to be ready about, and the two things that reach it are both wrong
      # here rather than merely useless:
      #
      #   * `adjustTimeout` returns a NON-ZERO timeout whenever the callback
      #     queue is empty and a timer is pending, so the "drain whatever is
      #     ready" helper becomes a WAIT — on the one thread a browser tab
      #     has. The same shape is already documented for chronos a few
      #     lines down; this is it on the other backend.
      #   * `runOnce` RAISES `ValueError` when the dispatcher is completely
      #     empty, which the native branch swallows. A pump whose empty case
      #     is an exception the caller discards is a pump that cannot tell
      #     "nothing to do" from "the dispatcher is gone".
      #
      # Measured rather than assumed, on emscripten 4.0.12 under node: the
      # native branch DOES work on this target — emscripten emulates epoll —
      # and it gets there by way of `__syscall_prlimit64`, which emscripten
      # answers with `warning: unsupported syscall` on stderr. Working by
      # emulation of a facility the shipping host has not got is exactly the
      # kind of accident this arm exists to stop depending on.
      #
      # So the arm is `runOnce` MINUS `selectInto`, and nothing else: the
      # same two steps in the same order, over the same public fields of
      # `PDispatcherBase`.
      #
      # THE BOUND, stated so it is not read as more than it is. This removes
      # the selector WAIT, not the selector. `getGlobalDispatcher()` still
      # constructs one on first use, which is where the `prlimit64` warning
      # above actually comes from, and a WASM build therefore still links
      # `std/selectors` and `std/nativesockets`. Removing that too means not
      # using `asyncdispatch` at all — which costs `{.async.}` and `await`,
      # for the reason in the first paragraph. What this arm guarantees is
      # that **no drain ever blocks**, which is the property a browser's one
      # thread needs; shrinking the link closure is a separate decision and
      # belongs with PLAT-18's artifact-size measurement.
      import std/[deques, heapqueue, monotimes]

      proc drainWasmDispatcher*() =
        ## Run every timer that is DUE and every callback the dispatcher has
        ## queued, without entering the selector.
        ##
        ## `getGlobalDispatcher()` is called for its side effect as well as
        ## its value: it is what installs `asyncfutures.callSoonProc`. Until
        ## something does, `callSoon` runs its argument INLINE ("Loop not
        ## initialized yet"), so a future completed before the first drain
        ## delivers its callback immediately and one completed after it does
        ## not. `poll(0)` initialises the dispatcher the same way, so this
        ## arm inherits that behaviour rather than inventing a second one.
        let p = getGlobalDispatcher()

        # 1. Due timers, smallest `finishAt` first — `processTimers`'s loop.
        #    What is NOT here is `adjustTimeout`: a timer that is not due yet
        #    stays on the heap and this call returns, where the native branch
        #    would hand its delay to the selector and sleep.
        let now = getMonoTime()
        while p.timers.len > 0 and now >= p.timers[0].finishAt:
          p.timers.pop().fut.complete()

        # 2. The `callSoon` queue, cascades included —
        #    `processPendingCallbacks`'s loop. Re-reading `.len` each turn is
        #    what makes a callback that queues another callback settle inside
        #    ONE drain, which is the contract every caller of
        #    `drainPlatformCallbacks` in this workspace already relies on.
        while p.callbacks.len > 0:
          let cb = p.callbacks.popFirst()
          cb()

  elif asyncBackend == "chronos":
    import chronos
    import std/heapqueue as stdHeapqueue
    export chronos
    type PlatformFuture*[T] = chronos.Future[T]

    proc chronosHasTimers(): bool {.inline.} =
      ## Workaround: `disp.timers.len` is ambiguous between
      ## `std/heapqueue.len` and chronos's `AsyncQueue.len` at the
      ## call site. Resolve explicitly via `std/heapqueue` and
      ## return a bool so callers don't need to know the type.
      let timers = getThreadDispatcher().timers
      stdHeapqueue.len(timers) > 0

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
      when platformIsWasm:
        # The WASM arm. `poll(0)` has no meaning on a linear-memory target;
        # see `drainWasmDispatcher` above for what replaces it and why.
        drainWasmDispatcher()
      else:
        try:
          poll(0)
        except ValueError:
          discard
    elif asyncBackend == "chronos":
      # chronos's `poll()` blocks on `selectInto` when its callback
      # queue holds only the sentinel and no timers / idlers are
      # registered. That's the wrong shape for a "drain whatever is
      # ready" helper, so skip the poll if there's nothing for us to
      # flush. The dispatcher's deque always holds a sentinel between
      # polls, so we treat any queue of size > 1 as "has real work".
      # (We can't check sentinel identity from outside chronos, but a
      # length-1 queue can only contain the sentinel — chronos always
      # adds new callbacks via `addLast`, after the sentinel.)
      try:
        # Skip the poll entirely when chronos has nothing to drain. A
        # `poll()` with empty callbacks AND no pending timers blocks on
        # `selectInto` waiting for the next timer, which is the wrong
        # shape for a "drain whatever is ready" helper. The dispatcher's
        # deque always holds a sentinel between polls, so we treat any
        # callback length > 1 as "real callback work pending". Timer
        # work is handled separately via `chronosHasTimers()`.
        if getThreadDispatcher().callbacks.len > 1 or chronosHasTimers():
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

proc newCompletedFuture*(): PlatformFuture[void] =
  when defined(js):
    result = newPromise proc(resolve: proc()) =
      resolve()
    {.emit: "`result`.__syncResolved = true; `result`.__syncValue = undefined;".}
  else:
    result = newFuture[void]("nim-everywhere completed void future")
    result.complete()

proc newFailedFuture*[T](message: string): PlatformFuture[T] =
  when defined(js):
    result = newPromise proc(resolve: proc(value: T)) =
      raise newException(CatchableError, message)
    {.emit: "`result`.__syncFailed = true; `result`.__syncError = `message`; `result`.catch(function(){});".}
  else:
    result = newFuture[T]("nim-everywhere failed future")
    result.fail(newException(CatchableError, message))

# Note: `sleepFor` was moved to `nim_everywhere/time.nim` as part of
# NE-Time-M0. The umbrella module re-exports `time.nim` so any caller
# that does `import nim_everywhere` keeps seeing `sleepFor` unchanged.
# Direct importers of `nim_everywhere/async_compat` that need `sleepFor`
# should add `import nim_everywhere/time`.
