#!/usr/bin/env bash
# Used by the /infisical-secret-scan:setup command, which passes the plugin data folder because the Bash tool doesn't
# get it. Prints JSON for Claude to read.
#
#   setup.sh --data-dir <folder> check                 checks the setup and lists the Claude Code data sources
#   setup.sh --data-dir <folder> select <data source>  saves the developer's choice, which must be a listed data source

if [ "$1" = "--data-dir" ]; then
  export CLAUDE_PLUGIN_DATA="$2"
  shift 2
fi

fail() {
  if command -v jq >/dev/null 2>&1; then
    jq -n --arg error "$1" '{ok: false, error: $error}'
  else
    printf '{"ok": false, "error": "%s"}\n' "$1"
  fi
  exit 1
}

for tool in infisical jq curl; do
  command -v "$tool" >/dev/null 2>&1 ||
    fail "$tool is not installed. Install the Infisical CLI (https://infisical.com/docs/cli/overview), jq, and curl, then run the setup command again."
done

[ -n "$CLAUDE_PLUGIN_DATA" ] || fail "The plugin data folder was not passed to the setup script."

source "$(dirname "$0")/lib.sh"

if ! check_cli_version; then
  # The message starts lowercase in the hooks, after "Infisical: ".
  first="$(printf '%s' "$CLI_VERSION_ERROR" | cut -c1 | tr '[:lower:]' '[:upper:]')"
  fail "$first${CLI_VERSION_ERROR:1}"
fi

umask 077
tmp="$(mktemp -d)" || fail "The setup script could not create a temporary folder."
trap 'rm -rf "$tmp"' EXIT

token="$(infisical_token)"
[ -n "$token" ] ||
  fail "The Infisical CLI is not logged in. Run 'infisical login' in a terminal, then run the setup command again."

api_url="$(infisical_api_url)"
printf 'Authorization: Bearer %s\n' "$token" >"$tmp/headers"

# Lists the Claude Code data sources in the organization's Secret Scanning project.
code="$(curl -sS --max-time 20 -o "$tmp/list.json" -w '%{http_code}' -H @"$tmp/headers" \
  "$api_url/v2/secret-scanning/data-sources/claude-code" 2>"$tmp/curl-error")"

case "$code" in
  200) ;;
  403) fail "Infisical denied the request to list data sources. Ask an admin for permission to read data sources in Secret Scanning." ;;
  *) fail "Could not list the Claude Code data sources: $(describe_api_failure "$code" "$tmp/list.json" "$tmp/curl-error" "$api_url")" ;;
esac

jq '[.dataSources[] | {
    id,
    name,
    description,
    projectId,
    onSecretDetected: (.config.onSecretDetected // "block")
  }]' "$tmp/list.json" >"$tmp/data-sources.json" 2>/dev/null ||
  fail "Infisical returned a data source list that the setup script could not read."

find_data_source() {
  jq -c --arg id "$1" '.[] | select(.id == $id)' "$tmp/data-sources.json"
}

case "$1" in
  check)
    if [ -n "$DATA_SOURCE_OVERRIDE" ]; then
      jq -n --argjson dataSource "$(find_data_source "$DATA_SOURCE_OVERRIDE" | jq -s '.[0]')" --arg id "$DATA_SOURCE_OVERRIDE" \
        '{ok: true, override: {id: $id, name: ($dataSource.name // null)}}'
      exit 0
    fi

    [ "$(jq 'length' "$tmp/data-sources.json")" -gt 0 ] ||
      fail "There are no Claude Code data sources in your organization's Secret Scanning project. Ask an admin to create one in Infisical, then run the setup command again."

    jq -n --slurpfile dataSources "$tmp/data-sources.json" --arg current "$DATA_SOURCE_ID" '{
        ok: true,
        current: (if $current == "" then null else ($dataSources[0][] | select(.id == $current) | .name) end),
        dataSources: [$dataSources[0][] | {id, name, description, onSecretDetected}]
      }'
    ;;

  select)
    [ -z "$DATA_SOURCE_OVERRIDE" ] ||
      fail "Your admin set the data source with INFISICAL_CLAUDE_CODE_DATA_SOURCE_ID, so it can't be changed here."

    selected="$(find_data_source "$2")"
    [ -n "$2" ] && [ -n "$selected" ] ||
      fail "\"$2\" is not one of your Claude Code data sources. Only a data source from the list can be selected."

    mkdir -p "$DATA_DIR" || fail "The setup script could not create the plugin data folder $DATA_DIR."
    printf '%s' "$selected" | jq '{id, name, projectId}' >"$tmp/data-source.json" &&
      mv "$tmp/data-source.json" "$SELECTION_FILE" ||
      fail "The setup script could not save the selection in $DATA_DIR."

    # Load the scan config now, so the next prompt doesn't have to.
    DATA_SOURCE_ID="$(jq -r '.id' "$SELECTION_FILE")"
    DATA_SOURCE_NAME="$(jq -r '.name' "$SELECTION_FILE")"
    CACHE_DIR="$DATA_DIR/$DATA_SOURCE_ID"
    SCAN_CONFIG="$CACHE_DIR/infisical-scan.toml"
    FETCHED_AT="$CACHE_DIR/fetched-at"
    mkdir -p "$tmp/fetch"
    fetch_scan_config "$tmp/fetch" || warning="The selection is saved, but the scan configuration could not be loaded: $FETCH_ERROR"

    printf '%s' "$selected" | jq --arg warning "${warning:-}" '{
        ok: true,
        selected: {name, onSecretDetected},
        warning: (if $warning == "" then null else $warning end)
      }'
    ;;

  *)
    fail "Unknown setup action \"$1\"."
    ;;
esac
