## Reprobuild project file for nim-everywhere.
##
## **Typed-Cross-Project-Deps rollout, Wave-0 leaf.** nim-everywhere is a
## pure-Nim leaf library — the cross-target platform seams (native +
## JavaScript backends: async facade, time facade, HTTP transport,
## filesystem/clock/event-loop seams) that IsoNim apps and other Metacraft
## Nim repos consume. It has NO in-scope sibling build dependency of its
## own, so the ``uses:`` block is just the toolchain floor and there is no
## ``uses: "<sibling>"`` edge.
##
## A Mode 1 / Mode 3 hybrid (per
## ``reprobuild-specs/Three-Mode-Convention-System.md``) modelled on the
## canonical ``runquota/repro.nim`` /
## ``codetracer-trace-format-nim/repro.nim`` /
## ``nim-stackable-hooks/repro.nim`` recipes:
##
## * Declares the upstream toolchain floor via ``uses:`` so consumers that
##   depend on this repo (via ``uses: "nim_everywhere"``) pick up the same
##   floor the nimble file's ``requires "nim >= 2.0.0"`` implies.
## * Declares ``library nim_everywhere`` so consumers can express a
##   workspace dependency on this repo. The importable surface is the
##   ``src/`` tree; consumers ``import nim_everywhere`` (the umbrella at
##   ``src/nim_everywhere.nim``) or the submodules under
##   ``src/nim_everywhere/`` directly.
## * Emits, per host-runnable test file under ``tests/``, a BUILD edge
##   (``buildNimUnittest.build``) that compiles ``build/test-bin/<stem>``
##   and an EXECUTE edge (``edge.testBinary.run``) that runs it — the
##   two-edge test template from ``reprobuild-specs/Package-Model.md``
##   §"The test template", exactly as reprobuild's own ``repro.nim`` does
##   it. The BUILD halves collect into ``test-builds`` and the EXECUTE
##   halves into ``test`` so ``repro build test`` / ``repro test``
##   materialise the runnable closure.
##
## **``--path:src``.** Unlike ``nim-stackable-hooks`` (whose ``config.nims``
## runs ``switch("path", "src")``), this repo's ``config.nims`` does NOT
## add ``src`` to the module path — the repo's Justfile passes
## ``--path:src`` explicitly on every ``nim c`` line. So every BUILD edge
## here passes ``paths = @["src"]`` to reproduce that flag; without it
## ``import nim_everywhere`` does not resolve. (config.nims only carries
## the dev-time ``-d:chronosClockHook`` fork override, which is off in the
## standard build.)
##
## **Per-test platform / backend gating.** Each test's edge mirrors the
## file's OWN gating so the corpus this host builds+runs matches what the
## repo's own ``nim c -r --path:src`` would run under the default backend:
##
##   * ``test_platform_smoke``, ``test_async_http``, ``test_async_backend``,
##     ``test_fake_time``, ``test_time_facade`` — import only
##     ``nim_everywhere`` and compile+run to exit 0 under the DEFAULT native
##     backend (``asyncBackend`` unset ⇒ ``asyncdispatch``). Their
##     backend-conditional bodies (``when asyncBackend in [...]`` /
##     ``when defined(js)``) all have live default-backend/native arms, so
##     they are always in the graph and always host-runnable. The repo's
##     ``just test`` runs exactly these five under the default backend
##     (``test-native`` + ``test-async-default`` + ``test-time-facade-default``),
##     plus a JS smoke pass and the asyncdispatch/none matrix — all of which
##     compile the SAME five files with extra ``-d:asyncBackend=...``. We
##     model the default-backend native pass (the umbrella ``nim c -r``
##     baseline); the ``-d:asyncBackend=`` matrix reruns are a follow-on
##     concern (they exercise the same edges with a define overlay).
##
##   * ``test_asyncdispatch_fake_clock`` and ``test_chronos_fake_clock`` are
##     DEV-ONLY clock-injection-hook tests. Each opens with a hard
##     ``{.fatal.}`` unless a special define is set —
##     ``-d:asyncdispatchClockHook`` / ``-d:chronosClockHook`` respectively —
##     AND each additionally requires a DEVELOPER-LOCAL compiler/library
##     fork redirect that is NOT part of the reprobuild build environment:
##     the asyncdispatch hook needs ``--lib:`` pointed at a local
##     ``codetracer-nim`` stdlib clone (which ``config.nims`` explicitly
##     documents CANNOT be set from config — the Justfile passes it on the
##     command line), and the chronos hook needs ``config.nims``'s
##     ``switch("path", "~/metacraft/nim-chronos")`` fork override, active
##     only under ``-d:chronosClockHook``. Both files' own docstrings state
##     the umbrella ``just test`` does NOT include them "because the path
##     points at a developer's local clone". They are therefore gated at
##     extraction on their opt-in define (``when defined(asyncdispatchClockHook)``
##     / ``when defined(chronosClockHook)``) — neither define is set in the
##     standard build, so both edges are simply absent from the graph here.
##     This mirrors the file's own gate: without the define the file is a
##     compile-time ``{.fatal.}``, so an ungated edge would fail to build,
##     and even with the define it is unbuildable without the local fork.
##
## **Tool provisioning.** ``defaultToolProvisioning "path"`` matches the
## canonical recipes: the nix dev shell puts ``nim`` + ``gcc`` on ``PATH``,
## so the weak-local PATH resolver is the right default. Without it
## ``repro build`` refuses to run with "typed tool provisioning is required
## for uses declarations".

