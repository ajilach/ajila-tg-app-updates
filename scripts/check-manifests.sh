#!/usr/bin/env bash
#
# check-manifests.sh — check that every <app-id>/latest.json in the update-manifest repo
# (https://github.com/ajilach/ajila-tg-app-updates) has the exact shape the installed
# apps expect, so a hand edit or a bad publish is caught on the next CI run.
#
# Usage:
#   check-manifests.sh [<dir>]
#
#   <dir>  the checkout to check (default: the repo this script lives in)
#
# Rules (the format is documented in the ajila-tg-app-updates README):
#   - Every folder with a latest.json is an app listed in APPS below: adding an app
#     means adding a row. Every app in APPS has its manifest, except one marked
#     "unreleased" (a notice only), whose first release creates the file.
#   - The retired root latest.json must not come back.
#   - Each manifest is one JSON object with exactly the keys tag_name, name, html_url,
#     published_at, draft, prerelease (in that order), formatted like jq's output.
#   - tag_name is a plain vX.Y.Z; name is non-empty; draft and prerelease are false;
#     published_at is UTC (YYYY-MM-DDTHH:MM:SSZ); html_url is
#     https://github.com/<code repo>/releases/tag/<tag_name>.
#
# Prints one line per manifest and exits 1 (::error::) if anything is wrong.
#
# Needs bash 3.2+ and jq.
set -euo pipefail

# app-id → the private code repo whose releases its manifest announces. Add a third
# column "unreleased" to a new app's row until its first release has created its
# manifest; for every other app a missing manifest is an error.
APPS='
save-aem-form           ajilach/ajila-forms-tg-save-form
aem-slingshot           ajilach/ajila-tg-dockerized-aem
aem-translation-editor  ajilach/ajila-aem-translation-tool
aem-bumblebee           ajilach/ajila-tg-aem-forms-editor  unreleased
zmettag                 ajilach/Zmettag
'

KEYS='["tag_name","name","html_url","published_at","draft","prerelease"]'
# jq regexes: \A and \z, because jq's ^ and $ would also accept a trailing newline.
TAG_RE='\Av[0-9]+\.[0-9]+\.[0-9]+\z'
DATE_RE='\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\z'

usage() {
  echo "usage: check-manifests.sh [<dir>]" >&2
  exit 2
}

# code_repo <app-id> — prints the app's code repo; fails for an unknown app.
code_repo() {
  local id repo state
  while read -r id repo state; do
    if [[ -n "$id" && "$id" == "$1" ]]; then
      echo "$repo"
      return 0
    fi
  done <<<"$APPS"
  return 1
}

# check_manifest <file> <code repo> — succeeds if the manifest is valid; otherwise sets
# PROBLEM to the first thing wrong with it. Values are quoted as JSON in messages.
check_manifest() {
  local file=$1 repo=$2 keys
  PROBLEM=
  if ! jq -se 'length == 1 and (.[0] | type == "object")' "$file" >/dev/null 2>&1; then
    PROBLEM="not a single JSON object"
    return 1
  fi
  keys=$(jq -c 'keys_unsorted' "$file")
  if [[ "$keys" != "$KEYS" ]]; then
    PROBLEM="keys must be exactly $KEYS in that order, not $keys"
    return 1
  fi
  if ! jq -e '[.tag_name, .name, .html_url, .published_at]
              | all(type == "string" and length > 0)' "$file" >/dev/null; then
    PROBLEM="tag_name, name, html_url and published_at must be non-empty strings"
    return 1
  fi
  if ! jq -e '.draft == false and .prerelease == false' "$file" >/dev/null; then
    PROBLEM="draft and prerelease must both be false"
    return 1
  fi

  # Compared inside jq: $(...) would drop a trailing newline from a value.
  if ! jq -e --arg re "$TAG_RE" '.tag_name | test($re)' "$file" >/dev/null; then
    PROBLEM="tag_name $(jq -c '.tag_name' "$file") is not a plain vX.Y.Z tag"
    return 1
  fi
  if ! jq -e --arg re "$DATE_RE" '.published_at | test($re)' "$file" >/dev/null; then
    PROBLEM="published_at $(jq -c '.published_at' "$file") is not UTC YYYY-MM-DDTHH:MM:SSZ"
    return 1
  fi
  if ! jq -e --arg repo "$repo" \
       '.html_url == "https://github.com/\($repo)/releases/tag/\(.tag_name)"' "$file" >/dev/null; then
    PROBLEM="html_url $(jq -c '.html_url' "$file") is not https://github.com/$repo/releases/tag/$(jq -r '.tag_name' "$file")"
    return 1
  fi
  if ! jq . "$file" | cmp -s - "$file"; then
    PROBLEM="not formatted like jq's output (2-space indent, trailing newline); rewrite it with jq ."
    return 1
  fi
}

# --- Arguments ----------------------------------------------------------------------------
case "${1:-}" in -*) usage ;; esac
[[ $# -le 1 ]] || usage
DIR=${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
[[ -d "$DIR" ]] || { echo "::error::$DIR is not a directory" >&2; exit 2; }
cd "$DIR"

# --- Check --------------------------------------------------------------------------------
FAILED=0
bad() { echo "::error file=$1::$1: $2"; FAILED=1; }

if [[ -e latest.json ]]; then
  bad latest.json "the root manifest is retired; each app's manifest is <app-id>/latest.json"
fi

shopt -s nullglob
for file in */latest.json; do
  app=${file%/latest.json}
  if ! repo=$(code_repo "$app"); then
    bad "$file" "unknown app id '$app'; add it to APPS in scripts/check-manifests.sh"
  elif check_manifest "$file" "$repo"; then
    printf 'ok    %-36s %-9s %s\n' "$file" "$(jq -r '.tag_name' "$file")" "$(jq -r '.html_url' "$file")"
  else
    bad "$file" "$PROBLEM"
  fi
done

while read -r app repo state; do
  [[ -n "$app" ]] || continue
  if [[ "$state" == unreleased ]]; then
    if [[ -e "$app/latest.json" ]]; then
      echo "::notice::$app has published its manifest; remove 'unreleased' from its row in APPS."
    else
      echo "::notice::$app/latest.json does not exist yet; the first release of $repo creates it."
    fi
  elif [[ ! -e "$app/latest.json" ]]; then
    bad "$app/latest.json" "missing; restore it (only an app marked 'unreleased' in APPS may lack its manifest)"
  fi
done <<<"$APPS"

exit "$FAILED"
