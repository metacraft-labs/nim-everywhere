# nim-everywhere

`nim-everywhere` provides small platform seams for Nim libraries that target both native Nim and Nim JS from the same source.

It currently exposes:
- `NativeString`, native collection aliases, and conversion helpers for code
  that should avoid backend-specific string/container choices
- async compatibility helpers for callback-based code that targets both
  native Nim and Nim JS
- filesystem read/write/existence helpers with native implementations and browser-safe JS stubs
- deterministic clock injection
- HTTP request/response records with sync and async fake transport support
- a browser `fetch` wrapper exposed as an async transport, with native kept
  pluggable for host-specific HTTP clients
- JSON parse/stringify helpers
- immediate event-loop scheduling usable from native and JS tests

## Development

```sh
direnv exec /home/zahary/metacraft/nim-everywhere just test
direnv exec /home/zahary/metacraft/nim-everywhere just test-js
```
