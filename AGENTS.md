# nim-everywhere

Shared Nim platform seams for code that must compile on native and JavaScript backends.

Commands:
- `just build`: compile native and JS smoke targets.
- `just test`: run native and JS smoke tests.
- `just lint`: run Nim and Nix checks.
- `just format`: format Nim and Nix sources.

Structure:
- `src/nim_everywhere.nim`: public export surface.
- `src/nim_everywhere/platform.nim`: filesystem, time, HTTP, JSON, and event-loop seams.
- `tests/`: deterministic native/JS smoke tests.

Keep this repo independent from IsoNim Editor and CodeTracer modules. Public APIs should remain backend-neutral and deterministic in tests.
