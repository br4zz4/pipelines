# Contract

What a repository must provide for `br4zz4/pipelines@v1` to run it. Everything
here is convention plus one file: `.github/modules.json`.

## Folders

```
modules/<name>/
  code/ci/    one script per code step: lint.sh · test.sh · package.sh
  infra/ci/   one script per infra step: check.sh · infra-prepare.sh
              one script per deploy hook: fly.sh · glide.sh · rollback.sh
```

`modules/<name>/code` and `modules/<name>/infra` are the defaults. A project that
puts them elsewhere declares the directories in the registry; nothing else in
the pipeline assumes a path.

## Registry — `.github/modules.json`

```json
{
  "shared": [".github/", ".project/", "Makefile", "compose.yml"],
  "modules": {
    "<name>": {
      "code": { "dir": "modules/<name>/code" },
      "infra": { "dir": "modules/<name>/infra" }
    }
  }
}
```

| key | meaning |
|---|---|
| `shared` | paths that count for every module and every subtrack |
| `modules.<name>.code.dir` | code directory; default `modules/<name>/code` |
| `modules.<name>.infra.dir` | infra directory; default `modules/<name>/infra` |

Nothing else is read. In particular the registry carries **no environment and no
url**: the url of a deploy comes from the `glide` hook, and the environment is an
input of the workflow.

A module name becomes an output key (`<name>_code`, `<name>_infra`) and a tag
prefix, so it must match `[A-Za-z_][A-Za-z0-9_-]*`. `detect` fails loudly
otherwise instead of writing an invalid output.

## Steps

A script **is** a step: `<dir>/ci/<step>.sh`. No workflow knows the name of a
step in advance; `detect` reads the directory and builds the matrix.

| subtrack | directory | steps |
|---|---|---|
| code | `code.dir` | every `ci/*.sh` except `setup` and `package` |
| infra | `infra.dir` | `check` and `infra-prepare`, when they exist |

`chmod +x` is neither required nor trusted: the hook runs scripts with `sh`
unless they are executable.

The deploy track does not take its steps from a matrix. It calls fixed hooks in
the infra directory:

| hook | job | contract |
|---|---|---|
| `infra/ci/infra-prepare.sh` | `infra-prepare` | read-only: render, plan or diff. Prints "nothing to apply" and exits 0 when there is nothing to do |
| `infra/ci/fly.sh` | `fly` | deploy the release and write `rollback=<point>` to `$GITHUB_OUTPUT` |
| `infra/ci/glide.sh` | `glide` | check the environment as it actually runs and write `url=<url>` to `$GITHUB_OUTPUT` |
| `infra/ci/rollback.sh` | `rollback` | return to `ROLLBACK_POINT`; fail when it is empty |

`fly.sh` may run two optional hooks around its apply:
`infra/ci/pre-apply.sh` and `infra/ci/post-apply.sh`. They exist as a convention,
not as pipeline steps; the example scripts test for them.

## Package

```
requirements ─┬─► build ──────────┐
              └─► infra-prepare ──┴─► deploy (staging)
```

1. **requirements** — the tag must be `<module>.YYYY.MM.DD.N`, exist in git and
   point at the commit of the run. The module is `${TAG%%.*}`.
2. **build** — checkout the tag, project setup with `modules/<module>/code`, run
   the `package` hook.
3. **infra-prepare** — checkout the tag, project setup with
   `modules/<module>/infra`, run the `infra-prepare` hook. It is read-only, so it
   runs in parallel with the build; a plan never waits for an image.
4. **deploy** — `deploy.yml` with the module, the tag and the environment.

## Deploy track

```
requirements ─► fly ─► glide ─┬─► land ─► notify      (success)
                              └─► rollback            (failure)
```

1. **requirements** — with a tag, verify it as in `package`. Without a tag,
   `resolve` first finds the newest release recorded green for the module and the
   job derives the tag and, when empty, the module from it. Production promotes
   what is green in staging; the resolve reads staging records.
2. **fly** — checkout the tag, require it, project setup with
   `modules/<module>/infra`, run the `fly` hook. The job runs in the
   `environment`, so its approvals and protection rules apply. The script writes
   `rollback=<point>`; the job publishes it as `rollback_point`.
3. **glide** — run the `glide` hook against the deployed environment and publish
   its `url` output.
4. **land** — record the release as green with GitHub Deployments, payload
   `{module, tag}`, `environment_url` = the `url` from glide. Promotion reads
   these records, so only a landed release can be promoted.
5. **notify** — write the result to the run summary and, when
   `NOTIFY_WEBHOOK_URL` is set, post it. A failure here never reverts a deploy.
6. **rollback** — runs only when `fly` or `glide` failed. It gets
   `ROLLBACK_POINT` from `fly`'s output. **The module script must fail high when
   the point is empty**: a failed deploy with no previous revision is a manual
   incident, never a silent success. After rolling back, `glide` runs again.

Artifacts: on a glide failure the pipeline uploads
`modules/<module>/code/tmp/artifacts` as
`e2e-<module>-<environment>-<tag>`, and ignores a missing directory. A project
that wants failure evidence (screenshots, logs) writes it there.

The code steps, the glide job and the rollback job carry a `postgres:16-alpine`
service (`postgres`/`postgres`, port 5432, `pg_isready` health check). It is a
default, not a language assumption: a module that does not use it simply ignores
it, and one that does can point at
`postgres://postgres:postgres@localhost:5432`.

## Toolchain and authentication — `.github/actions/setup`