import repro_project_dsl

# ``ct_test_nim_unittest`` supplies the ``buildNimUnittest.build(...)``
# typed-tool used by every test BUILD edge below, and the
# ``edge.testBinary.run(...)`` UFCS dispatch for the EXECUTE edges. It
# re-exports ``repro_project_dsl`` so the import order is unimportant.
#
# Note: like the other leaf recipes this file does NOT import
# ``ct_test_runner_install`` — that module is engine-coupled and lives at
# reprobuild's repo root, importable only from reprobuild's own project
# extraction. Without it the execute edges route through the engine's
# default direct-binary runner (run the binary, key on exit status), which
# is exactly the exit-0 verification this corpus needs; the Nim
# ``unittest`` harness prints per-suite results and exits non-zero on
# failure.
import ct_test_nim_unittest

type
  NimEverywhereTestSpec = object
    ## One entry per test file. ``source`` is the repo-relative ``.nim``
    ## path; ``binary`` is the ``build/test-bin/<stem>`` output.
    source: string
    binary: string

const portableTestSpecs: seq[NimEverywhereTestSpec] = @[
  # The five host-runnable tests: they import only ``nim_everywhere`` and
  # compile+run to exit 0 under the default native backend. Every
  # backend-conditional body inside them (``when asyncBackend in [...]``,
  # ``when defined(js)``) has a live default-backend/native arm.
  NimEverywhereTestSpec(source: "tests/test_platform_smoke.nim",
    binary: "build/test-bin/test_platform_smoke"),
  NimEverywhereTestSpec(source: "tests/test_async_http.nim",
    binary: "build/test-bin/test_async_http"),
  NimEverywhereTestSpec(source: "tests/test_async_backend.nim",
    binary: "build/test-bin/test_async_backend"),
  NimEverywhereTestSpec(source: "tests/test_fake_time.nim",
    binary: "build/test-bin/test_fake_time"),
  NimEverywhereTestSpec(source: "tests/test_time_facade.nim",
    binary: "build/test-bin/test_time_facade"),
]

const asyncdispatchHookTestSpecs: seq[NimEverywhereTestSpec] = @[
  # ``test_asyncdispatch_fake_clock`` opens with a ``{.fatal.}`` unless
  # ``-d:asyncdispatchClockHook`` (and ``asyncBackend`` in
  # ``["", "asyncdispatch"]``) is set, and additionally needs a ``--lib:``
  # redirect to a developer-local ``codetracer-nim`` stdlib fork. Gated on
  # the opt-in define; absent from the standard-build graph.
  NimEverywhereTestSpec(source: "tests/test_asyncdispatch_fake_clock.nim",
    binary: "build/test-bin/test_asyncdispatch_fake_clock"),
]

