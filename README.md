# ajila-tg-app-updates

Public update manifests for Ajila's apps. The apps' code repositories are private,
so an installed app can't ask the GitHub Releases API whether a newer version
exists (that would need a token, and apps never carry one). Instead, each app's
release CI writes a small JSON file here, and the installed app reads it
anonymously from `raw.githubusercontent.com`.

This repo holds only those manifests, the script that writes them, and the checks
that keep them valid. No app code, no release assets.

## Apps

| App | App id | Code repo (private) | Manifest |
|---|---|---|---|
| Save AEM Form | `save-aem-form` | [`ajilach/ajila-forms-tg-save-form`](https://github.com/ajilach/ajila-forms-tg-save-form) | [`save-aem-form/latest.json`](https://raw.githubusercontent.com/ajilach/ajila-tg-app-updates/main/save-aem-form/latest.json) |
| AEM Slingshot | `aem-slingshot` | [`ajilach/ajila-tg-dockerized-aem`](https://github.com/ajilach/ajila-tg-dockerized-aem) | [`aem-slingshot/latest.json`](https://raw.githubusercontent.com/ajilach/ajila-tg-app-updates/main/aem-slingshot/latest.json) |
| AEM Translation Editor | `aem-translation-editor` | [`ajilach/ajila-aem-translation-tool`](https://github.com/ajilach/ajila-aem-translation-tool) | [`aem-translation-editor/latest.json`](https://raw.githubusercontent.com/ajilach/ajila-tg-app-updates/main/aem-translation-editor/latest.json) |

Apps fetch `https://raw.githubusercontent.com/ajilach/ajila-tg-app-updates/main/<app-id>/latest.json`.

Save AEM Form builds up to 1.3.0 read the former root `latest.json`, which has been
removed, so they no longer see update notices. That was accepted when the per-app
layout was introduced.

## Manifest format

The manifest mirrors the GitHub release object, so a decoder for the Releases API's
`releases/latest` works unchanged:

```json
{
  "tag_name": "v1.4.0",
  "name": "Save AEM Form 1.4.0",
  "html_url": "https://github.com/ajilach/ajila-forms-tg-save-form/releases/tag/v1.4.0",
  "published_at": "2026-10-12T09:30:00Z",
  "draft": false,
  "prerelease": false
}
```

Invariants, enforced by [`scripts/check-manifests.sh`](scripts/check-manifests.sh) on
every push to `main` and every pull request:

- Exactly these six keys, in this order, formatted like `jq`'s output (2-space
  indent, trailing newline).
- `tag_name` is a plain `vX.Y.Z`.
- `html_url` is exactly `https://github.com/<code repo>/releases/tag/<tag_name>`.
- `draft` and `prerelease` are always `false`; prereleases are never announced.
- `published_at` is the release's publish time in UTC (`YYYY-MM-DDTHH:MM:SSZ`);
  `name` is the release's title.
- Every folder with a `latest.json` is an app in the table above, every app in the
  table has its manifest (unless it is marked `unreleased`; see
  [Adding an app](#adding-an-app)), and there is no root `latest.json`.

raw.githubusercontent.com serves the file as `text/plain` with
`cache-control: max-age=300` (up to 5 minutes stale) and
`access-control-allow-origin: *`.

`html_url` points at the private release page: it opens only for people signed in
to GitHub with access to that code repo. That is true for every current user of
these apps, whose install docs already send them there.

## Client contract

Every app implements the same behavior:

1. **Fetch** the manifest URL with a plain, unauthenticated GET; never a token.
   Webviews send no custom headers at all (raw.githubusercontent.com answers a CORS
   preflight with 403). Native apps may set `User-Agent: <App>/<version>`, bypass the
   local cache, and time out after about 15 s.
2. **Validate**: HTTP 200, a JSON object, `tag_name` a strict `vX.Y.Z` (leading `v`/`V`
   stripped for comparison), `draft`/`prerelease` not true, and `html_url` starting
   with `https://github.com/ajilach/<own code repo>/releases/`. Anything else means
   "no information": silent in the background, "Couldn't check…" on a manual check.
3. **Compare** numerically per component with zero padding (1.10.0 > 1.9.0;
   1.2 == 1.2.0). Offer only a strictly newer version. An unparseable running
   version never prompts.
4. **Cadence**: with automatic checks on, check at launch and on a periodic tick
   (e.g. hourly) whenever a check is due: no successful check yet, or the last
   successful one is at least 24 h old. Record the time only after a successful
   fetch and parse, so an offline check is retried on the next tick or launch.
5. **Notify** non-destructively about a discovered update unless the user skipped
   that exact version (compared numerically, as in 3): **View Release** (opens
   `html_url` in the browser), **Remind Me Later** (dismiss; offered again at the
   next due check or launch), **Skip This Version** (remembers the version). While
   an update is known, keep a low-key indicator (status-menu item, banner or
   status-bar pill) so "Later" isn't lost.
6. **Manual check** ("Check for Updates…" / "Check Now") ignores the 24 h throttle
   and the skipped version, distinguishes "You're up to date (vX)", "Version Y is
   available" and "Couldn't check for updates (reason)", and, if it succeeds,
   counts as the last successful check.
7. **Opt-out**: "Check for updates automatically", on by default. Turning it back on
   triggers a check. Manual checks always work.
8. **Never check** from unit tests, UI snapshot or smoke-test modes, or dev/preview
   builds without a real release version.
9. **Honest privacy copy** wherever the app claims to work offline or send nothing,
   e.g. "Once a day, <App> downloads a small public file from GitHub to see whether
   a newer version exists. Nothing about you or your work is sent; GitHub sees only
   your IP address and the app version." (Webview apps: "…your IP address.")
10. **Never download or install** anything; users update from the release page.

## Publishing

Each app's tag-triggered release workflow publishes its manifest in a separate job
that runs only after the release exists and every asset is attached, so no app is
told about an incomplete release. Nobody publishes from a laptop.

```yaml
  publish-update-manifest:
    name: Publish update manifest
    needs: <the release/build job(s)>
    runs-on: ubuntu-latest
    timeout-minutes: 10
    permissions:
      contents: read                      # only to read this repo's release with github.token
    env:
      TAG: <the same tag expression the release job uses>
      HAS_TOKEN: ${{ (secrets.APP_UPDATES_TOKEN || secrets.ACCESS_TOKEN) != '' }}
    steps:
      - name: Check the publishing token
        if: env.HAS_TOKEN != 'true'
        run: |
          echo "::error::Neither APP_UPDATES_TOKEN nor the org secret ACCESS_TOKEN is available; cannot publish the update manifest."
          exit 1
      - name: Check out this repository
        uses: actions/checkout@<the pin/version this repo already uses>
        with:
          ref: ${{ env.TAG }}                # or the same ref the release job checks out
          persist-credentials: false
      - name: Check out the update manifests
        uses: actions/checkout@<same>
        with:
          repository: ajilach/ajila-tg-app-updates
          ref: main
          path: .app-updates
          token: ${{ secrets.APP_UPDATES_TOKEN || secrets.ACCESS_TOKEN }}
      - name: Publish <app-id>/latest.json
        env:
          GH_TOKEN: ${{ github.token }}
        run: scripts/publish-update-manifest.sh .app-updates <app-id> "$TAG"
```

- `github.token` only reads the app's own release. Pushing here uses
  `secrets.APP_UPDATES_TOKEN || secrets.ACCESS_TOKEN`; today that is the org secret
  `ACCESS_TOKEN`, which every app repo in the table already receives.
- To narrow it, create a fine-grained personal access token with resource owner
  `ajilach`, repository access to this repo only, and **Contents: read and write**
  (the org may have to approve it; a dedicated machine account keeps it from
  depending on one person), and store it as `APP_UPDATES_TOKEN` (an org secret for
  the app repos, or a secret in each). It takes precedence automatically; no YAML
  change is needed. Mind its expiry date.
  A GitHub App would work too, but its installation tokens expire after an hour, so
  each job would need an extra step that mints one.
- Pass tags and other untrusted values through `env:`, never `${{ }}` inside `run:`.

[`scripts/publish-update-manifest.sh`](scripts/publish-update-manifest.sh) is a
drop-in: each app repo has a byte-identical copy at `scripts/publish-update-manifest.sh`.
Edit it here and copy it over (`cmp` the copies to confirm). Its rules:

- Only plain `vX.Y.Z` tags are announced. Other tags (`v1.4.0-rc.1`), drafts and
  prereleases are skipped with a `::notice::`.
- The release data must match the tag and the repo
  (`https://github.com/<repo>/releases/tag/<tag>`).
- A manifest never moves backwards: an older tag changes nothing, and re-running the
  same tag is a no-op.
- Each app writes only its own file, rebuilt on the newest `origin/main` before every
  push. A rejected push is retried (5 attempts with backoff), so concurrent releases
  of different apps all land.
- Anything else that stops the publish fails the job with `::error::`; an
  announcement never silently goes missing.

## Verify a publish

The release job's summary names the tag it published, and the "Check manifests"
workflow runs on the new commit. To read the file itself:

```sh
gh api repos/ajilach/ajila-tg-app-updates/contents/<app-id>/latest.json --jq .content | base64 -d
```

or open its raw URL (CDN-cached for up to 5 minutes, so it can lag behind `main`).

## Withhold or roll back

Edit `<app-id>/latest.json` by hand so it describes the release that should be
offered (all six fields, matching that release), run `scripts/check-manifests.sh`,
and commit to `main`. CI only ever moves a manifest forward, so the rollback stays
until a release newer than the one in the file is published. Re-running the
withdrawn release's publish job counts too, and would announce it again.

## Adding an app

1. Pick an app id (lowercase letters, digits, dashes); it is the manifest's folder.
2. Add a row to `APPS` in [`scripts/check-manifests.sh`](scripts/check-manifests.sh),
   marked `unreleased` (third column), and to the app table above.
3. Copy [`scripts/publish-update-manifest.sh`](scripts/publish-update-manifest.sh) to
   the app repo's `scripts/` (byte-identical, executable).
4. Add the publish job above to the app's release workflow, after every job that
   creates the release or attaches assets. The first release creates
   `<app-id>/latest.json`; then remove the `unreleased` marker (the check prints a
   notice until you do), so a deleted manifest fails CI from then on.
5. Implement the client contract in the app.

## Testing locally

```sh
tests/publish-update-manifest.test.sh   # the publisher, against a throwaway local repo
tests/check-manifests.test.sh           # the manifest check, against fixture folders
scripts/check-manifests.sh              # the manifests in this checkout
```

CI ([`.github/workflows/check.yml`](.github/workflows/check.yml)) runs the same
three, after `bash -n` on every script.

To dry-run the publisher against a real release, use a throwaway clone: the
publisher hard-resets its checkout to `origin/main`.

```sh
git clone --quiet https://github.com/ajilach/ajila-tg-app-updates.git /tmp/app-updates
GITHUB_REPOSITORY=ajilach/ajila-forms-tg-save-form \
  scripts/publish-update-manifest.sh --dry-run /tmp/app-updates save-aem-form v1.3.0
```

It reads the release with your `gh` login and pushes nothing. It prints the manifest
it would write, or, if the file already announces that tag (as it does for the
current release), says there is nothing to publish.

## Recommended hardening

Not applied yet: a branch ruleset on `main` that blocks force pushes and deletion,
so no manifest's history can be rewritten. Don't require pull requests or status
checks there; the release jobs push to `main` directly.
