---
title: Pipelines padrão por módulo, gerados e obrigatórios
status: proposed
created: 2026-11-15
updated: 2026-11-15
owner: "@o_porpino"
certainty: high
---

# Pipelines padrão por módulo, gerados e obrigatórios

> **TLDR**: todo projeto passa a ter só `pr.yml`, `main.yml` e `deploy.yml`, gerados a partir do `.github/modules.json` e validados pelo `conform`. Cada módulo corre numa trilha própria de jobs paralelos, sem `matrix` e com nomes literais (`core / code / lint`). O main builda e cria a tag. A tag sobe staging, e o dispatch sobe produção pela mesma trilha. Os secrets vêm do ward (`<projeto>` e `<projeto>::restricted`), o toolchain vem do `mise`, e o vocabulário de hooks é fechado e obrigatório.

# what

    Como dono de vários projetos (Ruby com banco, Go sem banco, Rust, Elixir) que fazem
    deploy em Heroku, GCP, Kubernetes ou AWS, quero que todos rodem exatamente o mesmo
    pipeline, gerado e verificado automaticamente, com uma trilha legível por módulo, para que
    nenhum projeto divirja do padrão e qualquer pessoa leia o grafo de um run sem esforço.

Glossário: `docs/CONTEXT.md` (Module, Track, Step, Hook, Check, Release, Release tag, Deploy,
Record, Default vault, Restricted vault, Ward scope, Render, Conform).

## Modelo

### Arquivos do projeto

```
.github/modules.json                 registro (única fonte editada à mão)
.github/actions/setup/action.yml     do projeto: autenticação no provedor e pacotes de sistema; nunca linguagem
.github/workflows/pr.yml             GERADO
.github/workflows/main.yml           GERADO
.github/workflows/deploy.yml         GERADO
.ward/config.yaml                    vaults <projeto>::default e <projeto>::restricted
.ward/vaults/**                      cifrado e commitado
modules/<m>/code/mise.toml           toolchain do lado code
modules/<m>/code/ci/{lint,audit,test,build}.sh
modules/<m>/infra/mise.toml          toolchain do lado infra
modules/<m>/infra/ci/{validate,plan,apply,deploy,verify,rollback}.sh
```

`modules.json`:

```json
{
  "shared": [".github/", ".ward/", "Makefile"],
  "extra_workflows": ["cleanup.yml"],
  "modules": {
    "core":    { "services": ["postgres"] },
    "gateway": {},
    "engine":  {},
    "events":  { "services": ["postgres", "redis"], "code": { "dir": "modules/events/app" } }
  }
}
```

| chave | significado |
|---|---|
| `shared` | paths que contam como mudança para todo módulo |
| `extra_workflows` | arquivos extras permitidos em `.github/workflows/`; default `[]` |
| `modules.<m>.services` | subconjunto de `postgres` e `redis`; default `[]` |
| `modules.<m>.code.dir` / `infra.dir` | default `modules/<m>/code` / `modules/<m>/infra` |

O nome de módulo segue `[a-z][a-z0-9_]*`. O nome do projeto (`<ns>`) é o namespace do vault default em `.ward/config.yaml` (`has_warranty::default` ou `has_warranty` → `has_warranty`), e os secrets do GitHub são `WARD_KEY_<NS>` e `WARD_KEY_<NS>_RESTRICTED`, com `<NS>` em maiúsculas, como na derivação do ward.

### Vocabulário fechado de hooks

| lado | hook | job | ambiente ward |
|---|---|---|---|
| code | `lint`, `audit`, `test` | `code / lint`, `code / audit`, `code / test` | `test` |
| code | `build` | `build` (só main) | `staging` |
| infra | `validate` | `infra / validate` | `test` |
| infra | `plan` | `infra / plan` | `staging` |
| infra | `apply`, `deploy`, `verify`, `rollback` | os de mesmo nome (deploy) | `staging` ou `production` |

- Todo hook é obrigatório. Quem não tem nada a fazer escreve um script que imprime o motivo e sai com 0 (ex.: `echo "sem audit: módulo sem dependências"`).
- Um `ci/*.sh` fora da tabela reprova no `conform`.
- O hook roda com o próprio diretório como cwd, com `MODULE`, `ENVIRONMENT`, `TAG` e `CI_CACHE_DIR` no ambiente, mais os valores do ward.
- `deploy` escreve `rollback=<ponto>` e `verify` escreve `url=<url>` em `$GITHUB_OUTPUT`.

### Jobs e nomes

No projeto, cada módulo é um job literal (`core`) que chama um reusable. Dentro do reusable, os jobs têm nomes literais fixos. O GitHub mostra `<módulo> / <job>`. Nenhum `name:` contém `${{`, e todo step tem `name:`.

```
pr      conform ─► detect ─┬─► core    / code / lint ∥ audit ∥ test ─┬─► check/pr (sempre)
                           │             / infra / validate ∥ plan ──┘
                           └─► gateway / …          (pulado se não mudou)

main    conform ─► detect ─┬─► core    / reuse ─► code / * e infra / * (pulados se o PR provou) ─► build ─► tag
                           └─► events  / …                                            (trilhas independentes)

deploy  conform ─► releases ─┬─► core / preflight ─► apply ─► deploy ─► verify ─┬─► record ─► notify
        push de tag = staging │                                                  └─► rollback ─┘
        dispatch = production └─► events / …
```

Steps de todo job que roda hook: `checkout` → `secrets` (setup-ward) → `toolchain` (mise) → `cache` → `setup` (action do projeto) → `<hook>`. Implementação: o `checkout` é step do job e os cinco seguintes são steps nomeados da composite `actions/step`, para não repetir 40 linhas em cada um dos 5 checks e 5 hooks de deploy; no grafo do job aparecem `checkout` e `<hook>`, e os demais ficam agrupados no log.

### Gate do PR (`check/pr`)

O ruleset da `main` de todo projeto exige **um único** status check: `check/pr` (integration GitHub Actions, `strict`). Exigir os checks de cada trilha não funciona. Um PR que não toca nenhum módulo (só `docs/`, por exemplo) pula todas as trilhas, e um check que nunca é criado deixa o merge travado em "Waiting for status to be reported".

