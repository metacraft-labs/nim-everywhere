`http_projection_80d4.json` is an immutable outcome/Promise-turn capture from
`http.nim` at `80d4b7d9c683967ddbc8ee29c902881e358fbaa1` (source SHA256
`85b5785f56c0c18c7fa9b9acef2c8745407d0709e8b9aac513c835f3a37d8740`).
The real `http_projection_fixture.nim` facade was compiled before extraction,
using the stock Nim2.2.4 engine1553ba14/wrappere2abfcf3 and Node24.14.0.
`test_http_projection.mjs` compares exact outcomes, header order, body omission,
call/consumption/completion counts and numbered native microtask sentinels.
The captured fixture and compiler logs are retained in the implementation receipt.

Regeneration is deliberately separate from the ordinary test command. Capture
requires compiling that historical source with the same fixture; changing the
candidate implementation is never a reason to update the compatibility oracle.
