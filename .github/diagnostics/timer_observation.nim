## Diagnostic only: genuine native 30 ms timer; no mocks or qualification claim.
## Preserve original callback and 25/500 ms bounds. Record paired observers
## before/after arming to distinguish registration cost from clock differences.
import std/[times, monotimes, json, compilesettings, os]
import nim_everywhere
const compilerAtBuild = getCurrentCompilerExe()
const libraryAtBuild = querySetting(SingleValueSetting.libPath)
var fired = false
var callbackWall = 0.0
var callbackMono = 0'i64
let beforeWall = epochTime()
let beforeMono = getMonoTime().ticks
discard scheduleAt(30, proc() =
  fired = true
  callbackWall = epochTime()
  callbackMono = getMonoTime().ticks)
let afterWall = epochTime()
let afterMono = getMonoTime().ticks
let started = epochTime()
while not fired and (epochTime() - started) < 0.500:
  drainPlatformCallbacks()
let finishedWall = epochTime()
let finishedMono = getMonoTime().ticks
let elapsed = finishedWall - started
echo $(%* {"diagnosticOnly": true, "backend": asyncBackend,
  "compilerAtBuild": compilerAtBuild, "libraryAtBuild": libraryAtBuild,
  "beforeWall": beforeWall, "beforeMonoNs": beforeMono,
  "afterWall": afterWall, "afterMonoNs": afterMono,
  "startedWall": started, "callbackWall": callbackWall,
  "callbackMonoNs": callbackMono, "finishedWall": finishedWall,
  "finishedMonoNs": finishedMono, "fired": fired,
  "originalElapsed": elapsed, "originalLowerBound": 0.025,
  "originalUpperBound": 0.500})
doAssert fired
doAssert elapsed >= 0.025
doAssert elapsed < 0.500
