// Actual compiler tag-ceiling errors must name their operation and the precise
// unlisted-effect diagnostic. Each own tag-removal inverse must compile the same
// ceiling; strict tagged positive compilation prevents a broken setup passing.
//
// Written in Node (not Python) because Node is the interpreter every lane of
// this repo already provisions for the JS tests, whereas the isolated Windows
// dev environment declares no Python.
import { mkdtempSync, writeFileSync, readFileSync, cpSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import assert from "node:assert/strict";

const root = process.cwd();
const work = mkdtempSync(join(tmpdir(), "ne-http-effects-"));
const fixture = join(root, "tests", "http_projection_fixture.nim");

function compile(extra, path, out) {
  const p = spawnSync(
    "nim",
    ["js", "-d:isonimStrictNondet", "--path:" + path, "--out:" + out, ...extra, fixture],
    { encoding: "utf8" },
  );
  assert.ok(!p.error, "cannot run nim: " + p.error);
  return { status: p.status, text: (p.stdout ?? "") + (p.stderr ?? "") };
}

const positive = compile(["-d:extractedHttpComposition"], join(root, "src"), join(work, "positive.js"));
writeFileSync(join(work, "positive.log"), positive.text);
assert.equal(positive.status, 0, positive.text);

for (const [mode, operation] of [
  ["Prepare", "prepareHttpRequestRaw"],
  ["Init", "buildHttpRequestInitRaw"],
  ["Project", "projectHttpResponseRaw"],
]) {
  const refused = compile(["-d:raw" + mode + "EffectCeiling"], join(root, "src"), join(work, mode + ".js"));
  writeFileSync(join(work, mode + ".log"), refused.text);
  assert.notEqual(refused.status, 0, operation + " accepted tags:[]");
  assert.ok(
    refused.text.includes("Error: " + operation + "(") &&
      refused.text.includes("can have an unlisted effect: RawNondet"),
    refused.text,
  );
  const copy = join(work, mode);
  cpSync(join(root, "src"), copy, { recursive: true });
  const file = join(copy, "nim_everywhere", "http.nim");
  const source = readFileSync(file, "utf8").replaceAll("\r\n", "\n");
  const start = source.indexOf("  proc " + operation + "*");
  assert.notEqual(start, -1, "no declaration of " + operation);
  const end = source.indexOf(" =\n", start);
  assert.notEqual(end, -1, "no body of " + operation);
  const signature = source.slice(start, end);
  const tag = " {.tags: [RawNondet].}";
  assert.equal(signature.split(tag).length - 1, 1, signature);
  writeFileSync(file, source.slice(0, start) + signature.replace(tag, "") + source.slice(end));
  const inverse = compile(["-d:raw" + mode + "EffectCeiling"], copy, join(work, mode + "-inverse.js"));
  writeFileSync(join(work, mode + "-inverse.log"), inverse.text);
  assert.equal(inverse.status, 0, inverse.text);
  console.log(operation + ": precise effect refusal and own tag-removal inverse PASS");
}
console.log("retained effects inputs/logs", work);
