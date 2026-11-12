# Examples

Static examples of what a project provides. Nothing here is executed by the
pipelines: copy the pieces you need into your repository and own them.

## What to copy

1. `.github/modules.json` — the minimal registry:

```json
{
  "shared": [".github/", ".project/", "Makefile", "compose.yml"],
  "modules": {
    "<module>": {
      "code": { "dir": "modules/<module>/code" },
      "deploy": { "dir": "modules/<module>/deploy" },
      "environments": {
        "staging": { "url": "https://staging.example.com" },
        "production": { "url": "https://example.com" }
      }
    }
  }
}
```

The default directories are `modules/<module>/code` and
`modules/<module>/deploy`, so the `code` and `deploy` keys may be omitted. Each
environment only needs its `url`.

2. `deploy/ci/{check,plan,fly,glide,rollback}.sh` into
   `modules/<module>/deploy/ci/`, executable or not — the hook runs them with
   `sh`. `check` and `plan` are the infra subtrack; `fly`, `glide` and
   `rollback` are the deploy track.

3. `code/ci/*.sh` into `modules/<module>/code/ci/`: one script per step
   (`lint`, `test`, ...), plus `package.sh` when the module publishes an image.

4. `setup-action.yml` into `.github/actions/setup/action.yml` — the project owns
   the toolchain and the authentication. The pipeline calls it after checkout
   with `dir`, `environment` and `runtime-config`.

## Scripts

Every script runs with the subtrack directory as the working directory — the
module's `code/` or `deploy/` directory — and is parametrized by environment
variables the project exports before the step (typically from `RUNTIME_CONFIG`
in its setup action). The examples use these names:

| variable | used by | meaning |
|---|---|---|
| `TAG` | fly | release tag |
| `PREFIX` | gcp-cloudrun | service / resource prefix |
| `IMAGE` | both | target image, without the tag |
| `SOURCE_IMAGE` | gcp-cloudrun | image to promote by digest |
| `TF_DIR` | gcp-cloudrun | terraform root inside `deploy/` |
| `TF_BUCKET`, `TF_STATE_PREFIX` | gcp-cloudrun | state backend |
| `TF_VARS` | gcp-cloudrun | JSON object of terraform variables |
| `OVERLAY`, `NAMESPACE`, `DEPLOYMENT` | k8s | kustomize overlay and rollout target |
| `URL`, `HEALTH`, `ENVIRONMENT`, `REGION` | both | environment URL, health path, environment name, region |

`fly` writes its rollback point to `$GITHUB_OUTPUT` as `rollback=<point>`; the
track hands it to `rollback` as `ROLLBACK_POINT`. A `rollback` script must fail
when that value is empty — there is nothing to return to.

## Available examples

| directory | stack |
|---|---|
| `gcp-cloudrun/` | terraform + Cloud Run services, image promotion by digest, migration job |
| `k8s/` | kustomize overlays, `kubectl diff`, `rollout undo` |
