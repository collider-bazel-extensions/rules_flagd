#!/usr/bin/env bash
# Inner test for server_cleanup_test: records where flagd listened.
set -euo pipefail
echo "$FLAGD_OFREP_PORT" > "$RECORD_FILE"
