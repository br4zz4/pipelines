# Examples

Static examples of what a project provides. Nothing here is executed by the
pipelines: copy the pieces you need into your repository and own them. All four
use the same vocabulary of hooks; only what the scripts call differs.

| directory | stack |
|---|---|
| `gcp-cloudrun/` | terraform + Cloud Run services, image promotion by digest, migration job |
| `k8s/` | kustomize overlays, `kubectl diff`, `rollout undo` |
| `heroku/` | container registry, `pipelines:promote` to production, `releases:rollback` |
| `aws-ecs/` | ECR + ECS Fargate, task definition per release, `wait services-stable` |

## What to copy

1. `modules.json` into `.github/modules.json` — the registry:

```json
{
  "shared": [".github/", ".ward/", "Makefile"],
  "modules": {
    "<module>": { "services": ["postgres"] }
  }
}
```

`services` is optional and a subset of `postgres` and `redis`. The default
directories are `modules/<module>/code` and `modules/<module>/infra`; a module
that keeps them elsewhere declares `code.dir` / `infra.dir`. Module names match
`[a-z][a-z0-9_]*`. The workflows are **not** copied: the conform job of the
first pull request generates `pr.yml`, `main.yml` and `deploy.yml` from this
file.

2. `code/ci/checks/*.sh` into `modules/<module>/code/ci/checks/`,
   `infra/ci/checks/*.sh` into `modules/<module>/infra/ci/checks/`, and
   `infra/ci/deploy/*.sh` into `modules/<module>/infra/ci/deploy/`.
   The vocabulary is closed and every hook is mandatory; a module with nothing
   to do keeps a script that prints why and exits 0:

| side | context | hook | job (GitHub UI) | what it does |
|---|---|---|---|---|
| code | `checks` | `lint`, `audit`, `test` | `<module> / code / lint`, `… / audit`, `… / test` | read-only gates; run with the `test` ward environment |
| code | `checks` | `build` | `<module> / code / build` | the image of the release; only `main` builds |
| infra | `checks` | `validate` | `<module> / infra / validate` | format and validate, no credentials |
| infra | `checks` | `plan` | `<module> / infra / plan` | what the release would change in the real environment; read-only |
| infra | `deploy` | `apply` | `deploy / apply` | make the infrastructure match the release; "nothing to apply" is valid |
| infra | `deploy` | `deployment` | `deploy / deployment` | release the image; writes `rollback=<point>`; never touches infrastructure |
| infra | `deploy` | `verify` | `deploy / verify` | check the environment as it runs; writes `url=<url>` |
| infra | `deploy` | `rollback` | `deploy / rollback` | return to `ROLLBACK_POINT`; fails when it is empty |

   These examples cover the platform side (infra hooks and `build`). The language
   hooks (`lint`, `audit`, `test`) live with the language: see `examples/polyglot` in
   `br4zz4/commons` for ruby, go and elixir, and use `make <module>.<step>` from there to run them locally.

   Anything else in `ci/checks/` or `ci/deploy/` is rejected by conform. A helper
   a hook needs belongs next to it, outside `ci/` (for example `lib/`).

3. `code/mise.toml` and `infra/mise.toml` into the same directories: the
   toolchain of each side. The pipeline runs `mise` there, so it never knows a
   language.

4. `setup-action.yml` into `.github/actions/setup/action.yml` — the project owns
   the authentication only. It reads the credentials the ward scope exported.

## Scripts

Every script runs with its own side directory as the working directory and is
parametrized by environment variables. The pipeline sets `MODULE`,
`ENVIRONMENT` and (in deploy) `TAG`; the rest comes from the ward scope
`secrets.<module>.<code|infra>.<environment>` and `secrets.ci.<environment>`
(production reads the restricted vault).

| variable | used by | meaning |
|---|---|---|
| `MODULE`, `ENVIRONMENT`, `TAG`, `CI_CACHE_DIR` | all | set by the pipeline |
| `PREFIX`, `SOURCE_IMAGE`, `TF_DIR`, `TF_BUCKET`, `TF_STATE_PREFIX`, `TF_VARS` | gcp-cloudrun | service prefix, image to promote, terraform root, state backend and variables |
| `WIF_PROVIDER`, `DEPLOY_SA` | gcp-cloudrun setup | workload identity |
| `OVERLAY`, `NAMESPACE`, `DEPLOYMENT`, `KUBE_CONFIG` | k8s | kustomize overlay, rollout target, base64 kubeconfig |
| `HEROKU_APP`, `SOURCE_APP`, `HEROKU_CONFIG`, `HEROKU_API_KEY` | heroku | app, staging app to promote from, config vars (JSON), credential |
| `CLUSTER`, `SERVICE`, `CONTAINER`, `IMAGE`, `TF_STATE_KEY`, `ROLE_ARN`, `AWS_REGION` | aws-ecs | ECS target, image, state key, role and region |
| `URL`, `HEALTH`, `RETRIES`, `DELAY` | all `verify` | environment URL, health path, retry budget |

## Caching

The pipeline restores `<dir>/.ci-cache` before the hook and saves it after, keyed
by `mise.toml` and all lockfiles of the side. The scope is the module side
(`<module>-code-…` or `<module>-infra-…`), so `lint`, `audit` and `test` share the
same cache. A `restore-keys` fallback allows partial hits when lockfiles change.

**Dependency managers** — point the manager's install path at `$CI_CACHE_DIR`:
```sh
# Ruby
export BUNDLE_PATH="${CI_CACHE_DIR}/bundle"
exec bundle exec rake test

# Node (npm)
export NPM_CONFIG_CACHE="${CI_CACHE_DIR}/npm"
exec npm test
```

**Docker builds** — use the GitHub Actions BuildKit cache backend so layers
survive across runs without a registry-side cache mount:
```sh
docker buildx build \
  --tag "${IMAGE}:${TAG}" \
  --cache-from "type=gha,scope=${MODULE}" \
  --cache-to   "type=gha,scope=${MODULE},mode=max" \
  --push \
  .
```

`scope` isolates each module's layer cache. `mode=max` exports all layers, not
just the final stage. `--mount=type=cache` in the Dockerfile is a local daemon
cache: effective on a laptop, useless on ephemeral GitHub Actions runners.

Two outputs cross the pipeline boundary through `$GITHUB_OUTPUT`:

- `deployment` writes `rollback=<point>`; the pipeline hands it to `rollback` as
  `ROLLBACK_POINT`. A `rollback` script must fail when that value is empty —
  there is nothing to return to.
- `verify` writes `url=<url>`; `record` stores it and `notify` prints it.

`apply` may print "nothing to apply" and exit 0. `plan` never mutates: it only
shows what the deploy would change, and it is a pull-request gate.
