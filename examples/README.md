# Examples

Static examples of what a project provides. Nothing here is executed by the
pipelines: copy the pieces you need into your repository and own them.

## What to copy

1. `.github/modules.json` — the registry:

```json
{
  "shared": [".github/", ".project/", "Makefile", "compose.yml"],
  "modules": {
    "<module>": {
      "code": { "dir": "modules/<module>/code" },
      "infra": { "dir": "modules/<module>/infra" }
    }
  }
}
```

The default directories are `modules/<module>/code` and
`modules/<module>/infra`, so the `code` and `infra` keys may be omitted. The
registry carries no environment and no url: the url of a deploy comes from the
`glide` hook.

Module names are arbitrary, but they become output keys and tag prefixes, so use
letters, digits, `_` and `-`. The committed fixture in `tests/detect/run.sh`
names its modules `ruby_app_example` and `go_app_example` only to show that a
name carries no language — same pipelines, same scripts, two runtimes. This
README and the example registries use `<module>`/`main` for brevity.

2. `infra/ci/*.sh` into `modules/<module>/infra/ci/`, executable or not — the
   hook runs them with `sh`:

| script | step | when |
|---|---|---|
| `check.sh` | `check` | checks on push/PR, read-only |
| `prepare.sh` | `prepare` | the read-only gate on PR/main; never in the rollout |
| `apply.sh` | `apply` | make the infrastructure match the release |
| `fly.sh` | `fly` | deploy the release; never touches infrastructure |
| `glide.sh` | `glide` | verify the environment as it runs |
| `rollback.sh` | `rollback` | return to the point `fly.sh` wrote |

`pre-apply.sh` and `post-apply.sh` are optional: `apply.sh` runs them around the
apply when they exist.

3. `code/ci/*.sh` into `modules/<module>/code/ci/`: one script per check
   (`lint`, `test`, ...), plus `build.sh` when the module publishes an image.

4. `setup-action.yml` into `.github/actions/setup/action.yml` — the project owns
   the toolchain and the authentication. The pipeline calls it after checkout
   with `dir`, `environment` and `runtime-config`.

## Scripts

Every script runs with its directory as the working directory — the module's
`code/` or `infra/` directory — and is parametrized by environment variables the
project exports before the step (typically from `RUNTIME_CONFIG` in its setup
action). The examples use these names:

| variable | used by | meaning |
|---|---|---|
| `TAG` | apply, fly | release tag, `<module>.YYYY.MM.DD.N` |
| `PREFIX` | gcp-cloudrun | service / resource prefix |
| `IMAGE` | both | target image, without the tag |
| `SOURCE_IMAGE` | gcp-cloudrun | image to promote by digest |
| `TF_DIR` | gcp-cloudrun | terraform root inside `infra/` |
| `TF_BUCKET`, `TF_STATE_PREFIX` | gcp-cloudrun | state backend |
| `TF_VARS` | gcp-cloudrun | JSON object of terraform variables |
| `OVERLAY`, `NAMESPACE`, `DEPLOYMENT` | k8s | kustomize overlay and rollout target |
| `URL`, `HEALTH`, `ENVIRONMENT`, `REGION` | both | environment URL, health path, environment name, region |

Two outputs cross the pipeline boundary through `$GITHUB_OUTPUT`:

- `fly` writes `rollback=<point>`; the deploy hands it to `rollback` as
  `ROLLBACK_POINT`. A `rollback` script must fail when that value is empty —
  there is nothing to return to.
- `glide` writes `url=<url>`; `land` records it and `notify` prints it.

`apply` may print "nothing to apply" and exit 0. `prepare` never mutates:
it only shows what the rollout would apply, and it gates the tag on PR/main.

## Available examples

| directory | stack |
|---|---|
| `gcp-cloudrun/` | terraform + Cloud Run services, image promotion by digest, migration job |
| `k8s/` | kustomize overlays, `kubectl diff`, `rollout undo` |
