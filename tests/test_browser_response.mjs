// All responses/streams/errors are real Node fetch against local HTTP. The
// Proxy only witnesses the native call's arguments and identical returned
// Promise; it forwards unchanged and never substitutes a transport/result.
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import vm from "node:vm";
import assert from "node:assert/strict";
vm.runInThisContext(
  await readFile(
    process.env.RAW_RESPONSE_FIXTURE ?? "tests/browser_response_fixture.js",
    "utf8",
  ),
);
const slots = new Map(),
  requests = [];
const server = createServer((req, res) => {
  const u = new URL(req.url, "http://localhost");
  requests.push(u.pathname);
  if (u.pathname === "/redirect") {
    res.writeHead(302, { Location: "/stream" });
    res.end();
  } else if (u.pathname === "/fail") {
    req.socket.destroy();
  } else if (u.pathname === "/binary") {
    res.end(Buffer.from([0, 255, 195, 169]));
  } else {
    slots.set(u.pathname, res);
    res.writeHead(207, "Raw Head", {
      "Content-Type": "text/plain",
      "X-Raw": "metadata",
    });
    res.flushHeaders();
    res.write("first-");
  }
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const base = "http://127.0.0.1:" + server.address().port;
const original = globalThis.fetch;
const observed = [];
globalThis.fetch = new Proxy(original, {
  apply(target, receiver, args) {
    const promise = Reflect.apply(target, receiver, args);
    observed.push({ args, promise });
    return promise;
  },
});
try {
  const init = { headers: { "X-Proof": "unchanged" } };
  const promise = startRawResponse(base + "/redirect", init);
  assert.equal(
    promise,
    observed[0].promise,
    "raw primitive returns the identical native Promise",
  );
  assert.equal(observed[0].args[1], init, "request init identity");
  const response = await promise;
  assert.equal(response.status, 207);
  assert.equal(
    response.statusText,
    "Raw Head",
    "original response statusText preserved",
  );
  assert.equal(response.url, base + "/stream");
  assert.equal(response.redirected, true);
  assert.equal(response.headers.get("x-raw"), "metadata");
  assert.equal(response.bodyUsed, false, "raw primitive does not consume body");
  assert.equal(
    response.body.locked,
    false,
    "raw primitive does not acquire reader",
  );
  const reader = response.body.getReader();
  assert.equal(new TextDecoder().decode((await reader.read()).value), "first-");
  slots.get("/stream").end("last");
  assert.equal(new TextDecoder().decode((await reader.read()).value), "last");
  assert.equal((await reader.read()).done, true);
  assert.deepEqual(requests, ["/redirect", "/stream"]);
  const cancelled = await startRawResponse(base + "/cancel", {});
  let closed = false;
  slots.get("/cancel").on("close", () => (closed = true));
  await cancelled.body.cancel();
  for (let i = 0; i < 100 && !closed; i++)
    await new Promise((r) => setTimeout(r, 5));
  assert.equal(closed, true, "body cancellation reaches the real server");
  await assert.rejects(
    startRawResponse(base + "/fail", {}),
    { name: "TypeError" },
    "raw network rejection remains a rejection",
  );
  const binary = await startRawResponse(base + "/binary", {});
  assert.deepEqual(
    [...new Uint8Array(await binary.arrayBuffer())],
    [0, 255, 195, 169],
    "raw body bytes are not decoded or replaced",
  );
  assert.equal(observed.length, 4, "one native fetch per primitive invocation");
  console.log("raw-browser-response: PASS");
} finally {
  globalThis.fetch = original;
  for (const r of slots.values()) r.destroy();
  server.closeAllConnections();
  await new Promise((r) => server.close(r));
}
