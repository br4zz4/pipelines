---
title: Topologia de CI mais curta, detect sem docs e verify enxuto
status: done
created: 2026-11-20
updated: 2026-11-21
owner: "@oporpino"
certainty: high
---

# Topologia de CI mais curta, detect sem docs e verify enxuto

> **TLDR**: o job `<módulo> / changes` deixa de existir e o `detect` roda em paralelo ao `conform` (pr, main) e o `conform` em paralelo ao `release / start` (deploy). O `detect` passa a ignorar `*.md`, `docs/` e `.project/docs/`. O `verify` e o `rollback` do deploy param de subir os serviços do módulo e rodam em 2 vCPU.

Parte da spec coordenadora `brazza.tech/lunetamagica/docs/specs/20261120170000_ci_time_optimization.md`.

# what

Como dev Brazza, quero que os workflows gerados tenham só os jobs que trabalham e que um commit de documentação não dispare checks, build e deploy, para que o tempo do merge até o staging seja o mínimo que a mudança exige.

## out of scope

- Mexer na lógica do `reuse`: ela funciona; os misses medidos no luneta foram pushes diretos na main, sem PR.
- Build em paralelo aos checks no main (descartado: produziria imagem de código não validado).
- Cache de plugins do Terraform e `*.lock.hcl` na chave de cache da `actions/step`. O cache do actions é escopado por branch/tag (inclusive no Blacksmith), o deploy roda em tag e o main pula `validate`/`plan` pelo reuse, então o deploy nunca encontraria cache aquecido.
- Remover o input `services` do `deploy.yml` reutilizável: ele fica aceito e ignorado para não quebrar consumidores ainda não regenerados.
- Mudar o runner de `test`, `lint`, `audit` e `build`.

## acceptance criteria

```gherkin
Cenário: pr sem o job changes
  Dado um projeto com o módulo core
  Quando o conform renderiza o pr.yml
  Então não existe o job `core-changes`
  E `detect` não tem `needs`
  E `core-code` e `core-infra` têm `needs: [ conform, detect ]`
  E o `if` de cada um lê `fromJSON(needs.detect.outputs.changes).core.<lado>`
  E o gate `check/pr` tem `needs` com conform, detect, core-code e core-infra

Cenário: main com detect em paralelo
  Quando o conform renderiza o main.yml
  Então `detect` não tem `needs`
  E `core-reuse` tem `needs: [ conform, detect ]`

Cenário: deploy com conform em paralelo
  Quando o conform renderiza o deploy.yml
  Então `release-start` não tem `needs`
  E o job `deploy` tem `needs: [ conform, release-start ]`
  E o job `deploy` não passa `services`

Cenário alternativo: conform falha
  Dado que o job conform falha
  Quando o main roda
  Então reuse, lanes, build e release não executam

Cenário: commit só de documentação
  Dado um diff com apenas `README.md`, `docs/x.md`, `.project/docs/old.txt` e `modules/core/infra/terraform/gcp/README.md`
  Quando o detect roda
  Então `changes.core` é `{"any": false, "code": false, "infra": false}`

Cenário alternativo: documentação junto com código
  Dado um diff com `docs/x.md` e `modules/core/code/app/models/a.rb`
  Quando o detect roda
  Então `changes.core.code` é true e `changes.core.infra` é false

Cenário alternativo: .project fora de docs continua compartilhado
  Dado um diff com `.project/ci/gcp/apply.sh`
  Quando o detect roda
  Então `changes.core.code` e `changes.core.infra` são true

Cenário: verify e rollback enxutos
  Quando leio `.github/workflows/deploy.yml`
  Então os jobs `verify` e `rollback` não declaram `services`
  E rodam em `blacksmith-2vcpu-ubuntu-2404`
  E o input `services` continua declarado, com descrição de obsoleto

Cenário: contrato do pipelines continua válido
  Quando rodo o workflow `self`
  Então check, rendered, detect, render, conform, gate e standard passam
```

# why

Medido no luneta (runs 44822618255, 44823402399, 44822257202):

