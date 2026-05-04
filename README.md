# nim-everywhere

`nim-everywhere` provides small platform seams for Nim libraries that target both native Nim and Nim JS from the same source.

It currently exposes:
- filesystem read/write/existence helpers with native implementations and browser-safe JS stubs
- deterministic clock injection
- HTTP request/response records with fake transport support
- JSON parse/stringify helpers
- immediate event-loop scheduling usable from native and JS tests

## Development

```sh
direnv exec /home/zahary/metacraft/nim-everywhere just test
direnv exec /home/zahary/metacraft/nim-everywhere just test-js
```
