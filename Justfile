alias t := test
alias fmt := format

build: build-native build-js

build-native:
    nim c --path:src tests/test_platform_smoke.nim
    nim c --path:src tests/test_async_http.nim

build-js:
    nim js --path:src tests/test_platform_smoke.nim
    nim js --path:src tests/test_async_http.nim

test: test-native test-js

test-native:
    nim c -r --path:src tests/test_platform_smoke.nim
    nim c -r --path:src tests/test_async_http.nim

test-js:
    bash tools/nim-js-test-gate.sh --path:src tests/test_platform_smoke.nim
    bash tools/nim-js-test-gate.sh --path:src tests/test_async_http.nim

lint: lint-nim lint-nix

lint-nim:
    nim check --path:src tests/test_platform_smoke.nim
    nim check --path:src tests/test_async_http.nim

lint-nix:
    nixfmt --check flake.nix

format: format-nim format-nix

format-nim:
    nimpretty src/nim_everywhere.nim src/nim_everywhere/*.nim tests/*.nim

format-nix:
    nixfmt flake.nix

bump-version version:
    sed -i "s/^version       = .*/version       = \"{{version}}\"/" nim_everywhere.nimble
    printf "%s\n" "{{version}}" > VERSION