- O `pr.yml` gerado sempre tem o job de nível superior `gate`, com `name: check/pr`, `if: ${{ always() }}` e `needs: [conform, detect, <todos os módulos>]`. Ele roda direto no projeto, não via reusable: um reusable criaria o nome `<caller> / <job>`, que não casa com o contexto exigido.
- O job tem um único step, `gate` (action remota, sem precisar de checkout), que chama `br4zz4/pipelines/actions/gate@v1` com `results: ${{ toJSON(needs) }}`. A action falha se algum `result` for `failure` ou `cancelled`. `skipped` conta como sucesso.
- O nome `check/pr` é uma exceção declarada à regra `<módulo> / <job>`: é o contrato com o ruleset e é igual em todo projeto.
- `main.yml` e `deploy.yml` não têm gate: nenhum ruleset exige checks neles.
- Configurar o ruleset é um passo de adoção do projeto, documentado no README. O `conform` não lê rulesets, porque isso exigiria token de admin.

### Secrets (ward)

| quem | escopos carregados |
|---|---|
| conform (modo fix), tag, notify | `<ns>:secrets.ci.common` (`GH_PIPELINES_TOKEN`, `NOTIFY_WEBHOOK_URL`) |
| jobs em `test`/`staging` | `<ns>:secrets.ci.<env>` + `<ns>:secrets.<m>.<code\|infra>.<env>` |
| jobs em `production` | `<ns>::restricted:secrets.ci.production` + `<ns>::restricted:secrets.<m>.<code\|infra>.production` |

- `secrets.ci.<env>` guarda o que a action `setup` do projeto usa para autenticar (WIF, role ARN, token do Heroku…).
- O GitHub só guarda `WARD_KEY_<NS>` e `WARD_KEY_<NS>_RESTRICTED`.
- O workflow gerado só passa a chave restricted para os jobs de módulo do `deploy.yml`, e só quando `github.event_name == 'workflow_dispatch'`. Dentro do reusable, ela só chega aos jobs com `inputs.environment == 'production'`.
- Só os jobs do reusable `deploy.yml` usam `environment:`, e só como `production` em produção e `staging` nos demais. A chave de produção pode viver só no environment `production`; o plano não é mais Free.

Contrato consumido de `br4zz4/setup-ward@v1` (especificado na spec daquele repo):

- inputs: `vault` (namespace), `key`, `restricted-key` (opcional) e `scopes` (lista, uma por linha, já qualificada);
- instala o ward numa versão fixa e exporta cada valor dos escopos para `GITHUB_ENV`, com `::add-mask::`;
- exporta `WARD_KEY_<NS>` (e `_RESTRICTED`, se recebida), também mascaradas, para que hooks possam rodar `ward exec` em outros escopos;
- um escopo sem valores gera `::notice::` e não falha.

### Conform

Primeiro job de todo run. Roda `render.py` sobre o `modules.json` e o `.ward/config.yaml` e compara a saída com os três workflows commitados. Reprova quando:

- algum dos três difere do render (o que inclui um `pr.yml` sem o job `check/pr` ou com ele alterado);
- existe em `.github/workflows/` um arquivo que não está em `extra_workflows`;
- a string `_RESTRICTED` aparece em qualquer workflow fora dos jobs de módulo do `deploy.yml`;
- falta um hook da tabela, ou sobra um `ci/*.sh` fora dela;
- falta o `mise.toml` em um dos diretórios de módulo, ou falta `.github/actions/setup/action.yml`;
- o `.ward/config.yaml` não declara exatamente um vault default de um namespace e o `<ns>::restricted` correspondente;
- um serviço declarado está fora do catálogo (`postgres` e `redis`).

Modos:

- **`fix`**, no PR do próprio repo com a chave disponível: grava os workflows renderizados, commita `ci: render workflows` na branch do PR com o `GH_PIPELINES_TOKEN` e falha com `::error::workflows re-rendered; a new run was triggered`. As demais violações só reprovam.
- **`check`**, no main, no deploy e em PR de fork: só reprova, e escreve no `GITHUB_STEP_SUMMARY` o diff dos arquivos esperados.

`render.py` e `conform.py` usam só a biblioteca padrão do Python 3. Rodam iguais em macOS e Linux, e localmente com `python3 actions/conform/render.py --root <projeto>`.

### Workflows gerados (forma para o módulo `core`, projeto `has_warranty`)

```yaml
# generated by br4zz4/pipelines render — do not edit
name: main
on:
  push:
    branches: [ main ]
permissions:
  contents: read
  id-token: write
  checks: read
  pull-requests: read
jobs:
  conform:
    name: conform
    runs-on: blacksmith-2vcpu-ubuntu-2404
    timeout-minutes: 5
    steps:
      - name: checkout
        uses: actions/checkout@v6
      - name: conform
        uses: br4zz4/pipelines/actions/conform@v1
        with:
          mode: check
  detect:
    name: detect
    needs: conform
    runs-on: blacksmith-2vcpu-ubuntu-2404
    timeout-minutes: 5
    outputs:
      changes: ${{ steps.detect.outputs.changes }}
    steps:
      - name: checkout
        uses: actions/checkout@v6
        with:
          fetch-depth: 0
      - name: detect
        id: detect
        uses: br4zz4/pipelines/actions/detect@v1
  core:
    name: core
    needs: detect
    if: fromJSON(needs.detect.outputs.changes).core.any
    uses: br4zz4/pipelines/.github/workflows/main.yml@v1
    with:
      module: core
      vault: has_warranty
      code: ${{ fromJSON(needs.detect.outputs.changes).core.code }}
      infra: ${{ fromJSON(needs.detect.outputs.changes).core.infra }}
      services: postgres
    secrets:
      WARD_KEY: ${{ secrets.WARD_KEY_HAS_WARRANTY }}
```

- `pr.yml` tem a mesma forma, com `on: pull_request`, `concurrency: pr-${{ github.ref }}` (cancela), `permissions: contents read, id-token write`, conform `mode: fix` (com `key`, `vault` e checkout de `github.head_ref`) e `uses: .../pr.yml@v1`. Termina com o gate:

```yaml
  gate:
    name: check/pr
    if: ${{ always() }}
    needs: [ conform, detect, checkout, core ]
    runs-on: blacksmith-2vcpu-ubuntu-2404
    timeout-minutes: 5
    steps:
      - name: gate
        uses: br4zz4/pipelines/actions/gate@v1
        with:
          results: ${{ toJSON(needs) }}
```
- `deploy.yml`:
  - `run-name: ${{ github.event_name == 'push' && 'staging' || 'production' }} · ${{ github.ref_name }}`;
  - gatilhos `push.tags: [ '*.[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].*' ]` e `workflow_dispatch` (sem inputs);
  - `permissions: contents read, id-token write, deployments write`;
  - jobs `conform` (check) → `releases`;
  - cada módulo com `if: fromJSON(needs.releases.outputs.releases).core != ''` e `concurrency: deploy-core-${{ needs.releases.outputs.environment }}` (sem cancelar);
  - `secrets.WARD_KEY_RESTRICTED: ${{ github.event_name == 'workflow_dispatch' && secrets.WARD_KEY_HAS_WARRANTY_RESTRICTED || '' }}`.