const chronosHookTestSpecs: seq[NimEverywhereTestSpec] = @[
  # ``test_chronos_fake_clock`` opens with a ``{.fatal.}`` unless
  # ``-d:chronosClockHook`` (and ``asyncBackend == "chronos"``) is set, and
  # additionally needs ``config.nims``'s local ``nim-chronos`` fork path
  # override. Gated on the opt-in define; absent from the standard-build
  # graph.
  NimEverywhereTestSpec(source: "tests/test_chronos_fake_clock.nim",
    binary: "build/test-bin/test_chronos_fake_clock"),
]

package nim_everywhere:
  defaultToolProvisioning "path"

  uses:
    # Toolchain floor — the PATH-resolvable binaries the build needs.
    # ``nim`` compiles every test binary (the ``buildNimUnittest.build``
    # edges below); ``gcc`` is the C back-end ``nim c`` shells out to.
    # Mirrors the nimble file's ``requires "nim >= 2.0.0"`` (the nix dev
    # shell furnishes a 2.2.x toolchain). Sufficient for the path-mode
    # resolver under ``nix develop``.
    "nim >=2.0 <3.0"
    "gcc >=12"

  # Library declaration — the ``src/`` tree is importable when this
  # package is consumed via ``uses: "nim_everywhere"``. The umbrella is
  # ``src/nim_everywhere.nim``; consumers may also import the submodules
  # under ``src/nim_everywhere/`` directly.
  library nim_everywhere

  build:
    # Two-edge test template (Package-Model.md §"The test template"): one
    # compile-only BUILD edge + one EXECUTE edge per host-runnable test
    # file. BUILD halves collect into ``test-builds``; EXECUTE halves
    # collect into ``test`` so ``repro test`` / ``repro build test``
    # materialise the runnable closure (each execute edge transitively
    # depends on its build edge). ``paths = @["src"]`` reproduces the
    # repo's ``--path:src`` (this repo's ``config.nims`` does NOT add it).
    var testBuildActions: seq[BuildActionDef] = @[]
    var testExecuteActions: seq[BuildActionDef] = @[]

    proc emitTestPair(source, binary: string;
                      buildActions, executeActions: var seq[BuildActionDef]) =
      var lastSlash = -1
      for i in 0 ..< binary.len:
        if binary[i] == '/' or binary[i] == '\\':
          lastSlash = i
      let stem =
        if lastSlash >= 0: binary[lastSlash + 1 .. ^1]
        else: binary
      let edge = buildNimUnittest.build(
        source = source,
        binary = binary,
        paths = @["src"],
        actionId = "nim_everywhere.test_build." & stem)
      buildActions.add(edge.action)
      # ``registerImplicitName = false`` because the BUILD edge already
      # owns the binary basename as the implicit target name; the explicit
      # ``actionId`` is the execute edge's selector (mirrors reprobuild's
      # ``repro.nim`` two-edge shape).
      let executeEdge = edge.testBinary.run(
        actionId = "nim_everywhere.test_execute." & stem,
        registerImplicitName = false)
      executeActions.add(executeEdge)

    # The five host-runnable tests — always in the graph.
    for spec in portableTestSpecs:
      emitTestPair(spec.source, spec.binary,
        testBuildActions, testExecuteActions)

    # Dev-only clock-injection-hook tests — gated at extraction on their
    # opt-in define so they never enter the graph in the standard build
    # (each is a compile-time ``{.fatal.}`` without its define, and even
    # with it needs a developer-local compiler/library fork redirect that
    # is not part of the reprobuild build environment).
    when defined(asyncdispatchClockHook):
      for spec in asyncdispatchHookTestSpecs:
        emitTestPair(spec.source, spec.binary,
          testBuildActions, testExecuteActions)

    when defined(chronosClockHook):
      for spec in chronosHookTestSpecs:
        emitTestPair(spec.source, spec.binary,
          testBuildActions, testExecuteActions)

    discard collect("test", testExecuteActions)
    discard collect("test-builds", testBuildActions)
