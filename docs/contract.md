# Contract

What a repository must provide for `br4zz4/pipelines@v1` to run it. Everything
here is convention plus one file: `.github/modules.json`.

## Folders

```
modules/<name>/
  code/ci/    one script per code step: lint.sh · test.sh · build.sh
  infra/ci/   one script per infra step: check.sh · prepare.sh
              one script per rollout hook: apply.sh · fly.sh · glide.sh · rollback.sh
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
| code | `code.dir` | every `ci/*.sh` except `setup` and `build` |
| infra | `infra.dir` | `check` and `prepare`, when they exist |

`chmod +x` is neither required nor trusted: the hook runs scripts with `sh`
unless they are executable.

`build` is a step but not a check: the code subtrack never runs it, `build.yml`
does, and only when a tag opens staging. `prepare` is the read-only infra gate
of PR/main; the rollout never runs it.

The rollout does not take its steps from a matrix. It calls fixed hooks in the
infra directory:

| hook | job | contract |
|---|---|---|
| `infra/ci/apply.sh` | `apply` | make the infrastructure match the release. Prints "nothing to apply" and exits 0 when there is nothing to do |
| `infra/ci/fly.sh` | `fly` | deploy the image (never plan or apply infra) and write `rollback=<point>` to `$GITHUB_OUTPUT` |
| `infra/ci/glide.sh` | `glide` | check the environment as it actually runs and write `url=<url>` to `$GITHUB_OUTPUT` |
| `infra/ci/rollback.sh` | `rollback` | return to `ROLLBACK_POINT`; fail when it is empty |

`apply.sh` may run two optional hooks around its work:
`infra/ci/pre-apply.sh` and `infra/ci/post-apply.sh`. They exist as a
convention, not as pipeline steps; the example scripts test for them.

## Prepare — the gate

```
PR ─────► code steps ∥ infra: check · prepare      (no build, no tag)
push main► code steps ∥ infra: check · prepare ──► tag + stamp
```

1. **check** — `check.sh`, read-only. Format/validate the infra.
2. **prepare** — `prepare.sh`, read-only. Render, plan or diff what the release
   would apply. It never mutates the environment.

Only after every affected subtrack passes does `main` create the release tag.
A plan that finds nothing says "nothing to apply" and succeeds.

## Staging — the tag is the order

```
requirements ──► build ──► rollout
```

1. **requirements** — reads the ref and publishes a matrix of `{module, tag}`
   releases (see *Tags and releases*). A tag push names one release; a branch
   may carry the releases of several modules.
2. **build** — for each release: checkout the tag, project setup with
   `modules/<module>/code`, run the `build` hook. This is the only place an
   image is built.
3. **rollout** — for each release: `rollout.yml` with the module, the tag and
   `staging`.

## Production — dispatch, no build

```
requirements ──► rollout
```

`production.yml` is a manual `workflow_dispatch` with **no inputs**: the **ref
of the run decides the releases**, and there is no fallback. It declares
**only** `requirements` and `rollout`: there is no `build` job, so a production
run cannot build an image.

1. **requirements** — reads the ref and publishes the matrix of releases (see
   *Tags and releases*). It does not validate them: that is per leg.
2. **rollout** — one leg per release, with the module and tag from the matrix
   and `production`. The first job of each leg requires the tag exists, points
   at the commit of the run and is **green in staging for that module**; a
   release that did not pass staging fails its leg before anything is applied.
   `fly` promotes the same digest from the staging registry; nothing rebuilds.

## Rollout track

```
requirements ─► apply ─► fly ─► glide ─┬─► land ─► notify      (success)
                                       └─► rollback           (failure)
```

1. **apply** — checkout the tag, project setup with `modules/<module>/infra`,
   run the `apply` hook with the release `TAG` and the project's `TF_VARS`. The
   job runs in the `environment`, so its approvals and protection rules apply.
2. **fly** — run the `fly` hook. It writes `rollback=<point>`; the job publishes
   it as `rollback_point`. Infrastructure changes belong to `apply`, not here.
3. **glide** — run the `glide` hook against the deployed environment and publish
   its `url` output.
4. **land** — record the release as green with GitHub Deployments, payload
   `{module, tag}`, `environment_url` = the `url` from glide. Promotion reads
   these records, so only a landed release can be promoted.
5. **notify** — write the result to the run summary and, when
   `NOTIFY_WEBHOOK_URL` is set, post it. A failure here never reverts a deploy.
6. **rollback** — runs only when `fly` or `glide` failed. It gets
   `ROLLBACK_POINT` from `fly`'s output. A failed `apply` does not trigger it:
   `fly` never ran, nothing went live, and there is no rollback point — an apply
   failure is a manual incident. **The module script must fail high when the
   point is empty**: a failed deploy with no previous revision is never a silent
   success. After rolling back, `glide` runs again.

Artifacts: on a glide failure the pipeline uploads
`modules/<module>/code/tmp/artifacts` as
`glide-<module>-<environment>-<tag>`, and ignores a missing directory. A project
that wants failure evidence (screenshots, logs) writes it there.

The glide job and the rollback job carry a `postgres:16-alpine` service
(`postgres`/`postgres`, port 5432, `pg_isready` health check). It is a default,
not a language assumption: a module that does not use it simply ignores it, and
one that does can point at
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

### The ref decides the releases

`requirements` never takes a release as an input. It reads the ref of the run:

| run on | releases | how |
|---|---|---|
| a tag | that tag, and the modules it names | a full `<module>.YYYY-MM-DD.NNN` names its prefix; otherwise the `tracks:` line of its message names them |
| a branch | **every** release tag pointing at the commit of the run | `git tag --points-at HEAD`, filtered by the `<module>.YYYY-MM-DD.` shape; each tag resolves its modules as above |

- **One commit, several releases.** A commit that changed two modules carries
  both tags; the matrix has one leg per release (module + tag).
- **No fallback.** A commit with no release tag has no image, so there is nothing
  to raise: `requirements` fails with `this commit has no release tag`. A
  "newest green release" is never substituted — deploying a different commit
  than the one that was asked for is not a deploy of this ref.
- **Production requires staging green per release.** Each leg's rollout runs
  `resolve` against staging before applying; one un-green release fails only its
  own leg, with a clear "not recorded green in staging" error.
- **Production never builds.** The production entrypoint is
  `requirements → rollout`, fanned out by the releases matrix.
- The ref is the whole instruction: a staging run is the tag push; a production
  dispatch is `--ref <tag>` (that release) or `--ref <branch>` (all releases of
  that commit), always without inputs.

A release tag belongs to one module and is sequential per day:

```
core.2026-11-13.001
```

- The module is the prefix: `MODULE=${TAG%%.*}`. The tag alone says what to
  build, prepare and deploy.
- The day is `America/Sao_Paulo`, written ISO (`YYYY-MM-DD`); `NNN` is the day's
  release count of that module plus one, zero-padded to three digits (`.010`
  after `.009`), and it grows past three when a day needs it (`.1000`).
- Tags are annotated; the message is `release <tag>`.
- There is one shape: `requirements` rejects anything but
  `<module>.YYYY-MM-DD.NNN`; there is no `v...` compatibility.
- `requirements` rejects a tag that does not point at the commit of the run: a
  release is a commit that was already built, never a tag moved afterwards. In
  production this check runs per leg, inside the rollout.
- `resolve` reads GitHub Deployments, whose payload carries `{module, tag}`. With
  a tag it only validates that the tag is green for the module in that
  environment; without one it returns the newest green tag. `requirements` only
  ever uses the first form — the second exists for read-only consumers. A
  deployment stays green after GitHub marks it `inactive` (which happens when a
  newer deploy enters the same environment); a `failure` after the success does
  un-green it.

## Names

Every job is `<context> / <name>`: `requirements / main`, `prepare / main`,
`build / main`, `apply / main`, `fly / main`, `glide / main`, `land / main`,
`notify / main`, `rollback / main`, and `lint / main` for a matrix leg. The
context says what is happening; the name says which module.

Inside a job, a step is named after the script it runs — `build`, `apply`,
`fly`, `glide` — with no module suffix. The module is already in the job name
and in the matrix, so repeating it in the step only adds noise.

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

- **Nesting**: the project entrypoint calls `requirements.yml`, `build.yml` and
  `rollout.yml` (fanned out by the releases matrix), which call actions — two
  levels, well under GitHub's limit of ten.
- **The release tag is created before the build** (it triggers staging), so
  every job can checkout the tag itself. `requirements` proves the tag points at
  the commit of the run.
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