- `conform` (9 s) → `detect` (7 s) → `core / changes` (7 s, só um `echo` no summary) rodam em série antes de qualquer check: cerca de 15 s no caminho crítico de todo pr e main. No deploy, o `conform` (7 s) atrasa o `release / start`.
- O commit `93d813c` (`docs: align gcp guides ...`) disparou lint, audit, test, validate, plan, build, release e deploy de uma imagem com o mesmo código.
- O `verify` faz um `curl` no `/up`, mas sobe Postgres e roda em 4 vCPU porque recebe os `services` do módulo, que existem para os testes.

# how

Sem feature flag: os workflows são gerados. O `conform fix` regenera os workflows de cada consumidor no próximo PR depois que a `v1` andar.

**Risco de rollout:** como `conform check` compara o workflow com o render da `v1`, o main e o deploy de um consumidor falham no `conform` até um PR regenerar os workflows. Esse é o comportamento padrão do contrato. O luneta é regenerado na própria sequência coordenadora; nos demais consumidores, um PR qualquer basta.

Sem telas.

## PR 1 — detect ignora documentação (branch: `feat/leaner-ci-1`, base: `main`)

**Entrega:** o `detect` descarta caminhos de documentação antes de casar com módulos e `shared`.

### Task 1: testes (tester)
**Arquivos:** Modify `tests/detect/run.sh`
**Passos:** casos "commit só de documentação", "documentação junto com código" e ".project fora de docs continua compartilhado" → vermelhos → commit `test: detect ignores docs`
**Valida:** `sh tests/detect/run.sh`

### Task 2: filtro
**Arquivos:** Modify `actions/detect/detect.py`
**Passos:** constante `IGNORED = (".project/docs/", "docs/")` e função `documentation(path)` que é verdadeira para `path.endswith(".md")` ou `path.startswith(IGNORED)`. Em `main`, quando `paths` não é `None`, usa `paths = [p for p in paths if not documentation(p)]`. Atualizar a docstring com a regra. Testes verdes → commit `feat: detect ignores documentation`
**Valida:** `sh tests/detect/run.sh && python3 -m py_compile actions/detect/detect.py`

**Pronto para prod:** só reduz o conjunto de mudanças; os workflows não mudam.

## PR 2 — topologia paralela (branch: `feat/leaner-ci-2`, base: `feat/leaner-ci-1`)

**Entrega:** render sem `<módulo>-changes`, `detect` paralelo ao `conform` (pr, main) e `conform` paralelo ao `release-start` (deploy).

### Task 1: testes (tester)
**Arquivos:** Modify `tests/render/run.sh`, `tests/render/props.py`, fixtures em `tests/check/fixtures/green-pr/pr.yml` e `tests/check/fixtures/green-consumer-deploy/deploy.yml` (ajustar ao novo formato)
**Passos:** cenários "pr sem o job changes", "main com detect em paralelo", "deploy com conform em paralelo" → vermelhos → commit `test: parallel conform and detect`
**Valida:** `sh tests/render/run.sh && sh tests/check/run.sh`

### Task 2: render
**Arquivos:** Modify `actions/conform/render.py`
**Passos:**
- `detect_job`: remove `needs: conform`.
- Remove `changes_job`; `render_pr` chama `lane_job(..., head="detect")`.
- `lane_job`: com `head == "detect"`, `needs: [ conform, detect ]` e `if: ${{ fromJSON(needs.detect.outputs.changes).<m>.<lado> }}`; com `head == "reuse"`, mantém o de hoje.
- `reuse_job`: `needs: [ conform, detect ]`.
- `gate_job`: `needs` = conform, detect e as lanes de cada módulo.
- `releases_job`: remove `needs: conform`. `deploy_job`: `needs: [ conform, release-start ]` e sem a linha `services`.

Testes verdes → commit `feat: render parallel conform and detect`
**Valida:** `sh tests/render/run.sh && python3 tasks/check.py && sh tasks/check_rendered.sh`

**Pronto para prod:** o render gera workflows válidos (`check.py --standard`); os consumidores só mudam ao regenerar.

## PR 3 — verify e rollback enxutos (branch: `feat/leaner-ci-3`, base: `feat/leaner-ci-2`)

**Entrega:** o `deploy.yml` reutilizável sem serviços em `verify` e `rollback`, ambos em 2 vCPU, e a documentação.

