#!/usr/bin/env bash
# Installs the Infisical CLI version that this plugin is tested with in <data dir>/bin. install-cli-command.sh runs it
# for /infisical-secret-scanner:install-cli, and you can also run it from a shell. It downloads the release archive for this
# platform from GitHub and installs nothing unless the archive matches the SHA-256 hash below.
#
# Usage: install-cli.sh <data dir>
# On success, prints one line that names the installed CLI. On failure, prints the reason to stderr and exits with 1.
#
# To pin a new version: set CLI_VERSION, download the checksum files of the release with
#   gh release download v<version> -R Infisical/cli -p 'checksums*.txt'
# and copy the hashes of the archives below from checksums.txt and checksums-darwin.txt.

set -o pipefail

CLI_VERSION="0.45.4"

# The scan must not reach the network, and neither must the test run of the downloaded CLI.
export INFISICAL_DISABLE_TELEMETRY=1 INFISICAL_DISABLE_UPDATE_CHECK=1

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

source "$(dirname "${BASH_SOURCE[0]}")/common.sh" 2>/dev/null || fail "Could not load common.sh from the plugin's scripts folder."

data_dir="$1"
[ -n "$data_dir" ] || fail "Usage: install-cli.sh <data dir>"

case "$(uname -s)" in
  Darwin) os=darwin ;;
  Linux) os=linux ;;
  MINGW* | MSYS* | CYGWIN*) os=windows ;;
  *) os=unknown ;;
esac
case "$(uname -m)" in
  x86_64 | amd64) arch=amd64 ;;
  arm64 | aarch64) arch=arm64 ;;
  *) arch=unknown ;;
esac

case "${os}_$arch" in
  darwin_amd64) expected_hash=d5f80a0d926c84f5875bf927152cadd193a769962af67a3d6f4ba3666f1140ae ;;
  darwin_arm64) expected_hash=2c44c652b896d5d845abad46348b0b94af1b7be8846491a2501e92e2da43e257 ;;
  linux_amd64) expected_hash=107389f4c9a0cc48023a834bb2a5bf1280c0a0e45ea7a98d13807d4def21b0a5 ;;
  linux_arm64) expected_hash=fcfd91de70efdedc7f8c1b1d90a024b433bb185387fe32467d49625a3bf55379 ;;
  windows_amd64) expected_hash=33537924a25e3fc9c9ddb56099ff308b3f281a218ecd8a369cf881490c8633d4 ;;
  windows_arm64) expected_hash=5c26256d0740a88ecce978280101273317f3a7da4d26d59c990f04c9befdd0a2 ;;
  *) fail "The plugin can't install the Infisical CLI on $(uname -s) $(uname -m)." ;;
esac

if [ "$os" = windows ]; then
  archive_name="cli_${CLI_VERSION}_${os}_$arch.zip"
  binary=infisical.exe
else
  archive_name="cli_${CLI_VERSION}_${os}_$arch.tar.gz"
  binary=infisical
fi
url="https://github.com/Infisical/cli/releases/download/v$CLI_VERSION/$archive_name"

mkdir -p "$data_dir" || fail "Could not create the folder $data_dir."
# A hook that times out is stopped before it can remove its work folder, so remove old ones here.
find "$data_dir" -maxdepth 1 -type d -name '.cli-install.*' -mmin +30 -exec rm -rf {} + 2>/dev/null
# The work folder is in the data folder, so the binary moves into place in one step: a scan that runs at the same time
# sees the old CLI or the new CLI, never part of a file.
work="$(mktemp -d "$data_dir/.cli-install.XXXXXX")" || fail "Could not create a work folder in $data_dir."
trap 'rm -rf "$work"' EXIT

# A connection to GitHub can fail once and work on the next try, so curl tries up to 3 times. The hook stops this script
# after 120 seconds. The worst case stays below that: two connection timeouts of 10 seconds, two waits of 2 seconds,
# and a last try of 85 seconds. No new try starts after 30 seconds.
if command -v curl >/dev/null 2>&1; then
  curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 --connect-timeout 10 --max-time 85 \
    --retry 2 --retry-delay 2 --retry-max-time 30 -o "$work/$archive_name" "$url" 2>"$work/download-error"
elif command -v wget >/dev/null 2>&1; then
  wget -q --https-only --timeout=10 --tries=3 -O "$work/$archive_name" "$url" 2>"$work/download-error"
else
  fail "Could not download the Infisical CLI, because neither curl nor wget is installed."
fi || {
  reason="$(tail -n 1 "$work/download-error")"
  fail "Could not download $url${reason:+ ($reason)}. Check that this machine can reach github.com."
}

[ "$(sha256 <"$work/$archive_name")" = "$expected_hash" ] ||
  fail "The downloaded archive $archive_name does not match the SHA-256 hash that ships with the plugin, so it was not installed."

if [ "$os" = windows ]; then
  command -v unzip >/dev/null 2>&1 || fail "Could not unpack $archive_name, because unzip is not installed."
  unzip -q -o "$work/$archive_name" "$binary" -d "$work" >/dev/null 2>&1
else
  tar -xzf "$work/$archive_name" -C "$work" "$binary" >/dev/null 2>&1
fi || fail "Could not unpack $archive_name."

chmod 700 "$work/$binary" || fail "Could not make the Infisical CLI executable."
"$work/$binary" --version >/dev/null 2>&1 ||
  fail "The downloaded Infisical CLI does not run on this machine. The folder $data_dir can be on a file system that does not allow programs to run."

mkdir -p "$data_dir/bin" && mv -f "$work/$binary" "$data_dir/bin/$binary" ||
  fail "Could not install the Infisical CLI in $data_dir/bin."

printf 'Installed Infisical CLI %s in %s.\n' "$CLI_VERSION" "$data_dir/bin/$binary"
