#!/usr/bin/env bash
#
# Tests for scripts/publish-update-manifest.sh against a throwaway bare repo.
# No network: release data comes from PUBLISH_RELEASE_JSON.
#
# Usage: tests/publish-update-manifest.test.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PUBLISH="$ROOT/scripts/publish-update-manifest.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export GITHUB_REPOSITORY="ajilach/example-app"
export PUBLISH_BACKOFF_SECONDS=0
unset GITHUB_STEP_SUMMARY
FAILED=0

pass() { echo "ok   - $*"; }
fail() { echo "FAIL - $*"; FAILED=1; }

# release_json <tag> [isDraft] [isPrerelease] [url]
release_json() {
  local tag=$1 draft=${2:-false} pre=${3:-false}
  local url=${4:-https://github.com/$GITHUB_REPOSITORY/releases/tag/$tag}
  jq -n --arg t "$tag" --arg u "$url" --argjson d "$draft" --argjson p "$pre" \
    '{tagName: $t, name: ("Example " + ($t | ltrimstr("v"))), url: $u,
      publishedAt: "2026-10-11T12:00:00Z", isDraft: $d, isPrerelease: $p}'
}

# publish <tag> [release json] — runs the script in the "ci" clone; prints its output.
publish() {
  local tag=$1 json=${2:-}
  [[ -n "$json" ]] || json=$(release_json "$tag")
  PUBLISH_RELEASE_JSON="$json" "$PUBLISH" "$WORK/ci" example-app "$tag" 2>&1
}

remote_tag() { git --git-dir="$WORK/origin.git" show "main:example-app/latest.json" 2>/dev/null | jq -r .tag_name; }
remote_commits() { git --git-dir="$WORK/origin.git" rev-list --count main; }

# --- Fixture: a bare "origin" with one commit on main, and the job's clone --------------
git init --quiet --bare --initial-branch=main "$WORK/origin.git"
git clone --quiet "$WORK/origin.git" "$WORK/seed" 2>/dev/null
(
  cd "$WORK/seed"
  git config user.name test && git config user.email test@example.com
  mkdir other-app
  echo '{"tag_name":"v9.9.9"}' >other-app/latest.json
  echo "# updates" >README.md
  git add . && git commit --quiet -m seed && git push --quiet origin HEAD:main
)
git clone --quiet "$WORK/origin.git" "$WORK/ci"

# 1. First publish writes the manifest in the agreed shape.
out=$(publish v1.2.0)
if [[ "$(remote_tag)" == "v1.2.0" ]]; then pass "first publish"; else fail "first publish: $out"; fi
expected=$(jq -n '{tag_name: "v1.2.0", name: "Example 1.2.0",
  html_url: "https://github.com/ajilach/example-app/releases/tag/v1.2.0",
  published_at: "2026-10-11T12:00:00Z", draft: false, prerelease: false}')
actual=$(git --git-dir="$WORK/origin.git" show main:example-app/latest.json)
if [[ "$actual" == "$expected" ]]; then pass "manifest shape and key order"; else fail "manifest shape: $actual"; fi

# 2. Re-running the same tag is a no-op (no new commit).
before=$(remote_commits)
out=$(publish v1.2.0)
if [[ "$(remote_commits)" == "$before" ]]; then pass "idempotent re-run"; else fail "re-run added a commit: $out"; fi

# 3. An older tag never moves the manifest backwards (exit 0, unchanged).
if out=$(publish v1.1.9) && [[ "$(remote_tag)" == "v1.2.0" ]]; then
  pass "no downgrade"
else
  fail "downgrade guard: $out"
fi

# 4. Numeric, not lexical, ordering: v1.10.0 > v1.9.0 > v1.2.0.
publish v1.9.0 >/dev/null && publish v1.10.0 >/dev/null
if [[ "$(remote_tag)" == "v1.10.0" ]]; then pass "numeric version ordering"; else fail "ordering: $(remote_tag)"; fi

