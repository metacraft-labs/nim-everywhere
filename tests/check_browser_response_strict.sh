#!/usr/bin/env bash
# Real compiler guard: only the intended strict diagnostic qualifies failure.
set -euo pipefail
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
if nim js -d:isonimStrictNondet -d:unqualifiedRawResponse --path:src --out:"$work/invalid.js" tests/browser_response_fixture.nim >"$work/diagnostic" 2>&1; then
  echo 'strict mode accepted unqualified fetchBrowserResponseRaw' >&2
  exit 1
fi
grep -F 'isonimStrictNondet: raw platform binding fetchBrowserResponseRaw' "$work/diagnostic"
if nim js -d:rawResponseEffectCeiling --path:src --out:"$work/effect.js" tests/browser_response_fixture.nim >"$work/effect" 2>&1; then
  echo 'raw response primitive lost RawNondet effect' >&2
  exit 1
fi
grep -F 'RawNondet' "$work/effect"
