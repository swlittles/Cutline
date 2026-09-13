#!/bin/bash
set -euo pipefail
exec "$(dirname "$0")/test-all.sh" ui