# 5. Prerelease-looking tags, draft releases and prerelease releases are skipped (exit 0).
before=$(remote_commits)
publish v2.0.0-rc.1 >/dev/null \
  && publish v2.0.0 "$(release_json v2.0.0 true false)" >/dev/null \
  && publish v2.0.0 "$(release_json v2.0.0 false true)" >/dev/null
if [[ "$(remote_commits)" == "$before" && "$(remote_tag)" == "v1.10.0" ]]; then
  pass "skips prerelease tags, drafts and prereleases"
else
  fail "skip rules"
fi

# 6. Bad release data fails loudly (exit 1).
if publish v2.0.0 "$(release_json v2.0.0 false false https://evil.example/x)" >/dev/null; then
  fail "foreign release URL accepted"
else
  pass "rejects a release URL outside the released repo"
fi
if publish v2.0.0 "$(release_json v2.0.1)" >/dev/null; then fail "tag mismatch accepted"; else pass "rejects release data for another tag"; fi
if publish v2.0.0 "not json" >/dev/null; then fail "garbage accepted"; else pass "rejects non-JSON release data"; fi
if PUBLISH_RELEASE_JSON="$(release_json v2.0.0)" "$PUBLISH" "$WORK/ci" Bad_App v2.0.0 >/dev/null 2>&1; then
  fail "bad app id accepted"
else
  pass "rejects a malformed app id"
fi

# 7. --dry-run prints the manifest and pushes nothing.
before=$(remote_commits)
out=$(PUBLISH_RELEASE_JSON="$(release_json v2.0.0)" "$PUBLISH" --dry-run "$WORK/ci" example-app v2.0.0 2>&1)
if [[ "$(remote_commits)" == "$before" && "$out" == *'"tag_name": "v2.0.0"'* ]]; then
  pass "dry run"
else
  fail "dry run: $out"
fi

# 8. A concurrent publish by another app between fetch and push: the rejected push is
#    retried on the newest main, and both changes survive.
git clone --quiet "$WORK/origin.git" "$WORK/other"
git -C "$WORK/other" config user.name other && git -C "$WORK/other" config user.email other@example.com
cat >"$WORK/ci/.git/hooks/pre-push" <<HOOK
#!/usr/bin/env bash
# Fires once: lands another app's release on origin just before our push.
[[ -e "$WORK/raced" ]] && exit 0
touch "$WORK/raced"
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX
cd "$WORK/other" && git pull --quiet origin main
mkdir -p third-app && echo '{"tag_name":"v0.1.0"}' >third-app/latest.json
git add third-app && git commit --quiet -m "third-app v0.1.0" && git push --quiet origin HEAD:main
HOOK
chmod +x "$WORK/ci/.git/hooks/pre-push"
out=$(publish v2.0.0)
third=$(git --git-dir="$WORK/origin.git" show main:third-app/latest.json 2>/dev/null | jq -r .tag_name)
if [[ -e "$WORK/raced" && "$(remote_tag)" == "v2.0.0" && "$third" == "v0.1.0" ]]; then
  pass "concurrent publish retried on the newest main"
else
  fail "race: tag=$(remote_tag) third=$third out=$out"
fi
rm -f "$WORK/ci/.git/hooks/pre-push"

# 9. Other apps' manifests are never touched.
other=$(git --git-dir="$WORK/origin.git" show main:other-app/latest.json | jq -r .tag_name)
if [[ "$other" == "v9.9.9" ]]; then pass "other apps untouched"; else fail "other app changed: $other"; fi

# 10. A push that keeps failing ends in a loud error, not silence.
git -C "$WORK/ci" remote set-url --push origin "$WORK/does-not-exist.git"
if out=$(publish v2.1.0); then fail "unpushable publish reported success: $out"; else pass "fails loudly when it cannot push"; fi

if (( FAILED )); then echo "some tests failed"; exit 1; fi
echo "all tests passed"