### Releases (deploy)

A action `releases` lê a ref e o `modules.json` e emite `releases` (JSON com **todos** os módulos, `""` para os ausentes) e `environment`:

| evento | ambiente | releases |
|---|---|---|
| push de tag | `staging` | a tag, no seu módulo (`${TAG%%.*}`) |
| dispatch numa tag | `production` | a tag, no seu módulo |
| dispatch numa branch | `production` | toda release tag que aponta para o HEAD; falha com `this commit has no release tag` se não houver nenhuma |

O `preflight` de cada trilha valida o formato, a existência e o commit da tag (`requirements`). Em produção, exige também que a release esteja registrada como verde em staging (`resolve`).

### Falhas

- `rollback` roda se `deploy` ou `verify` falhar. Recebe `ROLLBACK_POINT` e roda `verify` de novo.
- Falha no `apply` não dispara rollback.
- `record` roda se o `apply` rodou. Marca o deployment do GitHub como `success` quando `verify` passou e `failure` nos outros casos.
- `notify` roda sempre. O status é `ok` se `verify` passou, `rolled back` se o `rollback` passou e `failed` nos demais casos. O status vai para o summary e, se houver `NOTIFY_WEBHOOK_URL`, também para o webhook.

## out of scope

- A action `br4zz4/setup-ward` (spec própria, no repo dela; pré-requisito).
- Os sub-vaults no ward (`br4zz4/ward` `docs/specs/20261115120000_sub_vaults.md`; pré-requisito).
- As regras compartilhadas de Makefile (`make <módulo>.<step>`) e um alvo local `make workflows`: ficam para a spec de Makefile.
- Re-deploy manual de staging por dispatch: o caminho é "Re-run jobs" no run da tag.
- Aprovação por revisor e secrets de environment (o plano Free não oferece em repo privado).
- Cache de dependências específico de linguagem. O pipeline oferece só `CI_CACHE_DIR`, e o hook aponta o próprio cache para lá.
- Credenciais de promoção entre registries de staging e produção: ficam no escopo `restricted:secrets.ci.production` do projeto.
- Windows.

## acceptance criteria

    Cenário: PR que mexe em um módulo
      Dado um projeto com os módulos core, gateway, engine e events
      Quando um PR altera só modules/core/code
      Então rodam conform, detect e core / code / lint, audit, test e core / infra / validate e plan
      E gateway, engine e events aparecem como jobs pulados com o nome literal

    Cenário: PR sem módulo alterado passa no gate
      Dado o ruleset da main exigindo só o contexto "check/pr"
      Quando um PR altera só docs/
      Então todas as trilhas são puladas
      E o check-run "check/pr" é criado com success e o PR fica mergeável

    Cenário alternativo: trilha falhando bloqueia o merge
      Dado um PR em que core / code / test falha (ou a trilha é cancelada)
      Então "check/pr" falha e o merge fica bloqueado

    Cenário alternativo: conform falhando bloqueia o merge
      Dado um PR em que o conform falha (inclusive no run que re-renderiza)
      Então detect e as trilhas são pulados, e "check/pr" roda e falha

    Cenário: nome exato do gate
      Quando consulto gh api repos/<repo>/commits/<sha>/check-runs --jq '.check_runs[].name'
      Então aparece exatamente "check/pr", sem prefixo de caller

    Cenário: nomes do grafo
      Dado qualquer run de pr, main ou deploy
      Quando abro o grafo
      Então nenhum job ou step exibe "${{"
      E nenhum nome repete o módulo ou o contexto (sem "build / checkout / build / checkout")
      E todo step tem nome (nenhum "Run actions/checkout@v6")

    Cenário: conform regenera no PR
      Dado um PR que adiciona o módulo "billing" só no modules.json
      Quando o run do PR executa o conform
      Então um commit "ci: render workflows" com os três workflows aparece na branch
      E o run falha com "workflows re-rendered"
      E o run seguinte passa no conform

    Cenário alternativo: conform em PR de fork
      Dado um PR de fork com workflow divergente
      Quando o conform roda sem a chave
      Então falha sem commitar e o summary mostra o diff esperado

    Cenário alternativo: workflow editado à mão no main
      Dado um main.yml editado à mão
      Quando roda o main
      Então o conform falha e nenhuma trilha de módulo roda

    Cenário alternativo: workflow extra
      Dado ".github/workflows/cleanup.yml"
      Quando ele não está em extra_workflows
      Então o conform falha citando o arquivo
      E quando está declarado, o conform passa

    Cenário alternativo: hook ausente ou fora do vocabulário
      Dado o módulo gateway sem infra/ci/rollback.sh, ou com code/ci/format.sh
      Quando roda o conform
      Então ele falha citando o módulo e o arquivo

    Cenário: hook que não se aplica
      Dado gateway/code/ci/audit.sh que só imprime "sem audit" e sai 0
      Quando roda gateway / code / audit
      Então o job fica verde e o log mostra o motivo

    Cenário: duas trilhas no main
      Dado um push no main que altera core e events
      Quando events falha em events / code / test
      Então core segue até core / tag e cria core.YYYY-MM-DD.NNN
      E events não builda nem cria tag

    Cenário: a tag só existe com imagem
      Dado core / build falhando
      Quando o main termina
      Então nenhuma tag nova de core existe

    Cenário: main reaproveita o que o PR provou
      Dado um commit que entrou por um PR verde com o mesmo conteúdo
      Quando roda o main
      Então core / code / lint, audit, test e core / infra / validate e plan aparecem pulados
      E core / build e core / tag rodam

    Cenário alternativo: conteúdo diferente do PR
      Dado um commit cujo conteúdo difere do testado no PR
      Quando roda o main
      Então os checks rodam

    Cenário: staging pela tag
      Dado o push da tag core.2026-11-15.001
      Quando roda o deploy
      Então o run-name é "staging · core.2026-11-15.001"
      E só a trilha core roda: preflight, apply, deploy, verify, record, notify
      E nenhum job builda

    Cenário: produção por dispatch
      Dado core.2026-11-15.001 registrada verde em staging
      Quando disparo o deploy na ref da tag
      Então o run-name é "production · core.2026-11-15.001" e a trilha core sobe com o vault restricted

    Cenário alternativo: produção sem staging verde
      Dado uma tag sem registro verde em staging
      Quando disparo o deploy nela
      Então core / preflight falha com "not recorded green in staging" e nada é aplicado

    Cenário: dispatch numa branch com duas releases
      Dado o HEAD do main com as tags core.… e events.…
      Quando disparo o deploy no main
      Então as trilhas core e events rodam em paralelo

    Cenário alternativo: dispatch num commit sem release
      Quando disparo o deploy num commit sem release tag
      Então releases falha com "this commit has no release tag"

    Cenário alternativo: falha no verify
      Dado verify falhando em staging
      Então rollback roda com o ROLLBACK_POINT do deploy e reexecuta o verify
      E record marca o deployment como failure
      E notify envia "rolled back"

    Cenário alternativo: falha no apply
      Dado apply falhando
      Então rollback não roda, record marca failure e notify envia "failed"

    Cenário: serviços por módulo
      Dado core com services ["postgres"] e gateway sem services
      Quando rodam core / code / test e gateway / code / test
      Então só o de core sobe o container postgres

    Cenário: chave restricted isolada
      Dado os workflows gerados
      Então WARD_KEY_<NS>_RESTRICTED só aparece nos jobs de módulo do deploy.yml
      E um workflow que a cite em outro lugar reprova no conform

    Cenário alternativo: PR de fork pula o plan
      Dado um PR de fork
      Então infra / plan aparece pulado e os demais checks rodam

    Cenário: toolchain por módulo
      Dado módulos com mise.toml de ruby, go, rust e erlang+elixir
      Quando rodam as trilhas
      Então cada uma instala só o que o próprio mise.toml declara
      E nenhum workflow ou action do pipelines cita uma linguagem

    Cenário alternativo: módulo sem mise.toml
      Então o conform falha citando o diretório

    Cenário: plataforma
      Dado macOS e Linux
      Quando rodo os testes de render e conform localmente e no CI
      Então a saída é idêntica nos dois

    Cenário: projeto real migrado
      Dado o has_warranty migrado
      Quando passa por PR, merge no main e deploy de staging pela tag
      Então os três runs ficam verdes com os nomes literais

