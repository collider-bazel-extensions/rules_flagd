#!/usr/bin/env bash
# Helpers for flagd_test scripts:  source "$FLAGD_TESTLIB"
#
#   flagd_eval FLAG [CONTEXT_JSON]        OFREP evaluation as JSON (value, variant,
#                                         reason, or errorCode)
#   flagd_value FLAG [CONTEXT_JSON]       the value: strings raw, others as JSON
#                                         (true, 3, {"a":1}); fails on an error
#   flagd_variant FLAG [CONTEXT_JSON]     the variant
#   flagd_wait_value FLAG EXPECTED [CONTEXT_JSON] [TIMEOUT_S]
#                                         wait until flagd_value prints EXPECTED (30 s)
#   flagd_set_flags FILE.json             replace the runtime overrides with FILE's flags
#   flagd_set_flag KEY FLAG_JSON          add or replace one override
#   flagd_clear_flags                     remove every override
#
# Overrides take precedence over the configured flags; the set/clear
# helpers return once flagd serves the change.

_flagd_py() { python3 "$FLAGD_TESTLIB_PY" "$@"; }

flagd_eval()        { _flagd_py eval "$@"; }
flagd_value()       { _flagd_py value "$@"; }
flagd_variant()     { _flagd_py variant "$@"; }
flagd_wait_value()  { _flagd_py wait-value "$@"; }
flagd_set_flags()   { _flagd_py set-flags "$1"; }
flagd_set_flag()    { _flagd_py set-flag "$1" "$2"; }
flagd_clear_flags() { _flagd_py clear-flags; }
