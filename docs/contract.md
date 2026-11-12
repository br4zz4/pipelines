# Contract

What a repository must provide for `br4zz4/pipelines@v1` to run it. Everything
here is convention plus one file: `.github/modules.json`.

## Registry — `.github/modules.json`

```json
{
  "region": "us-west1",
  "shared": [".github/", "tasks/", ".project/", "Makefile", "compose.yml"],
  "modules": {
    "main": {
      "code": {
        "dir": "modules/main/code",
        "package": { "context": "modules/main/code", "target": "web" }
      },
      "infra": {
        "dir": "modules/main/deploy/terraform/gcp/envs/{env}",
        "check_dir": "modules/main/deploy/terraform",
        "state": {
          "bucket": "has-warranty-tfstate-{env}",
          "prefix": "has-warranty/terraform.tfstate"
        },
        "vars": { "web_image_tag": "{tag}", "migrate_image_tag": "{tag}" }
      },
      "environments": {
        "staging": {
          "project": "has-warranty-staging",
          "repository": "has-warranty-staging",
          "prefix": "has-warranty-staging",
          "url": "https://staging.tenhoessanota.com.br"
        },
        "production": {
          "project": "has-warranty-production",
          "repository": "has-warranty-production",
          "prefix": "has-warranty-production",
          "url": "https://tenhoessanota.com.br",
          "source": "staging"
        }
      }
    }
  }
}
```

| key | meaning |
|---|---|
| `region` | Artifact Registry / Cloud Run region |
| `shared` | paths that touch every track (defaults shown) |
| `modules.<n>.code.dir` | module code directory |
| `modules.<n>.code.package` | presence builds and pushes an image; `context` and `target` feed the docker build |
| `modules.<n>.code.line.migrate` | runs the `<prefix>-migrate` job in the deploy line; `false` for modules without migrations |
| `modules.<n>.code.line.worker` | also deploys `<prefix>-worker`; `false` for a single-service module |
| `modules.<n>.code.line.health` | health path the smoke tests; default `/up` |
| `modules.<n>.code.line.artifacts` | path inside the code dir kept when e2e fails; empty = nothing |
| `modules.<n>.code.paths` | optional; overrides the change-detection root |
| `modules.<n>.infra.dir` | terraform environment directory; `{env}` becomes the environment |
| `modules.<n>.infra.check_dir` | root for `fmt -recursive` and `validate` |
| `modules.<n>.infra.state` | GCS backend; `{env}` becomes the environment |
| `modules.<n>.infra.vars` | terraform variables; `{tag}` becomes the release tag |
| `modules.<n>.environments.<e>.project` | GCP project |
| `modules.<n>.environments.<e>.repository` | Artifact Registry repository |
| `modules.<n>.environments.<e>.prefix` | Cloud Run service prefix (`<prefix>-web`, `<prefix>-worker`, `<prefix>-migrate`) |
| `modules.<n>.environments.<e>.url` | public URL, smoke only (never blocking unless `strict`) |
| `modules.<n>.environments.<e>.source` | environment whose image is promoted into this one; omitted means no promotion |
| `modules.<n>.environments.<e>.image` | optional full image override |

The image path is derived: `{region}-docker.pkg.dev/{project}/{repository}/web`.

A module is a directory under `modules/` with `code/` and/or `deploy/`. A facet
without a matching key in the registry does not exist as a track.

## Steps

`<facet_dir>/ci/<step>.sh` **is** the step. `chmod +x` is not required and not
trusted; scripts run with `sh` when they are not executable.

| facet | steps the pipeline looks up |
|---|---|
| code | whatever exists in `code/ci/`; `e2e` runs after a deploy |
| infra | generic, no scripts needed: `check`, `plan`, `apply` |

### Toolchain — `.github/actions/setup`

Installing the toolchain is the one thing a shell script does badly, so it is a
project-owned **composite action** at a fixed path. The pipeline calls it after
checkout, before any step, and skips it when the file is absent:

```yaml
      - name: Set up the module
        if: hashFiles('.github/actions/setup/action.yml') != ''
        uses: ./.github/actions/setup
        with:
          dir: ${{ inputs.code_dir }}
```

```yaml
# .github/actions/setup/action.yml
name: setup
description: Toolchain for one module
inputs:
  dir: { required: true }
runs:
  using: composite
  steps:
    - uses: ruby/setup-ruby@v1
      with:
        working-directory: ${{ inputs.dir }}
        bundler-cache: true
```

`./` resolves against the **caller's workspace**, which is exactly the project,
so this one path works from every pipeline (checks and deploy).

A project overrides a generic infra/deploy step by creating
`modules/<name>/deploy/ci/<step>.sh` — `snapshot`, `promote`, `migrate`,
`services`, `smoke`, `verify`, `record`, `rollback`, `terraform`. The action
runs it instead of its default. The signature is the same positional arguments
the default receives (see each `action.yml`).