# why

Hoje cada projeto escreve à mão quatro workflows (`pr-main`, `main`, `staging` e `production`), copiando cerca de 200 linhas do README. Cada cópia diverge: o `has_warranty` tem o job `build / ${{ needs.preflight.outputs.module }}` chamando um job `build / ${{ inputs.module }}`, o que gera o nó `build / checkout / build / checkout`. Jobs pulados aparecem com `${{ inputs.module }}` cru. Steps sem nome aparecem como "Run actions/checkout@v6". O `rollout.yml` traz um secret e um `if` específicos do módulo `checkout`, o que fere a neutralidade. Hooks ausentes são pulados em silêncio, então um deploy sem `fly.sh` é registrado como verde. O `notify` só avisa sucesso. Toda perna da matriz sobe Postgres. O toolchain é resolvido com um `if` por linguagem na `setup` do projeto. Os secrets passam por cópias no GitHub (`RUNTIME_CONFIG`, `CHECKOUT_APP_SECRETS`) em vez de virem da fonte de verdade (o ward). E a skill `oporpino:ci` descreve um terceiro padrão.

Com mais stacks (Go, Rust, Elixir) e mais plataformas (Heroku, GCP, Kubernetes, AWS), isso não escala. O padrão precisa ser gerado, verificado a cada run e neutro quanto a linguagem e provedor.

# how

TDD em toda task de código: o tester escreve o teste vermelho a partir dos cenários, o builder implementa o mínimo e a suíte fica verde. Validação padrão neste repo: `python3 tasks/check.py && sh tests/detect/run.sh && sh tests/render/run.sh && sh tests/conform/run.sh && shellcheck -S warning actions/*/*.sh examples/*/*/ci/*.sh`. Sem telas.

**Pré-requisitos (outras specs):** `br4zz4/ward` sub-vaults (PRs 1–4 mergeados e release publicada) e `br4zz4/setup-ward@v1` publicado com o contrato da seção "Secrets". Os PRs 1–8 deste repo não dependem deles para passar no `self.yml`. Só o PR 10 (migração) depende.

**Tag `v1`:** os PRs 1–8 entram no `main` sem mover a tag `v1`, então o `has_warranty` continua na versão antiga. A tag só se move no PR 10.

**Congelamento da `v1` (hard rule):** a partir do merge do PR 1, ninguém move a `v1` para o `main` antes do PR 10. Se o main fosse publicado no meio da sequência, o has_warranty quebraria. Uma correção urgente no pipeline antigo (como o gate `check/pr` do has_warranty, em andamento em outra sessão) sai de uma branch `release/v1-legacy` criada a partir do commit atual da `v1`, e a `v1` é movida para o commit dessa branch. O que for reaproveitável dessa correção (a action `gate`) também entra no PR 1 desta spec, idêntico, para não divergir.

**Gate interino do has_warranty:** o ruleset já exige `check/pr`. Até o PR 10, o has_warranty tem esse job à mão no `pr-main.yml`, pela outra sessão. Se a action `gate` tiver sido publicada na `v1` legada, o PR 1 copia o mesmo `action.yml` e o mesmo `gate.sh`. No PR 10, o `pr.yml` gerado traz o mesmo `check/pr`, então a troca não deixa o PR de migração sem o check exigido.

## PR 1 — render e conform (branch: `feat/standard-pipelines-1`, base: `main`)
**Entrega:** `render.py` gera os três workflows a partir do `modules.json` e do `.ward/config.yaml`. A action `conform` valida o projeto nos modos `check` e `fix`. Ainda nenhum workflow usa isso.
**Arquivos:**
- Create `actions/conform/render.py`: só stdlib. Lê `modules.json` e o namespace do vault default, valida nomes de módulo e serviços, e escreve `pr.yml`, `main.yml` e `deploy.yml` na forma da seção "Workflows gerados". O cabeçalho é `# generated by br4zz4/pipelines render — do not edit`. A ordem dos módulos é alfabética e a saída é determinística. Imagem do serviço: `postgres:16-alpine` / `redis:7-alpine`, passadas como input `services` (lista separada por vírgula).
- Create `actions/conform/conform.py`: todas as regras da seção "Conform". No modo `check`, diff no summary e saída 1. No modo `fix`, grava, commita, faz push via `https://x-access-token:${GH_PIPELINES_TOKEN}@github.com/<repo>` e sai 1. Sem token, cai para `check`.
- Create `actions/conform/action.yml`: inputs `mode` (`check`|`fix`), `vault`, `key`. Steps nomeados: `secrets` (setup-ward com `<vault>:secrets.ci.common`, só se `mode == fix` e `key != ''`) e `conform`.
- Create `actions/gate/action.yml`, `actions/gate/gate.sh` (ou reaproveitar, idênticos, se a correção legada já os criou): input `results` (JSON de `needs`). Imprime `<job>: <result>` por linha e sai com 1 se algum for `failure` ou `cancelled`.
- `render.py` gera o job `gate` (`name: check/pr`) no `pr.yml`, com `needs` = conform, detect e todos os módulos em ordem alfabética.
- Create `tests/gate/run.sh`: tudo success; com skipped; com failure; com cancelled; `needs` vazio.
- Create `tests/render/run.sh` e `tests/render/fixtures/{four-modules,single-module}/` (entrada + workflows esperados).
- Create `tests/conform/run.sh` e `tests/conform/fixtures/` (um caso por regra de reprovação e um caso verde).
- Modify `.github/workflows/self.yml`: roda `tests/render/run.sh`, `tests/conform/run.sh` e `tests/gate/run.sh`.

