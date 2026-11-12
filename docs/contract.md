# Contract

What a repository must provide for `br4zz4/pipelines@v1` to run it. Everything
here is convention plus one file: `.github/modules.json`.

## Registry — `.github/modules.json`

```json
{
  "shared": [".github/", ".project/", "Makefile", "compose.yml"],
  "modules": {
    "<name>": {
      "code": { "dir": "modules/<name>/code" },
      "deploy": { "dir": "modules/<name>/deploy" },
      "environments": {
        "staging": { "url": "https://staging.example.com" },
        "production": { "url": "https://example.com" }
      }
    }
  }
}
```

| key | meaning |
|---|---|
| `shared` | paths that count for every module and every subtrack |
| `modules.<name>.code.dir` | module code directory; default `modules/<name>/code` |
| `modules.<name>.deploy.dir` | module deploy directory; default `modules/<name>/deploy` |
| `modules.<name>.environments.<env>.url` | URL of the environment, used by land and notify |

The registry is the only module knowledge in the pipeline. A module is a
directory with a code side and a deploy side; the directories may be declared
explicitly or left to the `<name>` defaults. An environment needs nothing but
its `url` — `url` is the public URL the release answers on, and it is what the
deployment record and the notification point at.

## Subtracks and steps

A script **is** a step: `<dir>/ci/<step>.sh`. No workflow knows the name of a
step in advance; the plan reads the directory and builds the matrix.

| subtrack | directory | steps |
|---|---|---|
| code | `code.dir` | every `ci/*.sh` except `setup` and `package` |
| infra | `deploy.dir` | `check` and `plan`, when they exist |
| package | `code.dir` | `ci/package.sh`, after the code steps (release only) |

`chmod +x` is neither required nor trusted: the hook runs scripts with `sh`
unless they are executable.

The deploy track does not take its steps from the code directory. It calls three
fixed hooks in the deploy directory:

| hook | when | contract |
|---|---|---|
| `deploy/ci/fly.sh` | `fly` job | deploy the release and write `rollback=<point>` to `$GITHUB_OUTPUT` |
| `deploy/ci/glide.sh` | `glide` job, and again after a rollback | check the environment as it actually runs |
| `deploy/ci/rollback.sh` | `rollback` job | return to `ROLLBACK_POINT`; fail when it is empty |

A project may override any generic action by placing a script at
`<module_dir>/deploy/ci/<step>.sh` (for example `land.sh`, `verify.sh`). The
action then runs the project script instead of its default.

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
are established; the pipeline itself never authenticates.

## Secrets

Passed explicitly, never inherited. The pipeline only ever sees these names:

| secret | required | meaning |
|---|---|---|
| `RUNTIME_CONFIG` | no | opaque JSON object with the project's per-environment values; the pipeline never parses it, it only forwards it to the setup action |
| `NOTIFY_WEBHOOK_URL` | no | notification endpoint; the notification never reverts a deploy |
| `GH_TAG_TOKEN` | yes, in `release.yml` | PAT with the `workflow` scope: a tag pushed with `GITHUB_TOKEN` does not trigger workflows |

Because `RUNTIME_CONFIG` is opaque, a project can change what its setup action
needs without touching the pipelines.

`GITHUB_TOKEN` permissions are declared by the entrypoints: `contents: read` and
`id-token: write` on check, `contents: write` on release (tag push),
`deployments: write` on deploy.

## Tags and releases

Release tags are sequential per day and annotated:

```
v2026.11.12.10
tracks: main,checkout
```

- The day is `America/Sao_Paulo`; `N` is the day's release count plus one, read
  as a number (`.10` after `.9`).
- The `tracks:` line lists **modules**, not facets. A module in that list
  deploys its whole track.
- A lightweight tag with no message carries **every module**, so a tag created
  by hand still deploys.
- Legacy `vYYYY.MM.DD-<sha>` tags are still accepted by `verify`.
- `deploy` with an empty tag resolves the newest release recorded green in that
  environment from the GitHub Deployments API; the tag is read from the
  deployment payload, which carries `{module, tag}`.
- The `modules` input narrows a release to the listed modules; the tag itself
  does not change.

