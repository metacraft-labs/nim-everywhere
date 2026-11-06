// Compile actual owning source mutations; real local HTTP/native fetch remains.
import { mkdtemp, mkdir, cp, readFile, writeFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import assert from "node:assert/strict";
const source = await readFile("src/nim_everywhere/http.nim", "utf8");
const work = await mkdtemp(join(tmpdir(), "raw-response-mutants-"));
const controls = [
  [
    "extra-continuation",
    "fetch(#, #)",
    "(fetch(#, #).then(function(r){return r;}))",
    "raw primitive returns the identical native Promise",
  ],
  ["drop-init", "fetch(#, #)", "fetch(#, (void #))", "request init identity"],
  [
    "early-body-lock",
    "fetch(#, #)",
    "(function(u,i){var p=fetch(u,i);p.then(function(r){r.body.getReader();});return p;})(#,#)",
    "raw primitive does not acquire reader",
  ],
  [
    "lost-metadata",
    "fetch(#, #)",
    "(function(u,i){var p=fetch(u,i);p.then(function(r){Object.defineProperty(r,'statusText',{value:'lost'});});return p;})(#,#)",
    "original response statusText preserved",
  ],
];
try {
  for (const [name, old, replacement, diagnostic] of controls) {
    assert.equal(source.split(old).length - 1, 1);
    const dir = join(work, name);
    await cp("src", dir, { recursive: true });
    await writeFile(
      join(dir, "nim_everywhere/http.nim"),
      source.replace(old, replacement),
    );
    const output = join(dir, "probe.js");
    let run = spawnSync(
      "nim",
      [
        "js",
        "--path:src",
        "--path:" + dir,
        "--out:" + output,
        resolve("tests/browser_response_fixture.nim"),
      ],
      { encoding: "utf8" },
    );
    assert.equal(run.status, 0, run.stdout + run.stderr);
    run = spawnSync(process.execPath, ["tests/test_browser_response.mjs"], {
      env: { ...process.env, RAW_RESPONSE_FIXTURE: output },
      encoding: "utf8",
      timeout: 30000,
    });
    assert.equal(run.signal, null, "mutation must fail assertion, not timeout");
    assert.notEqual(run.status, 0, "mutant unexpectedly passed " + name);
    assert(
      (run.stdout + run.stderr).includes(diagnostic),
      run.stdout + run.stderr,
    );
    console.log("rejected " + name + ": " + diagnostic);
  }
} finally {
  await rm(work, { recursive: true, force: true });
}