**Pronto para prod:** só adiciona arquivos. Nada referencia a action ainda, e a `v1` não muda.
**Valida:** `sh tests/render/run.sh && sh tests/conform/run.sh && sh tests/gate/run.sh && python3 tasks/check.py`

## PR 2 — detect, releases e reuse sem matriz (branch: `feat/standard-pipelines-2`, base: `feat/standard-pipelines-1`)
**Entrega:** `detect` emite `changes` como JSON `{ "<m>": { "any", "code", "infra" } }`, sem as saídas de matriz. Entra a nova action `releases`. O `reuse` passa a procurar checks com o prefixo `<module> / check / `.
**Arquivos:**
- Modify `actions/detect/detect.py`, `actions/detect/action.yml`: saída única `changes` com todos os módulos (booleanos). Saem `code`, `infra`, `modules`, `tracks` e `any`.
- Create `actions/releases/action.yml`, `actions/releases/releases.sh`: regras da tabela "Releases". Saídas `releases` (JSON com todos os módulos) e `environment`. A regex de tag é a mesma do `requirements.sh`.
- Modify `actions/reuse/reuse.py`, `actions/reuse/action.yml`: o default de `check_prefix` vira `<module> / check / `. O input `subtrack` sai, e entra `steps` com `lint,audit,test,validate,plan`. Corrigir a variável `SUBTACK`.
- Modify `tests/detect/run.sh`; Create `tests/releases/run.sh`.

**Pronto para prod:** os workflows antigos deste repo não leem as saídas de matriz do detect (só os consumidores leem, e eles continuam na `v1` antiga).
**Valida:** `sh tests/detect/run.sh && sh tests/releases/run.sh && python3 tasks/check.py`

## PR 3 — hook obrigatório, record e notify (branch: `feat/standard-pipelines-3`, base: `feat/standard-pipelines-2`)
**Entrega:** hook ausente falha. `record` registra `success` ou `failure`. `notify` aceita `ok`, `failed` e `rolled back`.
**Arquivos:**
- Modify `actions/hook/hook.sh`: script ausente dá `::error::missing <dir>/ci/<step>.sh` e exit 1. O hook exporta `CI_CACHE_DIR=<dir>/.ci-cache`.
- Create `actions/record/action.yml`, `actions/record/record.sh`: igual ao `land.sh`, com o input `state` (`success`|`failure`) e sem o override `ci/land.sh`.
- Modify `actions/notify/action.yml`, `actions/notify/notify.sh`: `status` em `ok|failed|rolled back`, com mensagem e emoji por status.
- Create `tests/actions/run.sh`: hook ausente, `record` com payload montado (gh simulado no PATH) e as três mensagens do `notify`.

**Pronto para prod:** o `land` continua existindo para o `rollout.yml` antigo, e a `v1` não muda.
**Valida:** `sh tests/actions/run.sh && python3 tasks/check.py`

## PR 4 — reusables pr, main e deploy (branch: `feat/standard-pipelines-4`, base: `feat/standard-pipelines-3`)
**Entrega:** os três reusables novos, com jobs literais, steps nomeados, serviços condicionais, ward e mise. O `check.py` passa a impor as regras de nome.
**Arquivos:**
- Create `.github/workflows/pr.yml`:
  - inputs `module`, `vault`, `code` (bool), `infra` (bool), `services` (string); secret `WARD_KEY`;
  - jobs `lint`, `audit` e `test` com `if: inputs.code` (aparecem como `<módulo> / code / lint` etc.); `validate` com `if: inputs.infra`; `plan` com `if: inputs.infra && (github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name == github.repository)`;
  - steps `checkout`, `secrets`, `toolchain` (`jdx/mise-action@v2` com `working_directory: <dir>`), `cache` (`actions/cache@v4`, path `<dir>/.ci-cache`, key `<module>-<step>-` + `hashFiles('<dir>/mise.toml', '<dir>/**/*.lock', '<dir>/**/go.sum')`), `setup` (`./.github/actions/setup` com `dir` e `environment`) e o hook;
  - `services.postgres.image: ${{ contains(inputs.services, 'postgres') && 'postgres:16-alpine' || '' }}` (idem `redis`) só em `test`.
- Create `.github/workflows/main.yml`:
  - o job `reuse` emite um booleano por check;
  - os mesmos jobs `lint`, `audit`, `test`, `validate`, `plan`, com `&& needs.reuse.outputs.<step> != 'true'`; a action `reuse` recebe `check_prefix: <módulo> / code / ` para encontrar os check-runs do PR;
  - `build` (`if: !failure() && !cancelled()`, ambiente `staging`);
  - `tag` (actions `tag` + `stamp`, com o token vindo de `<vault>:secrets.ci.common`). O `stamp` passa a ler `GH_PIPELINES_TOKEN`.
- Create `.github/workflows/deploy.yml`:
  - inputs `module`, `vault`, `tag`, `environment` (obrigatório, sem default), `services`; secrets `WARD_KEY` e `WARD_KEY_RESTRICTED`;
  - jobs `preflight`, `apply`, `deploy`, `verify`, `record`, `rollback` e `notify`, com as regras da seção "Falhas";
  - escopos com `<vault>::restricted` quando `environment == 'production'`;
  - `verify` e `rollback` com os serviços condicionais;
  - upload de `<code.dir>/tmp/artifacts` quando o verify falha.
