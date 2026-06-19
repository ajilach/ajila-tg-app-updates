# SaveAEMForm-updates

Public version manifest for [Save AEM Form](https://github.com/ajilach/SaveAEMForm),
whose code repository is private.

The app reads [`latest.json`](latest.json) at launch (via
`https://raw.githubusercontent.com/ajilach/SaveAEMForm-updates/main/latest.json`) to
detect newer versions. It mirrors the GitHub release shape:

```json
{
  "tag_name": "v1.1",
  "html_url": "https://github.com/ajilach/SaveAEMForm/releases/tag/v1.1"
}
```

`latest.json` is published automatically by `scripts/release.sh` in the main project
(`UPDATE_MANIFEST_DIR` pointing at a checkout of this repo). No need to edit it by hand.
