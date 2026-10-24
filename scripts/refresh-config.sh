#!/usr/bin/env bash
# Async UserPromptSubmit hook: refresh the cached secret scanning config at most once every 24 hours.
# It never blocks a prompt. If refreshes keep failing, scan-prompt.sh blocks prompts once the cache is too old.

source "$(dirname "$0")/lib.sh"

REFRESH_MINUTES=1440
# After a failed fetch, wait this long before the next try, so a broken setup doesn't mean a request per prompt.
RETRY_MINUTES=60

[ -n "$DATA_SOURCE_ID" ] || exit 0
command -v infisical >/dev/null 2>&1 || exit 0
command -v jq >/dev/null 2>&1 || exit 0
command -v curl >/dev/null 2>&1 || exit 0
check_cli_version || exit 0

mkdir -p "$CACHE_DIR" || exit 0

is_recent "$FETCHED_AT" "$REFRESH_MINUTES" && exit 0
is_recent "$CACHE_DIR/attempted-at" "$RETRY_MINUTES" && exit 0

# Prompts sent in quick succession start one fetch, not several.
mkdir "$CACHE_DIR/lock" 2>/dev/null || exit 0
umask 077
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"; rmdir "$CACHE_DIR/lock"' EXIT

touch "$CACHE_DIR/attempted-at"

fetch_scan_config "$tmp"