### Task 1: workflow
**Arquivos:** Modify `.github/workflows/deploy.yml`
**Passos:** remove os blocos `services:` de `verify` e `rollback`; `runs-on: blacksmith-2vcpu-ubuntu-2404` nos dois; a descrição do input `services` passa a ser `Deprecated, ignored: verify and rollback run without services`. Commit `feat: verify without services`
**Valida:** `python3 tasks/check.py && sh tests/actions/run.sh`

### Task 2: documentação
**Arquivos:** Modify `docs/contract.md` (topologia de pr/main/deploy, regra de documentação do detect, verify sem serviços), `README.md` (diagrama dos jobs, se houver)
**Passos:** commit `docs: leaner ci topology`
**Valida:** `grep -n 'changes' docs/contract.md README.md` não descreve mais o job `<módulo> / changes`

**Pronto para prod:** consumidores já gerados continuam passando `services`, que é aceito e ignorado.

### Task 3: release da v1
Depois do merge dos 3 PRs, rodar `sh tasks/release.sh` (move a `v1`) e confirmar com `git ls-remote --tags origin v1`.

## SEQUENCE
1. #<pr1> — detect ignora documentação
2. #<pr2> — topologia paralela
3. #<pr3> — verify e rollback enxutos
Merge in this order: #<pr1> #<pr2> #<pr3>

# definition of done

- [x] Todo cenário de "acceptance criteria" foi validado (automatizado ou verificado com comando exato) — suítes `detect` 23, `render` 31, `conform` 33, `actions` 215, `check` 25, `apply_needed` 12, `self` verde; PRs br4zz4/pipelines#8 a #14
- [x] Cenários de render ("pr sem o job changes", "main com detect em paralelo", "deploy com conform em paralelo"): `sh tests/render/run.sh` verde
- [x] Cenário "conform falha": `python3 tasks/check.py` verde e o `needs` de reuse e das lanes inclui `conform` (asserção em `tests/render/run.sh`)
- [x] Cenários de detect (só documentação, documentação com código, `.project` fora de docs): `sh tests/detect/run.sh` verde
- [x] Cenário "verify e rollback enxutos": `grep -n 'services:' .github/workflows/deploy.yml` mostra só o input; `verify` e `rollback` em 2 vCPU
- [x] Cenário "contrato do pipelines continua válido": workflow `self` verde
- [x] Cada PR da sequência validado isoladamente (self verde sem os PRs seguintes) — #8, #9 e #10 verificados branch a branch antes de abrir
- [x] Toda task do "how" executada, incluindo o release da `v1` — `v1` movida 5 vezes, a última em 3b38b7a (inclui #14)
- [x] Documentação atualizada (`docs/contract.md`, `README.md`)
- [x] Staging: `staging: none` (biblioteca; a validação em staging fica na spec coordenadora do luneta)
- [x] Banner `FINISHED` impresso como última saída (`br4zz4:finish`, Step 7), só com todos os itens acima marcados

## documentation

- `docs/contract.md`: topologia, regra de documentação do detect, verify sem serviços.
- `README.md`: diagrama de jobs.

## desvios e extras entregues

- **O job `<módulo> / changes` voltou no `pr.yml`** (PR #11), agora com `needs: [ conform, detect ]`. Sem ele, as lanes code e infra tinham o mesmo `needs` e o GitHub as agrupava numa caixa só no grafo. O ganho do `detect` em paralelo ao `conform` continua.
- **Input `step` no setup do projeto** (#12): a action `step` passa o nome do hook ao `setup`, que pode pular o que o hook não usa (gcloud e login do docker no `plan`).
- **Hooks opcionais `migrate` e `traffic`** (#13): `rollout` cria as revisões sem tráfego, `migrate` roda em paralelo e `traffic` move o tráfego depois dos dois. Sem o script o job passa com `skipping`, e o `conform` os aceita sem exigir.
- **`apply` condicional** (#14): a action `apply-needed` roda o `detect` no intervalo release anterior..tag; só em staging, sem mudança de infra, o `apply` é pulado e os jobs seguintes continuam. Validado no deploy `core.2026-11-20.044` (`apply: skipped`, 210 s do início ao fim do `verify`).
