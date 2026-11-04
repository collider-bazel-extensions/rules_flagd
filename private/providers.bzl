"""Providers exposed by rules_flagd."""

FlagdBinaryInfo = provider(
    doc = "flagd toolchain binary.",
    fields = {
        "version":   "string — pinned flagd version",
        "flagd_bin": "File — the flagd executable",
    },
)

FlagdFlagsInfo = provider(
    doc = "Checked flagd flag definitions (flagd_flags).",
    fields = {
        "sources": "list of File — flag files in source order (deps first). " +
                   "flagd merges them in this order: a flag key in a later " +
                   "file replaces the same key from an earlier one.",
    },
)