- Modify `actions/stamp/action.yml`, `actions/stamp/stamp.sh`: o token vira `GH_PIPELINES_TOKEN`.
- Modify `tasks/check.py`:
  - `WORKFLOW_NAMES` passa a ter `pr`, `main`, `deploy`, `self` e os cinco legados, marcados para remoção no PR 5;
  - nas três novas, reprova `name:` com `${{`, step sem `name:`, job sem `name:` literal, `matrix`, `environment:` e `_RESTRICTED` em job cujo `if` não exige `production`;
  - nos workflows gerados (fixtures de consumidor), exige no `pr.yml` o job `gate` com `name: check/pr`, `if: ${{ always() }}`, `needs` contendo todos os demais jobs e sem `uses:` de reusable;
  - adiciona `heroku` ao regex de plataforma.

**Pronto para prod:** os reusables novos ficam no `main` sem consumidor, e a `v1` não muda.
**Valida:** `python3 tasks/check.py && python3 tasks/check.py --consumers tests/render/fixtures/four-modules/expected`

## PR 5 — remove o legado (branch: `feat/standard-pipelines-5`, base: `feat/standard-pipelines-4`)
**Entrega:** o repo só tem o conjunto novo.
**Arquivos:**
- Delete `.github/workflows/{subtrack,prepare,build,preflight,rollout}.yml` e `actions/land/`.
- Modify `tasks/check.py`:
  - `WORKFLOW_NAMES = {pr, main, deploy, self}`;
  - `OBSOLETE_WORKFLOWS` ganha os cinco nomes e `OBSOLETE_TOKENS` ganha `fly`, `glide`, `land`, `prepare.sh` e `RUNTIME_CONFIG`;
  - as regras de nome valem para todos.
- Modify `.github/workflows/self.yml`: tira a checagem inline de obsoletos (já está no `check.py`). Os steps ficam `checkout`, `syntax`, `contracts`, `detect`, `render`, `conform`, `releases`, `actions`, `shell`.

**Pronto para prod:** só remove o que nada no `main` referencia, e a `v1` não muda.
**Valida:** `python3 tasks/check.py && grep -rnE 'fly|glide|land|subtrack|RUNTIME_CONFIG' .github actions` sem saída

## PR 6 — exemplos gcp-cloudrun e k8s (branch: `feat/standard-pipelines-6`, base: `feat/standard-pipelines-5`)
**Entrega:** os dois exemplos com o vocabulário novo, `mise.toml`, a `setup` só com autenticação e scripts de code que chamam o Makefile.
**Arquivos (exemplos são documentação estática):**
- Rename em `examples/{gcp-cloudrun,k8s}/infra/ci/`: `check.sh` → `validate.sh`, `prepare.sh` → `plan.sh`, `fly.sh` → `deploy.sh`, `glide.sh` → `verify.sh`. Atualizar os comentários.
- Create `examples/{gcp-cloudrun,k8s}/code/ci/{lint,audit,test,build}.sh`, cada um com `exec make "${MODULE}.<step>"`.
- Create `examples/{gcp-cloudrun,k8s}/{code,infra}/mise.toml`.
- Modify `examples/gcp-cloudrun/setup-action.yml` (só autenticação, lendo `WIF_PROVIDER` e `DEPLOY_SA` do ambiente exportado pelo ward); Create `examples/k8s/setup-action.yml`.
- Delete `examples/*/registry.json`; Create `examples/{gcp-cloudrun,k8s}/modules.json`.

**Pronto para prod:** só exemplos.
**Valida:** `shellcheck -S warning examples/*/*/ci/*.sh && python3 tasks/check.py`

## PR 7 — exemplos heroku e aws-ecs (branch: `feat/standard-pipelines-7`, base: `feat/standard-pipelines-6`)
**Entrega:** os mesmos hooks para Heroku e ECS Fargate.
**Arquivos:**
- Create `examples/heroku/{modules.json,setup-action.yml,code/mise.toml,infra/mise.toml}`, `examples/heroku/code/ci/{lint,audit,test,build}.sh` e `examples/heroku/infra/ci/`:
  - `build`: `heroku container:push`;
  - `validate`: `app.json` válido;
  - `plan`: imprime "nothing to plan";
  - `apply`: `heroku config:set` a partir do ambiente;
  - `deploy`: anota a release atual em `rollback=` e roda `container:release`;
  - `verify`: `curl --retry` no `URL`;
  - `rollback`: `heroku releases:rollback "${ROLLBACK_POINT}"`, falhando se o ponto estiver vazio.
- Create `examples/aws-ecs/…`, com a mesma lista:
  - `setup-action.yml`: `aws-actions/configure-aws-credentials` com `ROLE_ARN`;
  - `build`: push no ECR;
  - `validate` / `plan`: `terraform fmt -check` + `validate` / `plan`;
  - `apply`: `terraform apply`;
  - `deploy`: anota a task definition atual em `rollback=` e roda `aws ecs update-service --task-definition <nova>` + `aws ecs wait services-stable`;
  - `verify`: `curl --retry`;
  - `rollback`: `update-service` para `ROLLBACK_POINT`.
- Modify `examples/README.md`: tabela de exemplos com os quatro e tabela de variáveis por exemplo.

**Pronto para prod:** só exemplos.
**Valida:** `shellcheck -S warning examples/*/*/ci/*.sh`

## PR 8 — documentação (branch: `feat/standard-pipelines-8`, base: `feat/standard-pipelines-7`)
**Entrega:** README e contrato descrevendo exatamente o modelo desta spec.
**Arquivos:**
- Modify `README.md`: o que roda quando (pr, main e deploy), como adotar (escrever o `modules.json`, a `setup`, os `mise.toml`, os hooks e os vaults; o PR gera os workflows), nomes e requisitos. Inclui o passo de adoção do ruleset da `main`: um único status check obrigatório `check/pr`, integration GitHub Actions (15368), `strict: true`, criado só depois que o primeiro `pr.yml` gerado estiver na `main`.
- Modify `docs/contract.md`: registro, vocabulário, conform, secrets e escopos ward, contrato do `setup-ward`, releases, falhas e limites (sem matriz, nomes literais).
- Review `docs/CONTEXT.md`.

**Pronto para prod:** só docs.
**Valida:** `grep -nE 'subtrack|fly|glide|land|RUNTIME_CONFIG|matrix' README.md docs/contract.md` sem saída

