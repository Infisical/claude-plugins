# Shared helpers for the hook scripts. Source this file; do not run it.

SETUP_COMMAND="/infisical-secret-scan:setup"
# The oldest CLI with everything the plugin uses, such as `infisical login status`.
MIN_CLI_VERSION="0.44.9"
DATA_DIR="${CLAUDE_PLUGIN_DATA:-${TMPDIR:-/tmp}/infisical-secret-scan}"
# The data source the developer chose with the setup command.
SELECTION_FILE="$DATA_DIR/data-source.json"

# An admin can set the data source for everyone, for example in managed settings. It wins over the developer's choice.
DATA_SOURCE_OVERRIDE="${INFISICAL_CLAUDE_CODE_DATA_SOURCE_ID:-}"
DATA_SOURCE_ID="$DATA_SOURCE_OVERRIDE"
DATA_SOURCE_NAME=""
if [ -z "$DATA_SOURCE_ID" ] && [ -f "$SELECTION_FILE" ]; then
  DATA_SOURCE_ID="$(jq -r '.id // empty' "$SELECTION_FILE" 2>/dev/null)"
  DATA_SOURCE_NAME="$(jq -r '.name // empty' "$SELECTION_FILE" 2>/dev/null)"
fi

CACHE_DIR="$DATA_DIR/${DATA_SOURCE_ID:-no-data-source}"
SCAN_CONFIG="$CACHE_DIR/infisical-scan.toml"
FETCHED_AT="$CACHE_DIR/fetched-at"

# The API URL of the Infisical instance the CLI is logged in to.
infisical_api_url() {
  local domain="${INFISICAL_DOMAIN:-}"
  local config="$HOME/.infisical/infisical-config.json"

  if [ -z "$domain" ] && [ -f "$config" ]; then
    domain="$(jq -r '
      (.activeProfile // "") as $active
      | ([.profiles[]? | select(.name == $active) | .domain][0]) // .LoggedInUserDomain // empty
    ' "$config" 2>/dev/null)"
  fi

  domain="${domain:-https://app.infisical.com/api}"
  domain="${domain%/}"
  case "$domain" in
    */api) printf '%s' "$domain" ;;
    *) printf '%s/api' "$domain" ;;
  esac
}

# The access token of the logged-in CLI user, or nothing. Without a session, `infisical user get token` starts a login
# and can open the browser, so it only runs after `infisical login status` finds a session. It can also print an error
# instead of a token, so only a successful run that prints a JWT counts.
infisical_token() {
  local output token
  infisical login status --json --silent </dev/null >/dev/null 2>&1 || return 0
  output="$(infisical user get token --plain 2>/dev/null </dev/null)" || return 0
  token="$(printf '%s\n' "$output" | tail -n 1)"
  [[ "$token" =~ ^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$ ]] && printf '%s' "$token"
}

