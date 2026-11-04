#!/usr/bin/env bash
# Inner test for server_cleanup_test: records where flagd and a replica
# started with flagd_start_instance listened.
set -euo pipefail
source "$FLAGD_TESTLIB"
b=$(flagd_start_instance b)
echo "$FLAGD_OFREP_PORT $(flagd_on "$b" bash -c 'echo $FLAGD_OFREP_PORT')" > "$RECORD_FILE"
