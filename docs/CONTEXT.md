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
The script `<code|infra>/ci/<step>.sh` that a step runs; every hook in the vocabulary is mandatory, and a module that has nothing to do prints why and exits 0.
_Avoid_: script step, action

### Workflows

**Check**:
The group of read-only gates of a module: `lint`, `audit`, `test`, `validate` and `plan`.
_Avoid_: CI, verify, subtrack

**Release**:
A built image of one module identified by its release tag; it exists only after the build succeeded.
_Avoid_: version, build

**Release tag**:
`<module>.YYYY-MM-DD.NNN`, created by `main` after the build; pushing it deploys to staging.
_Avoid_: version tag, `v...` tag

**Deploy**:
The same track for staging and production — `preflight`, `apply`, `deploy`, `verify`, `record`, `notify`, with `rollback` on failure; staging is triggered by the tag push, production by a dispatch.
_Avoid_: rollout, ship, promote

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

**Conform**:
The first job of every run, which fails when a project's workflows differ from the render or its modules miss a hook.
_Avoid_: lint, policy check
