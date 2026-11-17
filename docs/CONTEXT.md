# Pipelines

Shared GitHub Actions pipelines that every br4zz4 project runs the same way: a
project declares its modules, and the pipelines check, build, tag and deploy each
one on its own track.

## Language

### Structure

**Module**:
A deployable unit of a project, with a code side and an infra side, declared in `.github/modules.json`.
_Avoid_: service, app, component

**Track**:
The independent line of jobs one module runs inside a workflow; a failure in one track never stops another.
_Avoid_: lane, subtrack, leg

**Step**:
One job of a track, named by a fixed word from the closed vocabulary and backed by one script.
_Avoid_: stage, task

**Hook**:
The script `ci/<checks|deploy>/<step>.sh` inside a module side directory (`code/` or `infra/`) that a step runs; every hook in the vocabulary is mandatory, and a module that has nothing to do prints why and exits 0. Context (`checks` or `deploy`) is derived from the step name — never passed explicitly.
_Avoid_: script step, action

### Workflows

**Check**:
The group of read-only gates of a module: `lint`, `audit`, `test`, `validate` and `plan`.
_Avoid_: CI, verify, subtrack

**Release**:
A built image of one module identified by its release tag; it exists only after the build succeeded.
_Avoid_: version, build

**Release tag**:
`<module>.YYYY-MM-DD.NNN`, named by `build` and published by the `release` job of `main` after the build succeeded; pushing it deploys to staging.
_Avoid_: version tag, `v...` tag

**Deploy**:
The same track for staging and production — `preflight`, `apply`, `rollout`, `verify`, `record`, `notify`, with `rollback` on failure; staging is triggered by the tag push, production by a dispatch on a release tag (default `staging`, choosable `production`).
_Avoid_: ship, promote

**Record**:
Marking a release green in an environment (GitHub Deployments); production only deploys what staging recorded.
_Avoid_: land

### Secrets

**Default vault**:
The ward sub-vault `<project>` (≡ `<project>::default`) holding the values of test, staging and the pipeline itself (`secrets.ci`).
_Avoid_: shared vault, open vault

**Restricted vault**:
The ward sub-vault `<project>::restricted` holding production values; its key reaches only the production jobs of `deploy`.
_Avoid_: production vault, sealed vault

**Ward scope**:
`<vault>:secrets.<module>.<code|infra>.<environment>` — the single rule the pipeline uses to load a hook's values; the environment stays in the path even inside the restricted vault.
_Avoid_: runtime config

### Enforcement

**Render**:
Generating a project's `pr`, `main` and `deploy` workflows from its `modules.json`; nobody writes them by hand.
_Avoid_: scaffold, template copy

**Gate**:
The always-running job `check/pr` of the `pr` workflow that sums up every other job; it is the only status check a project's `main` ruleset requires.
_Avoid_: required check, status job

**Conform**:
The first job of every run, which fails when a project's workflows differ from the render or its modules miss a hook.
_Avoid_: lint, policy check

### Commons

**Commons**:
The `br4zz4/commons` repository, mounted in every project as the `.commons/` submodule, that gives every module the same local commands, compose services and secret handling; it knows no project, language or provider.
_Avoid_: shared lib, toolkit, `.project`

**Context file**:
`commons.ctx` at the project root: the only place where a project tells the commons its name, environments, vaults and scope template; make and every commons script read it, and a missing key fails instead of falling back to a guess.
_Avoid_: config, `.env`, settings

**Ops hook**:
A project script under `<infra>/ops/` (`remote.sh`, `secrets.sh`) that the commons runs for actions only the project's provider knows how to do; never run by the pipeline's own steps.
_Avoid_: task, ci hook

**Frame**:
Everything around a module's own code: Makefile, compose, secret loading and wiring to the pipeline; the commons owns it, the module only owns its core ("miolo").
_Avoid_: shell (reserved for the interactive command), casca, boilerplate, scaffold

**Canonical variable**:
An environment variable whose name and meaning are fixed for every module of every project (`DATABASE_URL`, `REDIS_URL`, `<MODULE>_URL`); a module never invents a synonym for it.
_Avoid_: `DB_*`, `<MODULE>_DATABASE_URL`, `NEON_*`

**Own key / Peer key**:
A module names its own variables without a prefix (`SHARED_SECRET` in checkout); a variable that belongs to another module's contract carries that module's prefix (`CHECKOUT_SHARED_SECRET` in core), even when both hold the same value, because they mean different things.
_Avoid_: shared scope, one name for both sides

**Secret push**:
Copying every key of a module's ward scope for one environment into the provider's secret store; it fails on a missing or `CHANGE_ME` value and always runs in the `apply` of a deploy, locally only by the same hook.
_Avoid_: secrets sync, upload, `app_secrets_push`

### Autofix

**Sentry issue**:
A grouped production error in Sentry, identified by its short id (`HAS_WARRANTY-1Z`); never a GitHub issue.
_Avoid_: bug, error, ticket, issue (alone)

**Autofix**:
The pipeline's attempt to fix one Sentry issue with an agent; it opens a pull request only when a regression test failed before the fix and passes after it, and otherwise leaves a note on the Sentry issue.
_Avoid_: self-heal, auto-repair, Seer
