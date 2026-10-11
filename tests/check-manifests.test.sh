#!/usr/bin/env bash
#
# Tests for scripts/check-manifests.sh against fixture directories: a valid set of
# manifests passes, and each kind of violation fails.
#
# Usage: tests/check-manifests.test.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT/scripts/check-manifests.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAILED=0

pass() { echo "ok   - $*"; }
fail() { echo "FAIL - $*"; FAILED=1; }

# "<app-id> <code repo>" for every app in the check script's APPS table, so a new app
# needs no edit here.
APP_ROWS=$(sed -n "/^APPS='/,/^'/p" "$CHECK" | awk 'NF >= 2 && $1 !~ /^APPS=/ { print $1, $2 }')
[[ -n "$APP_ROWS" ]] || { echo "could not read the APPS table from $CHECK"; exit 1; }
APP_COUNT=$(wc -l <<<"$APP_ROWS" | tr -d ' ')

# fixture — a fresh directory with a valid manifest for each known app; prints its path.
fixture() {
  local dir app repo
  dir=$(mktemp -d "$WORK/case.XXXXXX")
  while read -r app repo; do
    mkdir "$dir/$app"
    jq -n --arg r "$repo" '{tag_name: "v1.2.0", name: "Example 1.2.0",
      html_url: ("https://github.com/" + $r + "/releases/tag/v1.2.0"),
      published_at: "2026-10-11T12:00:00Z", draft: false, prerelease: false}' \
      >"$dir/$app/latest.json"
  done <<<"$APP_ROWS"
  echo "$dir"
}

# edit <dir> <app-id> <jq filter> — rewrites one manifest through jq (keeping jq's format).
edit() {
  local file="$1/$2/latest.json"
  jq "$3" "$file" >"$file.tmp" && mv "$file.tmp" "$file"
}

# expect_fail <description> <dir> <file the error must name>
expect_fail() {
  local out status=0
  out=$("$CHECK" "$2" 2>&1) || status=$?
  if [[ $status -eq 1 && "$out" == *"::error file=$3::"* ]]; then
    pass "$1"
  else
    fail "$1 (exit $status): $out"
  fi
}

# 1. A valid set passes with one "ok" line per manifest.
dir=$(fixture)
if out=$("$CHECK" "$dir" 2>&1) && [[ "$(grep -c '^ok ' <<<"$out")" == "$APP_COUNT" ]]; then
  pass "valid manifests pass"
else
  fail "valid manifests: $out"
fi

# 2. What the publisher writes passes the check (the two scripts agree on the format).
dir=$(fixture)
git init --quiet --bare --initial-branch=main "$WORK/origin.git"
git -C "$dir" init --quiet --initial-branch=main
git -C "$dir" add .
git -C "$dir" -c user.name=test -c user.email=test@example.com commit --quiet -m seed
git -C "$dir" push --quiet "$WORK/origin.git" HEAD:main
git clone --quiet "$WORK/origin.git" "$WORK/ci"
release=$(jq -n '{tagName: "v1.3.0", name: "Save AEM Form 1.3.0",
  url: "https://github.com/ajilach/ajila-forms-tg-save-form/releases/tag/v1.3.0",
  publishedAt: "2026-10-11T12:00:00Z", isDraft: false, isPrerelease: false}')
out=
if GITHUB_REPOSITORY=ajilach/ajila-forms-tg-save-form PUBLISH_RELEASE_JSON="$release" GITHUB_STEP_SUMMARY= \
     "$ROOT/scripts/publish-update-manifest.sh" "$WORK/ci" save-aem-form v1.3.0 >/dev/null 2>&1 \
   && [[ "$(jq -r .tag_name "$WORK/ci/save-aem-form/latest.json")" == v1.3.0 ]] \
   && out=$("$CHECK" "$WORK/ci" 2>&1); then
  pass "published manifest passes"
else
  fail "published manifest: ${out:-publish failed}"