## PR 9 — skills (repo `~/.qwert`, branch: `feat/pipelines-skills`, base: `main` daquele repo)
**Entrega:** as skills descrevem só este padrão.
**Arquivos:**
- Localizar as skills afetadas: `grep -rlnE 'ibft-corp/pipelines|deploy-staging|deploy-production|require-tag|ship|smoke|fly|glide|RUNTIME_CONFIG|GCP_WIF' ~/.qwert/config/agents/skills`. Se `oporpino:ci` não existir mais com esse nome, usar a skill equivalente que o grep apontar.
- Rewrite `~/.qwert/config/agents/skills/oporpino/oporpino:ci/SKILL.md`:
  - o padrão é `br4zz4/pipelines@v1`, com workflows gerados pelo conform (nunca escritos à mão);
  - modules.json, vocabulário fechado e obrigatório, nomes `<módulo> / <job>`, sem matriz;
  - ward `<ns>` / `<ns>::restricted`, `mise.toml` por lado, `setup` só com autenticação;
  - deploy pela tag (staging) e por dispatch (produção);
  - o hook chama `make <módulo>.<step>`.
- Modify `~/.qwert/config/agents/skills/oporpino/oporpino:spec/SKILL.md`: troca `ibft-corp/pipelines` por `br4zz4/pipelines`, e aplica o mesmo a toda skill do grep.

**Pronto para prod:** só texto.
**Valida:** o grep acima sem saída, exceto em menções históricas explícitas.

## PR 10 — publicar a v1 e migrar o has_warranty (repo `brazza.tech/has_warranty`, branch: `feat/standard-pipelines`, base: `main`)
**Entrega:** o primeiro consumidor no padrão e a tag `v1` movida.
**Passos, nesta ordem:**
1. Confirmar os pré-requisitos: release do ward com sub-vaults e `br4zz4/setup-ward@v1` publicado.
2. No has_warranty:
   - `ward vault add has_warranty::restricted`;
   - mover os valores de produção para `has_warranty::restricted:secrets.<m>.<code|infra>.production` e `…:secrets.ci.production`;
   - criar `has_warranty:secrets.ci.common` (`GH_PIPELINES_TOKEN`, `NOTIFY_WEBHOOK_URL`) e `has_warranty:secrets.ci.{test,staging}`;
   - os valores de teste (`DATABASE_URL=postgres://postgres:postgres@localhost:5432`, `RAILS_ENV=test`) vão para `secrets.<m>.code.test`.
3. `.gitignore`: passar a commitar `.ward/vaults/**` (as chaves continuam ignoradas).
4. Hooks:
   - renomear `check` → `validate`, `prepare` → `plan`, `fly` → `deploy` e `glide` → `verify` em `modules/{core,checkout}/infra/ci/`;
   - criar os hooks que faltarem;
   - criar `modules/{core,checkout}/{code,infra}/mise.toml` a partir do `.ruby-version` e do `.terraform-version`.
5. `.github/actions/setup/action.yml`:
   - fica só com pacotes de sistema e a autenticação no GCP lendo `WIF_PROVIDER` / `WIF_SA` do ambiente;
   - saem Ruby, Terraform, o `DATABASE_URL` e o parse de `RUNTIME_CONFIG`.
6. `modules/checkout/infra/ci/app_secrets_push.sh` sai de `ci/` (o `conform` reprova script fora do vocabulário) e vai para `modules/checkout/infra/lib/app_secrets_push.sh`. O `ci/apply.sh` passa a rodar `ward exec has_warranty${SUFFIX}:secrets.checkout.code.${ENVIRONMENT} -- lib/app_secrets_push.sh`, com `SUFFIX=::restricted` em produção. Delete `modules/*/infra/github_secrets_push.sh`.
7. `.github/modules.json` com os serviços: `core` e `checkout` com `["postgres"]`.
8. No pipelines: `git tag -f v1 <HEAD do main> && git push -f origin v1` (feito pelo techleader, com aviso ao usuário).
9. No has_warranty:
   - delete `.github/workflows/{pr-main,main,staging,production}.yml`. O `check/pr` interino sai junto com o `pr-main.yml` e é substituído pelo gate do `pr.yml` gerado no mesmo PR. O ruleset não muda;
   - gerar `pr.yml`, `main.yml` e `deploy.yml` uma vez, na mão (`python3 <pipelines>/actions/conform/render.py --root .`) e commitá-los no próprio PR: um PR roda os workflows da própria branch, então os primeiros precisam vir junto, senão o conform nunca roda. Depois o conform só mantém em sincronia;
   - no GitHub, criar `WARD_KEY_HAS_WARRANTY` e `WARD_KEY_HAS_WARRANTY_RESTRICTED` e apagar `RUNTIME_CONFIG`, `NOTIFY_WEBHOOK_URL`, `CHECKOUT_APP_SECRETS` e `GH_TAG_TOKEN`.
10. Entre os passos 8 e 9, o has_warranty fica congelado: nenhum merge no main até o PR de migração entrar.

**Pronto para prod:** o PR do has_warranty só é mergeado com `pr` verde. Depois do merge, o `main` precisa ficar verde e a tag gerada precisa subir staging pelo `deploy`.
**Valida:** `gh run list -R <has_warranty> --limit 3` mostra `pr`, `main` e `deploy` (staging) com `completed success`, e `curl -sS -o /dev/null -w "%{http_code}" --retry 3 --retry-delay 2 <url de staging>/up` retorna 2xx.

## SEQUENCE
1. #<pr1> — render e conform
2. #<pr2> — detect, releases e reuse sem matriz
3. #<pr3> — hook obrigatório, record e notify
4. #<pr4> — reusables pr, main e deploy
5. #<pr5> — remove o legado
6. #<pr6> — exemplos gcp-cloudrun e k8s
7. #<pr7> — exemplos heroku e aws-ecs
8. #<pr8> — documentação
9. #<pr9> — skills (`~/.qwert`)
10. #<pr10> — publicar a v1 e migrar o has_warranty

Merge in this order: #<pr1> #<pr2> #<pr3> #<pr4> #<pr5> #<pr6> #<pr7> #<pr8> #<pr9> #<pr10>

# definition of done

