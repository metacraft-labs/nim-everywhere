#!/usr/bin/env bash
# Thin wrapper: the check itself is Node (see the .mjs for why).
set -euo pipefail
exec node "$(dirname "${BASH_SOURCE[0]}")/check_http_projection_effects.mjs"