## Tags

Release tags are sequential per day, readable, and annotated:

```
v2026.11.12.10
tracks: main/code,checkout/code,checkout/infra
```

- The day is `America/Sao_Paulo`; `N` is the day's release count plus one, read
  as a number (`.10` after `.9`).
- The tag names the image: `IMAGE:<tag>` is pushed by `main.yml` and promoted
  byte for byte into production.
- A lightweight tag with no message means "every track", so releases created
  before this contract keep working.
- Legacy `vYYYY.MM.DD-<sha>` tags are still accepted by `verify`.

## Secrets

Passed explicitly, never inherited. Staging and production get separate values;
the caller decides which credentials each environment uses, so the pipeline only
ever sees these names:

| secret | used by |
|---|---|
| `GCP_WIF_PROVIDER` / `GCP_DEPLOY_SA` | target environment: build, plan, apply, deploy |
| `GCP_SOURCE_WIF_PROVIDER` / `GCP_SOURCE_DEPLOY_SA` | source environment (image promotion) |
| `GH_TAG_TOKEN` | `main.yml` — a PAT with the `workflow` scope; a `GITHUB_TOKEN` push does not trigger workflows |
| `NOTIFY_WEBHOOK_URL` | optional; Slack-compatible payload, failure never reverts a deploy |

`GITHUB_TOKEN` permissions are declared by the entrypoints:
`contents: write` on main (tag push), `id-token: write` wherever GCP is
authenticated, `deployments: write` on deploy.

## A module in any language

Steps are scripts and the toolchain is the project's composite action — nothing
in the pipeline knows Ruby. A Go module has the same shape:

```json
"payments": {
  "code": {
    "dir": "modules/payments/code",
    "package": { "context": "modules/payments/code" },
    "line": { "migrate": false, "worker": true, "health": "/healthz", "artifacts": "" }
  },
  "infra": { "dir": "modules/payments/deploy/terraform/envs/{env}", "state": {}, "vars": {} },
  "environments": { "staging": {}, "production": { "source": "staging" } }
}
```

```sh
# modules/payments/code/ci/test.sh
set -eu
go test ./...

# modules/payments/code/ci/lint.sh
set -eu
golangci-lint run
```

`.github/actions/setup` installs whichever toolchain the `dir` needs:

```yaml
    - name: Set up Go
      if: hashFiles(format('{0}/go.mod', inputs.dir)) != ''
      uses: actions/setup-go@v5
      with:
        go-version-file: ${{ inputs.dir }}/go.mod
        cache-dependency-path: ${{ inputs.dir }}/go.sum
```

The `step` job always runs a Postgres service: it is a default, not a language
assumption. A module that does not use it simply does not read `DATABASE_URL`.
The one fixed assumption is Cloud Run/GCP, overridable per step via
`modules/<name>/deploy/ci/<step>.sh`.

## Ordering and failure

```
deploy: plan ─► per module: infra ─► code ─┬─ smoke ────┐
                                           └─ e2e ──────┴─ record ─► notify
                                                        └─ rollback
```

- `infra` runs before `code` for a module, and a failure there stops that
  module's code deploy — never promote code on top of half-applied infra.
- Modules are independent: `fail-fast: false`, one broken track does not cancel
  the others.
- `smoke` and `e2e` run in parallel; `record` requires both; `rollback` only on
  failure and only when there is a previous revision to return to.
- Migrations are **not** reverted. They must be expand/contract.

## Edge cases

| situation | behavior |
|---|---|
| push touching only docs | no tag, no build, no deploy |
| push touching only `main/deploy/**` | tag `tracks: main/infra` — terraform applies, no image is promoted |
| push touching only `main/code/**` | tag `tracks: main/code` — checkout does not appear in the deploy |
| `deploy` with an empty tag | resolves the newest release recorded green in that environment |
| `deploy` with `modules: main` | narrows the release to that module; the tag stays the same |
| tag from before this contract | all tracks are considered part of it |
| repository with a single module | the matrix has one leg; nothing else changes |

## Limits

- Nesting: `entrypoint → deploy.yml → module.yml → line.yml` — four levels,
  well under GitHub's limit of ten.
- `jobs.<job_id>.if` accepts only `github, needs, vars, inputs` — never
  `matrix`. Every gate lives in the reusable, on `inputs.changed`.
- Relative `uses:` resolve against the **caller's** repository, so every
  internal reference is absolute: `br4zz4/pipelines/...@v1`. Pin the major tag;
  a project that needs exactness pins a SHA or a minor tag.
- A reusable workflow cannot read `secrets` in a composite action, so actions
  take tokens as inputs.