- [x] Todo cenário de "acceptance criteria" foi validado (automatizado ou verificado com comando exato)
- [x] Testes automáticos passando — suíte verde, não só a parte nova (`self.yml` verde) — detect 20/20, render 31/31, conform 25/25, releases 14/14, actions 85/85, gate 11/11, check 24/24, release 39/39
- [x] Toda task do "how" executada
- [x] Documentação atualizada (`README.md`, `docs/contract.md`, `docs/CONTEXT.md`, `examples/README.md`, skills) — `rollout` e `ci/checks/`/`ci/deploy/` corretos; `oporpino:ci` SKILL reescrita; grep limpo
- [x] Staging: sem telas neste repo; staging do has_warranty validado no PR 10 (ping em `/up`) — `checkout.staging.tenhoessanota.com.br/up` e `staging.tenhoessanota.com.br/up` retornam 200
- [x] Cada PR da sequência validado isoladamente (build e testes verdes sem os PRs seguintes) — evidência: PRs 1-8 validados cada um numa worktree descartável; check.py + suítes + check_rendered verdes
- [x] Último PR liga a funcionalidade e remove código temporário (move a `v1`, migra o has_warranty e apaga os secrets antigos) — v1 movido para d1b0257; has_warranty em @v1; CHECKOUT_APP_SECRETS, GH_TAG_TOKEN, RUNTIME_CONFIG deletados
- [x] `tests/render` cobre dois fixtures, e o render é determinístico (duas execuções produzem a mesma saída byte a byte) — evidência: tests/render 11 passed (four-modules e single-module, props.py checa determinismo)
- [x] `tests/conform` tem um caso por regra: workflow divergente, extra não declarado, extra declarado (verde), hook ausente, hook fora do vocabulário, sem `mise.toml`, sem `setup`, ward sem default/restricted, serviço fora do catálogo, `_RESTRICTED` fora do deploy — evidência: tests/conform 21 passed
- [x] Modo `fix` testado com git local (bare repo como remote): commit `ci: render workflows` e saída 1; sem token cai para `check` — evidência: tests/conform, casos fix com bare repo
- [x] `check.py` reprova `name:` com `${{`, step sem nome, `matrix`, `environment:` e `_RESTRICTED` em job não-produção — evidência: tests/check 22 passed (regras 1-8)
- [x] `tests/releases` cobre push de tag, dispatch em tag, dispatch em branch com duas tags e commit sem tag — evidência: tests/releases 16 passed
- [x] `tests/actions` cobre hook ausente (exit 1), `record` success/failure e `notify` ok/failed/rolled back — evidência: tests/actions 85 passed
- [x] Nenhum workflow ou action cita linguagem ou provedor (`check.py` verde com `heroku` no regex) — evidência: `python3 tasks/check.py` → ok: 4 workflows, 13 actions, com heroku no regex PLATFORM
- [x] `tests/gate` verde: success, skipped e `needs` vazio passam; failure e cancelled falham — evidência: tests/gate 11 passed
- [x] `check.py` reprova um `pr.yml` gerado sem o job `check/pr` ou com ele via reusable — evidência: fixtures bad-gate-* em tests/check
- [x] has_warranty: um PR só de `docs/` fica mergeável com `check/pr` success (cenário "PR sem módulo alterado passa no gate") — PR #136 SHA 81480c6: check/pr success, core/code, core/infra, checkout/code, checkout/infra skipped
- [x] has_warranty: um PR com uma trilha falhando tem `check/pr` failure e o merge bloqueado (cenário "trilha falhando bloqueia o merge") — PR #138 SHA 216de09: core/code/test failure → check/pr failure
- [x] has_warranty: um PR com o conform falhando tem `check/pr` failure (cenário "conform falhando bloqueia o merge") — PR #137 SHA bcce2d8: conform failure → detect skipped → check/pr failure; conform commitou ci: render workflows no branch
- [x] `gh api repos/brazza-tech/has_warranty/commits/<sha>/check-runs --jq '.check_runs[].name'` lista `check/pr` exato (cenário "nome exato do gate") — SHA 41dc7f92: check/pr aparece sem prefixo de caller
- [x] A `v1` não foi movida para o `main` entre os PRs 1 e 10 (`git log v1 -1` antes do PR 10 aponta para a `v1` atual ou para a `release/v1-legacy`) — evidência: `git rev-parse v1` = 41ef6d8 → 19ec4cf, ancestral da main, intocada
- [x] has_warranty: PR com mudança só em `core` roda só `core / code / *` e `core / infra / *` (cenário "PR que mexe em um módulo") — PR #134 SHA 5fc88dc1: checkout/* skipped, core/code/lint+audit+test success, core/infra skipped
- [x] has_warranty: grafo sem `${{`, sem nome repetido e com todo step nomeado (cenário "nomes do grafo") — verificado via python3 yaml.safe_load em main.yml
- [x] has_warranty: o PR de migração recebeu o commit `ci: render workflows` do conform (cenário "conform regenera no PR") — PR #137 (test/conform-fail): conform detectou divergência, commitou ci: render workflows no branch (SHA bcce2d8 → e891e203)
- [x] has_warranty: main reaproveitou os checks do PR (jobs `code / *` e `infra / *` pulados) e criou a tag depois do build — run 43874246626: core/code/lint+audit+test skipped (reuse=true), core/build success, core/release success
- [x] has_warranty: a tag subiu staging com run-name `staging · <tag>`, sem job de build — runs: "staging · core.2026-11-16.014", "staging · checkout.2026-11-16.006" (push event, sem job build)
- [x] has_warranty: `gh workflow run deploy.yml --ref <tag>` subiu produção com o vault restricted — run 43885943339: core.2026-11-16.017, staging registrado verde (run 43885881690), preflight 4m58s, apply+rollout+verify+record success
- [x] has_warranty: `WARD_KEY_HAS_WARRANTY_RESTRICTED` aparece só nos jobs de módulo do `deploy.yml` (`grep -n RESTRICTED .github/workflows/*.yml`) — deploy.yml linha 75; ausente em pr.yml e main.yml
- [x] Os cenários de falha (verify com rollback, apply sem rollback, notify sempre) são cobertos pelas condições do `deploy.yml`, verificadas no `check.py` — rollback `if: always() && (rollout.result == 'failure' || verify.result == 'failure')`, notify `if: always()`; check.py 85 passed
- [x] `render.py` e `conform.py` rodam com saída idêntica em macOS (local) e Linux (CI) — encoding="utf-8" e newline="\n" explícitos; CI (Linux) e local (macOS) produzem bytes idênticos (render determinístico validado em tests/render)
- [x] Skills: o grep do PR 9 não acha termos antigos — `grep -rlnE 'ibft-corp/pipelines|deploy-staging|...|GCP_WIF' ~/.qwert/config/agents/skills` sem saída; `oporpino:ci` SKILL reescrita (v3.0.0)

## documentation

- `README.md`: reescrito para o modelo gerado.
- `docs/contract.md`: reescrito.
- `docs/CONTEXT.md`: glossário (criado durante a entrevista).
- `examples/README.md`: quatro plataformas.
- `~/.qwert/config/agents/skills/oporpino/oporpino:ci/SKILL.md`, `oporpino:spec/SKILL.md` e as equivalentes encontradas no grep.