fi

# 3. A released app's manifest must exist; an app marked "unreleased" in APPS (tested on
#    a copy of the script with an extra row) only gets a notice, until its first release.
dir=$(fixture); rm -r "$dir/aem-slingshot"
expect_fail "rejects a missing manifest" "$dir" aem-slingshot/latest.json
mkdir "$WORK/unreleased"
awk '{ print } /^APPS=/{ print "new-app  ajilach/new-app  unreleased" }' \
  "$CHECK" >"$WORK/unreleased/check-manifests.sh"
chmod +x "$WORK/unreleased/check-manifests.sh"
dir=$(fixture)
if out=$("$WORK/unreleased/check-manifests.sh" "$dir" 2>&1) \
   && [[ "$out" == *"::notice::new-app/latest.json does not exist yet"* ]]; then
  pass "unreleased app without a manifest is a notice"
else
  fail "unreleased app without a manifest: $out"
fi
mkdir "$dir/new-app"
jq '.html_url = "https://github.com/ajilach/new-app/releases/tag/v1.2.0"' \
  "$dir/save-aem-form/latest.json" >"$dir/new-app/latest.json"
if out=$("$WORK/unreleased/check-manifests.sh" "$dir" 2>&1) \
   && [[ "$(grep -c '^ok ' <<<"$out")" == $(( APP_COUNT + 1 )) && "$out" == *"remove 'unreleased'"* ]]; then
  pass "unreleased app with a manifest passes and asks to drop the marker"
else
  fail "unreleased app with a manifest: $out"
fi

# 4. Not one JSON object.
dir=$(fixture); echo 'not json' >"$dir/save-aem-form/latest.json"
expect_fail "rejects invalid JSON" "$dir" save-aem-form/latest.json
dir=$(fixture); echo '[]' >"$dir/save-aem-form/latest.json"
expect_fail "rejects a JSON array" "$dir" save-aem-form/latest.json
dir=$(fixture); : >"$dir/save-aem-form/latest.json"
expect_fail "rejects an empty file" "$dir" save-aem-form/latest.json
dir=$(fixture); file="$dir/save-aem-form/latest.json"; cat "$file" "$file" >"$file.tmp" && mv "$file.tmp" "$file"
expect_fail "rejects two JSON values" "$dir" save-aem-form/latest.json

# 5. Keys: exactly the six, in order.
dir=$(fixture); edit "$dir" aem-slingshot 'del(.published_at)'
expect_fail "rejects a missing key" "$dir" aem-slingshot/latest.json
dir=$(fixture); edit "$dir" aem-slingshot '. + {body: "notes"}'
expect_fail "rejects an extra key" "$dir" aem-slingshot/latest.json
dir=$(fixture); edit "$dir" aem-slingshot '{name, tag_name, html_url, published_at, draft, prerelease}'
expect_fail "rejects keys out of order" "$dir" aem-slingshot/latest.json

# 6. Field types and values.
dir=$(fixture); edit "$dir" aem-slingshot '.name = ""'
expect_fail "rejects an empty name" "$dir" aem-slingshot/latest.json
dir=$(fixture); edit "$dir" aem-slingshot '.name = null'
expect_fail "rejects a null name" "$dir" aem-slingshot/latest.json
dir=$(fixture); edit "$dir" aem-slingshot '.draft = true'
expect_fail "rejects a draft" "$dir" aem-slingshot/latest.json
dir=$(fixture); edit "$dir" aem-slingshot '.prerelease = true'
expect_fail "rejects a prerelease" "$dir" aem-slingshot/latest.json
dir=$(fixture); edit "$dir" aem-slingshot '.draft = "false"'
expect_fail "rejects draft as a string" "$dir" aem-slingshot/latest.json