## Deploy track

```
plan ─► fly ─► glide ─┬─► land ─► notify      (success)
                      └─► rollback            (failure)
```

1. **fly** — checkout the release tag, verify it, set up the module, run
   `deploy/ci/fly.sh`. The job runs in the `environment`, so its approvals and
   protection rules apply. The script writes `rollback=<point>` to
   `$GITHUB_OUTPUT`; the step exposes it as the `rollback` output of the hook
   and the job publishes it as `rollback_point`.
2. **glide** — run `deploy/ci/glide.sh` against the deployed environment.
3. **land** — record the release as green with GitHub Deployments, payload
   `{module, tag}`, `environment_url` = the registry `url`. Production
   promotion reads these records, so only a landed release can be promoted.
4. **notify** — write the result to the run summary and, when
   `NOTIFY_WEBHOOK_URL` is set, post it. A failure here never reverts a deploy.
5. **rollback** — runs only when `fly` or `glide` failed. It gets
   `ROLLBACK_POINT` from `fly`'s output. **The module script must fail high when
   the point is empty**: a failed deploy with no previous revision is a manual
   incident, never a silent success. After rolling back, `glide` runs again.

Artifacts: on a glide failure the pipeline uploads
`<code.dir>/tmp/artifacts` as `e2e-<module>-<environment>-<tag>`, and ignores a
missing directory. A project that wants failure evidence (screenshots, logs)
writes it there.

Both the subtrack steps and the glide job carry a `postgres:16-alpine` service
(`postgres`/`postgres`, port 5432, `pg_isready` health check). It is a default,
not a language assumption: a module that does not use it simply ignores it, and
one that does can point at `postgres://postgres:postgres@localhost:5432`.

## Detection

| event | change set |
|---|---|
| `push` | `EVENT_BEFORE..HEAD`; without a usable before or `HEAD^`, everything |
| `pull_request` | `merge-base(EVENT_BASE or origin/<base>)..HEAD` |
| any other event | everything |

- `modules/<name>/code/**` touches the code subtrack of `<name>`.
- `modules/<name>/deploy/**` touches the infra subtrack of `<name>`.
- A `shared` path touches every subtrack of every module.
- Unrelated paths (docs, for example) touch nothing: no tag, no build, no deploy.
- `tracks` is the comma list of modules with any subtrack touched, deduplicated,
  in registry order: `main,checkout`.

## Matrices

A check leg and a release leg have the same shape:

| field | meaning |
|---|---|
| `module` | module name |
| `module_dir` | `modules/<module>` |
| `code_dir` | `code.dir` |
| `deploy_dir` | `deploy.dir` |
| `steps` | comma list of the subtrack's steps |
| `steps_matrix` | `{"include":[{"step":"<step>"}]}`, or `none` when empty |
| `package` | `true` when `ci/package.sh` exists |
| `changed` | `true` when the subtrack is in the run |
| `url` | `environments.<env>.url` |
| `environment` | environment of the run |
| `tag` | release tag, empty in check mode |

Check mode emits `code`, `infra`, `tracks` and `any`; release mode emits
`modules`, `tracks`, `tag` and `any`.

## Limits

- **Nesting**: `deploy.yml → track.yml`, two levels; `check.yml` and
  `release.yml` call `subtrack.yml` directly. The maximum is three, well under
  GitHub's limit of ten.
- A job-level `if` may only read `github`, `needs`, `inputs` and `vars` — never
  `matrix`. Every gate lives in the reusable workflow, on its inputs.
- Relative `uses:` resolve against the **caller's** repository, so every
  internal reference is absolute (`br4zz4/pipelines/...@v1`). The single
  exception is `./.github/actions/setup`, which *must* resolve in the caller.
- A reusable workflow cannot read `secrets` in a composite action, so actions
  take tokens as inputs.
- The pipelines are platform-agnostic: workflows and actions must not contain a
  provider name (`gcloud`, `kubectl`, ...). All of it lives in the module's
  scripts. `tasks/check.py` enforces this.
- The files under `examples/` are static documentation. Nothing in the pipelines
  executes them; a project copies and owns what it needs.