Installing a toolchain and authenticating are the two things a shell script does
badly, so both are a project-owned composite action at a fixed path. The
pipelines call it after checkout, before any step:

```yaml
      - name: Set up the module
        uses: ./.github/actions/setup
        with:
          dir: ${{ inputs.dir }}
          environment: ${{ inputs.environment }}
          runtime-config: ${{ secrets.RUNTIME_CONFIG }}
```

`./` resolves against the **caller's** workspace, which is the project, so the
same path works from every pipeline. The action is the only place credentials
are established; the pipeline itself never authenticates. It is the natural
place to export the variables the scripts read (`TAG`, `URL`, image names,
terraform backend, ...).

## Secrets

Passed explicitly, never inherited. The pipeline only ever sees these names:

| secret | required | meaning |
|---|---|---|
| `RUNTIME_CONFIG` | no | opaque JSON object with the project's per-environment values; the pipeline never parses it, it only forwards it to the setup action |
| `NOTIFY_WEBHOOK_URL` | no | notification endpoint; the notification never reverts a deploy |
| `GH_TAG_TOKEN` | yes, to tag | PAT with the `workflow` scope: a tag pushed with `GITHUB_TOKEN` does not trigger workflows |

Because `RUNTIME_CONFIG` is opaque, a project can change what its setup action
needs without touching the pipelines.

`GITHUB_TOKEN` permissions are declared by the entrypoints: `contents: read` and
`id-token: write` to build and deploy, `contents: write` to tag,
`deployments: write` to land.

## Tags and releases

A release tag belongs to one module and is sequential per day:

```
main.2026.11.12.10
```

- The module is the prefix: `MODULE=${TAG%%.*}`. The tag alone says what to
  build, plan and deploy.
- The day is `America/Sao_Paulo`; `N` is the day's release count of that module
  plus one, read as a number (`.10` after `.9`).
- Tags are annotated; the message is `release <tag>`.
- Legacy `vYYYY.MM.DD.N` and `vYYYY.MM.DD-<sha>` tags are still accepted by
  `requirements`.
- `requirements` rejects a tag whose commit is not the commit of the run: the
  deploy is dispatched from the tag ref.
- `resolve` reads GitHub Deployments, whose payload carries `{module, tag}`. With
  a tag it only validates that the tag is green for the module in that
  environment; without one it returns the newest green tag. Deploying production
  without a tag therefore promotes the newest release that passed in staging.

## Names

Every job and step that appears in a run is named `<context> / <name>`:
`requirements / main`, `build / main`, `infra-prepare / main`, `fly / main`,
`glide / main`, `land / main`, `notify / main`, `rollback / main`, and
`lint / main` for a matrix leg. The context says what is happening; the name says
which module.

## Detection

`detect` reads the event change set:

| event | change set |
|---|---|
| `push` | `EVENT_BEFORE..HEAD`; without a usable before or `HEAD^`, everything |
| `pull_request` | `merge-base(EVENT_BASE or origin/<base>)..HEAD` |
| any other event | everything |

- `modules/<name>/code/**` touches the code subtrack of `<name>`.
- `modules/<name>/infra/**` touches the infra subtrack of `<name>`.
- A `shared` path touches every subtrack of every module.
- Unrelated paths (docs, for example) touch nothing: no tag, no build, no deploy.

### Outputs

| output | meaning |
|---|---|
| `code` | matrix of the code subtracks that changed |
| `infra` | matrix of the infra subtracks that changed |
| `modules` | matrix of the modules that changed, one leg each |
| `tracks` | comma list of changed module names, e.g. `main,checkout` |
| `any` | `true` when at least one module changed |
| `<module>_code` | `true` when the code subtrack of `<module>` changed |
| `<module>_infra` | `true` when the infra subtrack of `<module>` changed |

The booleans let a project write explicit jobs for one module without a matrix.

A subtrack leg has the shape below. A matrix with nothing changed carries one
sentinel leg — `module=none`, `changed=false`,
`steps_matrix={"include":[{"step":"none"}]}` — so a caller can fan out
unconditionally; `changed=false` makes the reusable workflow skip it.

| field | meaning |
|---|---|
| `module` | module name (`none` in the sentinel) |
| `dir` | `code.dir` or `infra.dir` of the subtrack |
| `steps` | comma list of the subtrack's steps |
| `steps_matrix` | `{"include":[{"step":"<step>"}]}`, or `none` when empty |
| `changed` | `true` when the subtrack is in the run |

## Limits

- **Nesting**: `package.yml → deploy.yml` and `package.yml → infra-prepare.yml`,
  two levels; the project's own entrypoint calls `subtrack.yml` directly, so the
  maximum is three, well under GitHub's limit of ten.
- **The release tag is created before the build** (it triggers `package.yml`),
  so every job can checkout the tag itself. `requirements` proves the tag points
  at the commit of the run.
- A job-level `if` may only read `github`, `needs`, `inputs` and `vars` — never
  `matrix`. Every gate lives in the reusable workflow, on its inputs.
- Relative `uses:` resolve against the **caller's** repository, so every
  internal reference is absolute (`br4zz4/pipelines/...@v1`). The single
  exception is `./.github/actions/setup`, which *must* resolve in the caller.
- A reusable workflow cannot read `secrets` in a composite action, so actions
  take tokens as inputs.
- The pipelines are platform-agnostic: workflows and actions must not contain a
  provider name (`gcloud`, `kubectl`, `terraform`, ...). All of it lives in the
  module's scripts. `tasks/check.py` enforces this.
- The files under `examples/` are static documentation. Nothing in the pipelines
  executes them; a project copies and owns what it needs.