for tag in v1.2 1.2.0 V1.2.0 v1.2.0-rc.1 v1.2.0.1; do
  dir=$(fixture)
  edit "$dir" aem-translation-editor ".tag_name = \"$tag\"
    | .html_url = \"https://github.com/ajilach/ajila-aem-translation-tool/releases/tag/$tag\""
  expect_fail "rejects tag $tag" "$dir" aem-translation-editor/latest.json
done

for date in 2026-10-11T12:00:00+02:00 2026-10-11T12:00:00.000Z "2026-10-11 12:00:00Z" 2026-10-11; do
  dir=$(fixture); edit "$dir" save-aem-form ".published_at = \"$date\""
  expect_fail "rejects published_at $date" "$dir" save-aem-form/latest.json
done

for url in \
  https://github.com/ajilach/ajila-tg-dockerized-aem/releases/tag/v1.2.0 \
  https://github.com/ajilach/ajila-forms-tg-save-form/releases/tag/v1.1.0 \
  http://github.com/ajilach/ajila-forms-tg-save-form/releases/tag/v1.2.0 \
  https://github.com/ajilach/ajila-forms-tg-save-form/releases/tag/v1.2.0/ \
  https://github.com/ajilach/SaveAEMForm/releases/tag/v1.2.0; do
  dir=$(fixture); edit "$dir" save-aem-form ".html_url = \"$url\""
  expect_fail "rejects html_url $url" "$dir" save-aem-form/latest.json
done

# A trailing newline in a value must not slip through (strict clients reject it).
dir=$(fixture); edit "$dir" aem-translation-editor '.tag_name += "\n" | .html_url += "\n"'
expect_fail "rejects a tag with a trailing newline" "$dir" aem-translation-editor/latest.json
dir=$(fixture); edit "$dir" save-aem-form '.published_at += "\n"'
expect_fail "rejects published_at with a trailing newline" "$dir" save-aem-form/latest.json
dir=$(fixture); edit "$dir" save-aem-form '.html_url += "\n"'
expect_fail "rejects html_url with a trailing newline" "$dir" save-aem-form/latest.json

# 7. Formatting: jq's output, trailing newline included.
dir=$(fixture); file="$dir/save-aem-form/latest.json"; jq -c . "$file" >"$file.tmp" && mv "$file.tmp" "$file"
expect_fail "rejects a minified manifest" "$dir" save-aem-form/latest.json
dir=$(fixture); file="$dir/save-aem-form/latest.json"; printf '%s' "$(cat "$file")" >"$file.tmp" && mv "$file.tmp" "$file"
expect_fail "rejects a missing trailing newline" "$dir" save-aem-form/latest.json

# 8. Unknown app folders and the retired root manifest.
dir=$(fixture); mkdir "$dir/new-app" && cp "$dir/save-aem-form/latest.json" "$dir/new-app/"
expect_fail "rejects an app missing from the table" "$dir" new-app/latest.json
dir=$(fixture); cp "$dir/save-aem-form/latest.json" "$dir/latest.json"
expect_fail "rejects a root latest.json" "$dir" latest.json

# 9. One bad manifest does not hide the others: they still get their "ok" line.
dir=$(fixture); edit "$dir" aem-slingshot '.draft = true'
out=$("$CHECK" "$dir" 2>&1) || true
if [[ "$(grep -c '^ok ' <<<"$out")" == $(( APP_COUNT - 1 )) && "$(grep -c '^::error' <<<"$out")" == 1 ]]; then
  pass "one line per manifest"
else
  fail "one line per manifest: $out"
fi

# 10. Usage errors.
if "$CHECK" "$WORK/a" "$WORK/b" >/dev/null 2>&1; then fail "two arguments accepted"; else pass "rejects extra arguments"; fi
if "$CHECK" "$WORK/does-not-exist" >/dev/null 2>&1; then fail "missing directory accepted"; else pass "rejects a missing directory"; fi

if (( FAILED )); then echo "some tests failed"; exit 1; fi
echo "all tests passed"