# True when version $1 is $2 or later. Both are MAJOR.MINOR.PATCH.
version_at_least() {
  local IFS=. i
  local -a have=($1) want=($2)
  for i in 0 1 2; do
    ((10#${have[i]:-0} > 10#${want[i]:-0})) && return 0
    ((10#${have[i]:-0} < 10#${want[i]:-0})) && return 1
  done
  return 0
}

# Checks the installed CLI against MIN_CLI_VERSION. On failure, returns 1 and sets CLI_VERSION_ERROR.
check_cli_version() {
  local version
  version="$(infisical --version 2>/dev/null </dev/null | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)"

  if [ -z "$version" ]; then
    CLI_VERSION_ERROR="could not read the Infisical CLI version. The plugin needs version $MIN_CLI_VERSION or later."
    return 1
  fi

  if ! version_at_least "$version" "$MIN_CLI_VERSION"; then
    CLI_VERSION_ERROR="the Infisical CLI is version $version, and the plugin needs $MIN_CLI_VERSION or later. Update the CLI: https://infisical.com/docs/cli/overview"
    return 1
  fi
}


is_recent() {
  [ -n "$(find "$1" -mmin "-$2" 2>/dev/null)" ]
}

# Why a request to Infisical failed, for the message shown to the user.
# Usage: describe_api_failure <http code> <response file> <curl error file> <api url>
describe_api_failure() {
  local message
  message="$(jq -r '.message // empty' "$2" 2>/dev/null)"

  case "$1" in
    000) printf 'Infisical could not be reached at %s: %s' "$4" "$(cat "$3" 2>/dev/null)" ;;
    401) printf "Infisical rejected the CLI login. Run 'infisical login', then try again." ;;
    403) printf 'Infisical denied the request%s. Ask an admin for access to the Claude Code data source and the secret scanning configuration.' "${message:+ ($message)}" ;;
    404)
      if [ -n "$DATA_SOURCE_OVERRIDE" ]; then
        printf 'Infisical has no Claude Code data source with ID "%s", the value of INFISICAL_CLAUDE_CODE_DATA_SOURCE_ID. Ask your admin to fix it.' "$DATA_SOURCE_ID"
      else
        printf 'Infisical has no Claude Code data source "%s" anymore. Run %s to choose another one.' "${DATA_SOURCE_NAME:-$DATA_SOURCE_ID}" "$SETUP_COMMAND"
      fi
      ;;
    *) printf 'Infisical returned HTTP %s%s' "$1" "${message:+: $message}" ;;
  esac
}

# Downloads the project's secret scanning config for local scans, so they match the scan in Infisical.
# Usage: fetch_scan_config <private work folder>. On failure, returns 1 and sets FETCH_ERROR.
fetch_scan_config() {
  local work="$1" token api_url code project_id

  token="$(infisical_token)"
  if [ -z "$token" ]; then
    FETCH_ERROR="the Infisical CLI is not logged in. Run 'infisical login', then try again."
    return 1
  fi

  api_url="$(infisical_api_url)"
  printf 'Authorization: Bearer %s\n' "$token" >"$work/headers"

  code="$(curl -sS --max-time 10 -o "$work/data-source.json" -w '%{http_code}' -H @"$work/headers" \
    "$api_url/v2/secret-scanning/data-sources/claude-code/$DATA_SOURCE_ID" 2>"$work/curl-error")"
  if [ "$code" != "200" ]; then
    FETCH_ERROR="$(describe_api_failure "$code" "$work/data-source.json" "$work/curl-error" "$api_url")"
    return 1
  fi

  project_id="$(jq -r '.dataSource.projectId // empty' "$work/data-source.json" 2>/dev/null)"
  if [ -z "$project_id" ]; then
    FETCH_ERROR="Infisical returned a data source without a project."
    return 1
  fi

  code="$(curl -sS --max-time 10 -o "$work/config.json" -w '%{http_code}' -H @"$work/headers" \
    "$api_url/v2/secret-scanning/configs?projectId=$project_id" 2>"$work/curl-error")"
  if [ "$code" != "200" ] || ! jq -e 'has("config")' "$work/config.json" >/dev/null 2>&1; then
    FETCH_ERROR="$(describe_api_failure "$code" "$work/config.json" "$work/curl-error" "$api_url")"
    return 1
  fi

  mkdir -p "$CACHE_DIR" || {
    FETCH_ERROR="the plugin could not create its cache folder $CACHE_DIR."
    return 1
  }

  if [ "$(jq -r '.config.content // "" | length' "$work/config.json")" -gt 0 ]; then
    jq -j '.config.content' "$work/config.json" >"$work/infisical-scan.toml"

    # A config the CLI can't load would fail every local scan.
    if ! printf '' | infisical scan --pipe --config "$work/infisical-scan.toml" --silent >/dev/null 2>&1; then
      FETCH_ERROR="the Infisical CLI could not load the project's secret scanning configuration. Fix it in Secret Scanning > Settings."
      return 1
    fi

    mv "$work/infisical-scan.toml" "$SCAN_CONFIG"
  else
    # No custom config: Infisical scans with the CLI defaults, so the local scan does too.
    rm -f "$SCAN_CONFIG"
  fi

  touch "$FETCHED_AT"
}
