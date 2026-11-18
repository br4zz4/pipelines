---
title: br4zz4/commons — a casca padrão de todo projeto, como submodule
status: proposed
created: 2026-11-17
updated: 2026-11-17
owner: "@o_porpino"
certainty: high
---

# br4zz4/commons — a casca padrão de todo projeto, como submodule

> **TLDR**: nasce o repo público `br4zz4/commons`, montado em todo projeto como o submodule `.commons/`. Ele dá a todo módulo os mesmos comandos de make, os mesmos fragments de compose e o mesmo carregamento de secrets do ward. Não conhece projeto, linguagem nem provedor: tudo que é do projeto vem do `commons.ctx`, do `.github/modules.json` e de scripts do próprio módulo. `make <m>.<step>` roda o mesmo hook `ci/checks/<step>.sh` que o CI roda. O has_warranty é migrado: core e checkout passam a usar o mesmo nome de variável, o mesmo push de secrets e o mesmo jeito de rodar local.

# what

    Como dono de vários projetos com módulos em Ruby, Go e Elixir, quero que a casca
    (make, compose, secrets, shells) venha de um repo comum e agnóstico, para que cada
    projeto e cada módulo escreva só o miolo e todos se comportem igual.

Glossário: `docs/CONTEXT.md` (Commons, Context file, Ops hook, Frame, Canonical variable, Own key / Peer key, Secret push, Module, Hook, Ward scope, Default vault, Restricted vault).

## Modelo

### O repo `br4zz4/commons`

```
bin/commons              dispatcher POSIX sh: commons <comando> [módulo] [args]
bin/init                 bootstrap local idempotente de um projeto
lib/ctx.sh               lê e valida o commons.ctx, resolve ENV, escopo, vault e guarda
lib/modules.py           lê .github/modules.json (python3 stdlib): módulos, dirs, serviços
lib/print.sh             mensagens (info, warn, error) para stderr
make/main.mk             único include do projeto; gera os targets
compose/database.yml     postgres:16-alpine
compose/cache.yml        redis:7-alpine
compose/mail.yml         axllent/mailpit:v1 (só local)
commons.ctx.example      todas as chaves, comentadas
examples/polyglot/       projeto exemplo com os módulos ruby, go e elixir
tests/                   suíte sh com projetos falsos
.github/workflows/self.yml
README.md, docs/contract.md
```

Regras de implementação:

- Só POSIX sh e python3 stdlib. Nada de GNU-only (`sed -i`, `readlink -f`, `date -d`, `grep -P`). Roda igual em macOS e Linux.
- O commons nunca roda comando de linguagem (`bundle`, `go`, `mix`, `rails`) nem de provedor (`gcloud`, `kubectl`, `heroku`, `aws`). Quem roda isso é script do módulo.
- `make/main.mk` acha o próprio diretório por `$(lastword $(MAKEFILE_LIST))`. Nada assume que o submodule se chama `.commons`.
- Todo target é uma linha só, chamando `bin/commons` (regra 1 target ↔ 1 comando do `br4zz4:make`).

### `commons.ctx`

Fica na raiz do projeto, no formato `CHAVE=valor`, sem aspas e sem espaços. O make faz `include` dele e o sh faz `.` nele.

```
COMMONS_PROJECT=has_warranty
COMMONS_ENVS=development,test,staging,production
COMMONS_ENV_LOCAL=development
COMMONS_ENV_CHECK=test
COMMONS_ENV_REMOTE=staging
COMMONS_VAULT=has_warranty
COMMONS_RESTRICTED_VAULT=has_warranty::restricted
COMMONS_RESTRICTED_ENVS=production
COMMONS_SCOPE={vault}:secrets.{module}.{side}.{env}
COMMONS_GITHUB_SECRETS=WARD_KEY_HAS_WARRANTY:.ward/has_warranty::default.key,WARD_KEY_HAS_WARRANTY_RESTRICTED:.ward/has_warranty::restricted.key
COMMONS_REQUIRED_CHECK=check/pr
COMMONS_REF=v1
```

| chave | obrigatória | significado |
|---|---|---|
| `COMMONS_PROJECT` | sim | nome do projeto; é o texto da confirmação e o `COMPOSE_PROJECT_NAME` |
| `COMMONS_ENVS` | sim | ambientes válidos, separados por vírgula |
| `COMMONS_ENV_LOCAL` | sim | default de `run/*`, `shell` e `db` |
| `COMMONS_ENV_CHECK` | sim | default de `lint`, `audit`, `test` e `validate` |
| `COMMONS_ENV_REMOTE` | sim | default de `build`, `plan`, `remote`, `secrets` e `keys` |
| `COMMONS_VAULT` | não | vault do ward. Vazio ou comentado (`# COMMONS_VAULT=...`) = projeto sem ward |
| `COMMONS_SCOPE` | se há vault | template do escopo com `{vault}`, `{module}`, `{side}` e `{env}` |
| `COMMONS_RESTRICTED_VAULT` | não | vault usado nos ambientes de `COMMONS_RESTRICTED_ENVS` |
| `COMMONS_RESTRICTED_ENVS` | se há restricted | ambientes que exigem confirmação e usam o vault restricted |
| `COMMONS_GITHUB_SECRETS` | não | pares `NOME:arquivo-de-chave` gravados por `github.setup` |
| `COMMONS_REQUIRED_CHECK` | não | check exigido pelo ruleset da branch default |
| `COMMONS_REF` | sim | tag do commons que `commons.update` usa |

- Faltou uma chave obrigatória: qualquer comando falha com `commons: commons.ctx sem <CHAVE>`.
- Um ambiente fora de `COMMONS_ENVS` (seja em `ENV=` ou num `COMMONS_ENV_*`) falha com `commons: ambiente <x> fora de COMMONS_ENVS`.
- O commons não tem default com cara de projeto. Nenhum nome de ambiente ou de vault aparece no código do commons.

### Resolução de ambiente, escopo e guarda

1. **Ambiente**: `ENV` (variável do make) > `ENVIRONMENT` (exportada pelo pipeline) > o default do comando (`COMMONS_ENV_*`). O `bin/commons` lê `ENV`, faz `unset ENV` e exporta `ENVIRONMENT`. Assim o `ENV` do POSIX sh, que aponta o arquivo de startup do shell interativo, nunca chega ao filho.
2. **Vault**: `COMMONS_RESTRICTED_VAULT` se o ambiente está em `COMMONS_RESTRICTED_ENVS`; senão, `COMMONS_VAULT`.
3. **Escopo**: o `COMMONS_SCOPE` com os quatro placeholders preenchidos (`side` = `code` ou `infra`).
4. **Carga**: com vault, o comando roda sob `ward exec <escopo> -- …`.
   - Antes disso, `ward secrets <escopo>` testa o acesso. Se o ward falhar por falta de chave, o comando falha com `commons: sem acesso ao vault <vault> (falta a chave)`.
   - Se o escopo não existir ou estiver vazio, sai um aviso `commons: escopo <escopo> vazio` e o comando segue sem ward. A exceção são `secrets` e `keys`, que falham.
   - Sem vault, o comando roda com o ambiente do shell.
5. **Guarda**: um ambiente em `COMMONS_RESTRICTED_ENVS` pede para digitar `COMMONS_PROJECT` quando há TTY. Sem TTY, exige `CONFIRM=<COMMONS_PROJECT>`. Com `GITHUB_ACTIONS=true` não pergunta: o CI é o caminho normal de produção.
6. **Toolchain**: todo comando que roda script de módulo roda sob `mise exec -C <dir> --`. Sem `mise.toml` no dir, falha com `commons: <dir> sem mise.toml`.
7. **Paridade com o CI**: o script roda com cwd = dir do lado e com `MODULE`, `ENVIRONMENT`, `TAG` (vazio localmente, a não ser que venha do ambiente) e `CI_CACHE_DIR=<dir>/.ci-cache`. São as mesmas variáveis que a action `step` do pipelines entrega. Um script não executável roda com `sh`.

### Comandos

Os módulos e os dirs (`code.dir` e `infra.dir`, com os defaults do pipelines) vêm do `.github/modules.json`.

| make | `bin/commons` | roda | lado | ENV default |
|---|---|---|---|---|
| `<m>.lint` `<m>.audit` `<m>.test` | `hook <m> <step>` | `<code>/ci/checks/<step>.sh` | code | `COMMONS_ENV_CHECK` |
| `<m>.build` | `hook <m> build` | `<code>/ci/checks/build.sh` | code | `COMMONS_ENV_REMOTE` |
| `<m>.validate` | `hook <m> validate` | `<infra>/ci/checks/validate.sh` | infra | `COMMONS_ENV_CHECK` |
| `<m>.plan` | `hook <m> plan` | `<infra>/ci/checks/plan.sh` | infra | `COMMONS_ENV_REMOTE` |
| `<m>.<nome>` | `run <m> <nome>` | `<code>/run/<nome>` (um target por arquivo) | code | `COMMONS_ENV_LOCAL` |
| `<m>.shell` | `shell <m>` | `$SHELL` (ou `sh`) no dir code | code | `COMMONS_ENV_LOCAL` |
| `<m>.db` | `db <m>` | `psql "$DATABASE_URL"`; falha se faltar `DATABASE_URL` ou `psql` | code | `COMMONS_ENV_LOCAL` |
| `<m>.keys` | `keys <m>` | imprime os nomes (nunca os valores) do escopo code, um por linha | code | `COMMONS_ENV_REMOTE` |
| `<m>.remote` | `remote <m>` | `<infra>/ops/remote.sh` | code + infra | `COMMONS_ENV_REMOTE` |
| `<m>.secrets` | `secrets <m>` | Secret push: valida o escopo code e roda `<infra>/ops/secrets.sh` | code + infra | `COMMONS_ENV_REMOTE` |
| `up` `down` `logs` | `up` `down` `logs` | `docker compose up -d --wait` / `down` (mantém volumes) / `logs -f` | — | — |
| `conform` | `conform` | valida o projeto contra este contrato | — | — |
| `github.setup` | `github-setup` | secrets, merge e ruleset no GitHub | — | — |
| `commons.update` | `update` | `git -C <commons> fetch --tags` + `checkout $COMMONS_REF` | — | — |
| `help` | `help` | lista os comandos, os módulos, os `run/*` e os targets `##` do projeto | — | — |

- Os argumentos vão em `ARGS="…"` e chegam ao script como `$@`.
- Os comandos `code + infra` rodam sob `ward exec <escopo code> <escopo infra>`. Uma chave presente nos dois escopos faz o comando falhar com `commons: <CHAVE> existe em <escopo code> e <escopo infra>`, citando só o nome.
- `secrets`:
  1. lê os nomes do escopo code com `ward secrets`;
  2. falha listando **só os nomes** de quem está vazio ou vale `CHANGE_ME` (`commons: sem valor: A B`), sem rodar o hook;
  3. exporta `COMMONS_SECRET_KEYS` (nomes separados por espaço) e roda `ops/secrets.sh`.
- `keys` existe para o `apply` e o Terraform usarem a mesma lista: a lista de chaves de um módulo **é** o escopo.
- O CI usa os mesmos comandos. Um hook de deploy chama `"$ROOT/.commons/bin/commons" secrets "$MODULE"`, e o `ENVIRONMENT` do pipeline decide o ambiente.

### Ops hooks

`<infra>/ops/` só aceita `remote.sh` e `secrets.sh`. Ambos são opcionais. Um comando cujo hook falta falha com `commons: <m> sem <infra>/ops/<hook>.sh`.

| hook | contrato |
|---|---|
| `remote.sh` | abre um shell ou roda `$@` no ambiente remoto (a release que está no ar), com o env dos escopos carregado |
| `secrets.sh` | grava no provedor cada chave de `COMMONS_SECRET_KEYS` com o valor do ambiente. Não lista chaves por conta própria e falha se uma gravação falhar |

### Compose

O projeto escreve o próprio `compose.yml` com `include:` (Compose ≥ 2.20; `up` falha com `commons: docker compose >= 2.20` se a versão for menor):

```yaml
include:
  - .commons/compose/database.yml
  - .commons/compose/mail.yml
```

| fragment | serviço | imagem | portas (host) | volume |
|---|---|---|---|---|
| `database.yml` | `database` | `postgres:16-alpine`, `postgres`/`postgres` | `${COMMONS_DB_PORT:-5432}:5432` | `database_data` |
| `cache.yml` | `cache` | `redis:7-alpine` | `${COMMONS_CACHE_PORT:-6379}:6379` | — |
| `mail.yml` | `mail` | `axllent/mailpit:v1` | `${COMMONS_MAIL_PORT:-8025}:8025`, `${COMMONS_SMTP_PORT:-1025}:1025` | — |

- As imagens e as credenciais são as mesmas dos serviços do CI. Todos os serviços têm healthcheck, para o `--wait` funcionar.
- O commons não monta `DATABASE_URL`. O valor de development mora no escopo ward de development do projeto.
- O app roda no host com mise. O commons não tem imagem de dev nem serviço de app.

### `bin/init`

Uso: `git submodule add https://github.com/br4zz4/commons .commons && .commons/bin/init`. É idempotente e nunca sobrescreve:

- **`Makefile`**: cria com `include .commons/make/main.mk` se não existir. Se existir sem o include, avisa.
- **`commons.ctx`**: cria a partir de `commons.ctx.example`, com todas as chaves comentadas, se não existir.
- **`compose.yml`**: cria se não existir. Os `include:` vêm dos `services` do `modules.json` (`postgres` → `database.yml`, `redis` → `cache.yml`), mais `mail.yml` comentado.
- **`.gitignore`**: acrescenta `.ci-cache/` se faltar.
- No fim roda `commons conform`, que lista o que falta.

### `conform` (do commons)

Reprova, citando o arquivo, quando:

1. falta o `commons.ctx`, falta uma chave obrigatória ou um `COMMONS_ENV_*` está fora de `COMMONS_ENVS`;
2. o `.github/modules.json` está ausente ou inválido, ou um nome de módulo não casa com `[a-z][a-z0-9_]*`;
3. um `<code>/run/<nome>` usa um nome reservado (`lint`, `audit`, `test`, `build`, `validate`, `plan`, `shell`, `db`, `keys`, `remote`, `secrets`);
4. `<infra>/ops/` tem algo além de `remote.sh` e `secrets.sh`;
5. o `compose.yml` inclui um `.commons/compose/*.yml` que não existe.

### `github.setup`

Precisa do `gh` autenticado com permissão de admin no repo, e o repo vem do `gh repo view`. É idempotente:

1. Para cada par de `COMMONS_GITHUB_SECRETS`, roda `gh secret set <NOME> < <arquivo>`. O valor nunca é impresso. Um arquivo ausente vira aviso e o par é pulado.
2. `gh api -X PATCH repos/<repo>` com `allow_merge_commit=false`, `allow_squash_merge=true`, `allow_rebase_merge=true` e `delete_branch_on_merge=true`.
3. Com `COMMONS_REQUIRED_CHECK`, cria ou atualiza o ruleset `commons-default-branch` da branch default: um status check obrigatório com esse nome, integration GitHub Actions (`15368`), `strict: true`. Ele só cria se algum `.github/workflows/*.yml` da branch default remota (`git grep` em `origin/<default>`) declarar `name: <check>`. Senão, avisa `ruleset adiado: nenhum workflow em <default> declara <check>` e segue.

### Convenção de variáveis (aplicada no has_warranty; o commons não impõe)

1. O banco é sempre `DATABASE_URL` e o cache é `REDIS_URL`.
2. A URL de outro módulo é `<MÓDULO>_URL`, sempre env simples (Terraform), nunca secret.
3. Chave própria vai sem prefixo de módulo. A chave de contrato de outro módulo leva o prefixo do dono, mesmo com o mesmo valor (Own key / Peer key).
4. A lista de chaves de um módulo é o escopo `secrets.<m>.code.<env>`: sem arquivo de lista, sem lista em script e sem lista no Terraform.
5. Valor vazio ou `CHANGE_ME` falha (o commons impõe isso no `secrets`).
6. O Secret push roda sempre no `apply` do deploy. `make <m>.secrets` é o mesmo caminho, rodado localmente.
7. O nome no Secret Manager é `<projeto-kebab>-<módulo>-<env>-<chave-kebab>` (ex.: `has-warranty-core-staging-secret-key-base`).

Mapa do has_warranty:

| módulo | hoje | depois | tipo |
|---|---|---|---|
| core | `DB_HOST`, `DB_USER`, `DB_PASSWORD`, `DB_PORT`, `DB_NAME_*`, `HAS_WARRANTY_DATABASE_PASSWORD`, `NEON_DATABASE_URL` | `DATABASE_URL` | secret |
| core | `CHECKOUT_APP_URL` | `CHECKOUT_URL` | env (Terraform) |
| core | `CHECKOUT_SHARED_SECRET`, `CHECKOUT_WEBHOOK_SECRET` | sem mudança (Peer key) | secret |
| core | `RAILS_MASTER_KEY` no `.env` | sai; `SECRET_KEY_BASE` vem do escopo | secret |
| checkout | `NEON_DATABASE_URL` / `CHECKOUT_DATABASE_URL` | `DATABASE_URL` | secret |
| checkout | `CORE_APP_URL` | `CORE_URL` | env (Terraform) |
| checkout | `CHECKOUT_SHARED_SECRET`, `CHECKOUT_WEBHOOK_SECRET`, `CHECKOUT_WEBHOOK_PATH_SECRET` | `SHARED_SECRET`, `WEBHOOK_SECRET`, `WEBHOOK_PATH_SECRET` | secret |
| checkout | `APPMAX_*`, `ASAAS_*` | sem mudança (prefixo é do provedor, não de módulo) | secret |
| ambos | `app_secret_keys.txt`, listas `app_secret_keys` no `variables.tf` | saem; a lista vem de `commons keys` | — |
| ambos | `<app>-<env>-<sufixo>`, `has-warranty-<env>-neon-database-url`, `checkout-<env>-neon-database-url` | `has-warranty-<m>-<env>-<chave-kebab>` | Secret Manager |

O Rails do core continua lendo `CACHE_DATABASE_URL`, `QUEUE_DATABASE_URL` e `CABLE_DATABASE_URL`. O Terraform os mapeia para o mesmo secret de `DATABASE_URL`, porque são uma escolha do projeto, não uma chave do escopo.

## out of scope

- Hook de túnel para banco privado (o has_warranty usa Neon público).
- Migrar ward, qwert, SharpConsole, PocKanban, lunetamagica, organizza e ya-site para o `br4zz4/commons`. O `oporpino/commons` fica intocado.
- Serviços de compose além de `database`, `cache` e `mail`.
- Imagem ou container de desenvolvimento para o app.
- Fazer o `conform` do pipelines validar o commons. O `conform` do commons roda localmente e no `init`.
- Windows.
- `migrate` por target: a migração continua no deploy (hooks `rollout` do has_warranty).

## acceptance criteria

    Cenário: o mesmo hook no make e no CI
      Dado o módulo ruby do examples/polyglot
      Quando rodo make ruby.test
      Então roda examples/polyglot/modules/ruby/code/ci/checks/test.sh com cwd no dir code
      E o script recebe MODULE=ruby, ENVIRONMENT=<COMMONS_ENV_CHECK> e CI_CACHE_DIR=<dir>/.ci-cache

    Cenário: agnóstico de linguagem
      Dado os módulos ruby, go e elixir do examples/polyglot
      Quando o self.yml do commons roda make <m>.lint e make <m>.test nos três
      Então os seis passam, cada um com o toolchain do próprio mise.toml
      E grep -rnE 'bundle|rails|go test|mix |gcloud|kubectl|heroku|aws ' bin lib make compose não acha nada

    Cenário: nada de projeto no commons
      Quando procuro has_warranty, development, staging, production, wehive ou ibft em bin, lib, make e compose
      Então não há ocorrência

    Cenário alternativo: chave faltando no commons.ctx
      Dado um commons.ctx sem COMMONS_ENV_LOCAL
      Quando rodo make core.shell
      Então falha com "commons: commons.ctx sem COMMONS_ENV_LOCAL"

    Cenário alternativo: ambiente inválido
      Quando rodo make core.test ENV=prod
      Então falha com "commons: ambiente prod fora de COMMONS_ENVS"

    Cenário: projeto sem ward
      Dado um commons.ctx com "# COMMONS_VAULT=x"
      Quando rodo make ruby.test
      Então o hook roda sem ward exec e passa

    Cenário: escopo vazio
      Dado um escopo de development inexistente para o módulo
      Quando rodo make core.shell
      Então aparece "commons: escopo <escopo> vazio" e o shell abre

    Cenário: shell local no banco de staging
      Quando rodo make core.console ENV=staging
      Então run/console roda local com os valores de has_warranty:secrets.core.code.staging

    Cenário: guarda de ambiente restrito
      Dado COMMONS_RESTRICTED_ENVS=production
      Quando rodo make core.console ENV=production sem TTY e sem CONFIRM
      Então falha sem rodar nada
      E com CONFIRM=has_warranty roda com o vault has_warranty::restricted

    Cenário alternativo: sem a chave restricted
      Dado que a máquina não tem a chave do vault restricted
      Quando rodo make core.console ENV=production CONFIRM=has_warranty
      Então falha com "commons: sem acesso ao vault has_warranty::restricted (falta a chave)"

    Cenário: Secret push recusa valor faltando
      Dado SECRET_KEY_BASE=CHANGE_ME no escopo code de staging
      Quando rodo make core.secrets
      Então falha com "commons: sem valor: SECRET_KEY_BASE", sem imprimir valores e sem rodar ops/secrets.sh

    Cenário: Secret push igual no CI e no make
      Dado o deploy de staging de core
      Quando o hook apply roda
      Então ele chama .commons/bin/commons secrets core
      E os secrets has-warranty-core-staging-<chave> ficam iguais ao escopo do ward

    Cenário alternativo: chave nos dois escopos
      Dado FOO em secrets.core.code.staging e em secrets.core.infra.staging
      Quando rodo make core.remote
      Então falha citando FOO e os dois escopos

    Cenário: nome reservado em run/
      Dado modules/core/code/run/test
      Quando rodo make conform
      Então falha citando o arquivo

    Cenário: ops fora do vocabulário
      Dado modules/core/infra/ops/deploy.sh
      Quando rodo make conform
      Então falha citando o arquivo

    Cenário: init idempotente
      Dado um projeto com Makefile próprio sem o include
      Quando rodo .commons/bin/init duas vezes
      Então o Makefile não muda, aparece o aviso do include e o segundo run não altera arquivo nenhum

    Cenário: compose por fragments
      Dado compose.yml com include de database.yml e mail.yml
      Quando rodo make up
      Então sobem database e mail saudáveis
      E make down para os dois mantendo o volume database_data

    Cenário: github.setup antes do pr.yml
      Dado um repo cuja branch default ainda não tem workflow com "name: check/pr"
      Quando rodo make github.setup
      Então os secrets são gravados, o merge fica só squash/rebase
      E aparece "ruleset adiado" sem criar ruleset

    Cenário: github.setup idempotente
      Quando rodo make github.setup duas vezes num repo com pr.yml
      Então existe um único ruleset commons-default-branch exigindo check/pr

    Cenário: plataforma
      Quando a suíte tests/ do commons roda em macOS e em Linux
      Então passa nos dois

    Cenário: has_warranty com a mesma casca nos dois módulos
      Dado o has_warranty migrado
      Então core e checkout rodam no host com mise, com make <m>.start, make <m>.test e make <m>.console
      E nenhum Makefile de módulo, .project/make/staging.mk ou serviço app existe

    Cenário: has_warranty com variáveis canônicas
      Quando procuro DB_HOST, NEON_DATABASE_URL, CHECKOUT_APP_URL, CORE_APP_URL e app_secret_keys no has_warranty
      Então só restam menções históricas em docs/

    Cenário: cutover sem queda
      Dado o deploy de staging e depois o de produção de cada PR de secrets do has_warranty
      Então verify fica verde em todos
      E os secrets antigos só são apagados depois dos dois ambientes verdes no nome novo

# why

Hoje a casca é reescrita em cada projeto, e de jeitos diferentes:

- **O `oporpino/commons` não serve de base.** É acoplado à WeHive/ibft (ECR `616795656532`, contexts `wehive-*`, `ibft-corp/infrastructure`) e está quebrado em vários pontos: `git.mk` e `ai.mk` apontam para um `scripts/make/` que não existe, `up.detached` roda em foreground, `_shortcuts.mk` é órfão e `console.sh` grava credencial em texto puro no pod. As quatro cópias (ward, qwert, SharpConsole e PocKanban, esta última com o submodule quebrado) divergem entre si.
- **O has_warranty não usa commons nenhum.** O core roda em container com `DB_*` e `RAILS_MASTER_KEY`, e o checkout roda no host com `DATABASE_URL`.
- **Os secrets divergem entre core e checkout:**
  - nomes diferentes para o mesmo conceito: `NEON_DATABASE_URL` vs `CHECKOUT_DATABASE_URL`, e `CHECKOUT_APP_URL` como secret vs `CORE_APP_URL` como env;
  - três listas de chaves que não batem (script, txt e Terraform);
  - push manual num módulo e no CI no outro;
  - nomes de Secret Manager diferentes.
- **As skills se contradizem**: symlink vs submodule, e targets flat vs `<m>.<x>`.

Com Go e Elixir chegando, cada projeto novo copiaria e divergiria de novo. Um commons agnóstico, que roda exatamente os hooks do pipeline, deixa a cada módulo só o miolo.

# how

TDD em toda task de código: o tester escreve o teste vermelho a partir dos cenários, o builder implementa o mínimo e a suíte fica verde. Validação padrão do commons: `sh tests/run.sh && shellcheck -S warning bin/* lib/*.sh tests/*.sh`. Sem telas novas. O has_warranty já tem staging (`/up`) e o ping cobre os deploys dele.

**Pré-condições:**

- O pipelines já está no padrão gerado (spec `20261115150000_standard_module_pipelines.md` concluída). O has_warranty já tem os vaults `has_warranty::default` e `has_warranty::restricted`, e os hooks `ci/checks` e `ci/deploy`.
- Criar o repo público `br4zz4/commons` é uma ação externa. O techleader roda `gh repo create br4zz4/commons --public` só depois de confirmar com o usuário.

**Ordem:** PRs C1–C5 (commons) → P1 (pipelines) → Q1 (skills) → H1–H5 (has_warranty). Os PRs H3–H5 sobem staging pela tag e produção por dispatch, e a produção de cada um só com o ok explícito do usuário.

## PR C1 — contexto, módulos e hooks (repo `br4zz4/commons`, branch: `feat/commons-1`, base: `main`)
**Entrega:** `bin/commons hook|run|shell|keys`, com o `commons.ctx` resolvido, o ward e o mise. `make <m>.<step>` e `make <m>.<run>`.
**Arquivos:**
- Create `lib/ctx.sh`: carrega e valida o `commons.ctx`; resolve ambiente (`ENV` > `ENVIRONMENT` > default, com `unset ENV`), vault, escopo e guarda (TTY, `CONFIRM`, `GITHUB_ACTIONS`); faz o pré-teste `ward secrets` e expõe a função `commons_exec <dir> <escopo...> -- cmd`, que aplica `ward exec` + `mise exec -C` + as variáveis de paridade.
- Create `lib/modules.py`: `modules.py <root> dir <m> <code|infra>`, `modules.py <root> list` e `modules.py <root> services <m>`. Defaults iguais aos do pipelines. Falha em JSON inválido ou nome fora de `[a-z][a-z0-9_]*`.
- Create `lib/print.sh`.
- Create `bin/commons`: subcomandos `hook`, `run`, `shell` e `keys`. Rejeita `hook` com step fora do vocabulário.
- Create `make/main.mk`: `include` do `commons.ctx`. Gera por módulo `<m>.{lint,audit,test,build,validate,plan,shell,keys}` e `<m>.<nome>` para cada `<code>/run/*`. Exporta `ENV`, `ARGS` e `CONFIRM`. Os targets são `.PHONY`, de uma linha.
- Create `commons.ctx.example`, `.gitignore`.
- Create `tests/run.sh` e `tests/fixtures/` (projeto falso com `modules.json`, `commons.ctx`, hooks em sh puro que gravam as variáveis recebidas, e `ward` e `mise` falsos no `PATH` que registram a chamada). Os casos cobrem os cenários de hook, chave faltando, ambiente inválido, sem ward, escopo vazio, guarda e falta de chave restricted.
- Create `.github/workflows/self.yml`: jobs `unit-linux` (`ubuntu-24.04`) e `unit-macos` (`macos-15`), cada um com `shellcheck` e `sh tests/run.sh`. Nomes literais, todo step nomeado.
**Pronto para prod:** repo novo, sem consumidor.
**Valida:** `sh tests/run.sh && shellcheck -S warning bin/commons lib/*.sh tests/run.sh`

## PR C2 — db, remote, secrets e conform (branch: `feat/commons-2`, base: `feat/commons-1`)
**Entrega:** os comandos que tocam ambiente remoto e o validador do projeto.
**Arquivos:**
- Modify `bin/commons`:
  - `db`;
  - `remote` e `secrets`, com os escopos code + infra e a detecção de colisão;
  - em `secrets`, a validação de vazio/`CHANGE_ME` (falha listando só os nomes) e o `COMMONS_SECRET_KEYS`;
  - `conform`, com as cinco regras.
- Create `lib/conform.sh`.
- Modify `make/main.mk`: `<m>.db`, `<m>.remote`, `<m>.secrets` e `conform`.
- Modify `tests/run.sh` e os fixtures: um caso por cenário de secrets, colisão, ops ausente, ops fora do vocabulário e nome reservado em `run/`. Um teste garante que nenhum valor de secret aparece no stdout/stderr de uma falha.
**Pronto para prod:** sem consumidor.
**Valida:** `sh tests/run.sh && shellcheck -S warning bin/commons lib/*.sh`

## PR C3 — compose e init (branch: `feat/commons-3`, base: `feat/commons-2`)
**Entrega:** fragments, `up`/`down`/`logs` e o bootstrap.
**Arquivos:**
- Create `compose/database.yml`, `compose/cache.yml` e `compose/mail.yml`, conforme a tabela "Compose", com healthcheck.
- Modify `bin/commons`: `up`, `down` e `logs`, com a checagem de versão do Compose e `COMPOSE_PROJECT_NAME=$COMMONS_PROJECT`.
- Create `bin/init`.
- Modify `make/main.mk`: `up`, `down` e `logs`.
- Modify `tests/run.sh`:
  - `init` duas vezes num projeto vazio e num projeto com Makefile próprio (o segundo run não muda nada: compara `cksum` antes e depois);
  - `docker compose -f <fixture> config` válido para cada fragment;
  - `up`/`down` reais só quando `docker` existe (no CI Linux).
**Pronto para prod:** sem consumidor.
**Valida:** `sh tests/run.sh`

## PR C4 — github.setup, update e help (branch: `feat/commons-4`, base: `feat/commons-3`)
**Entrega:** a configuração do repo no GitHub e a manutenção do submodule.
**Arquivos:**
- Create `lib/github.sh`: os três passos de "github.setup", com a busca do ruleset por nome para atualizar em vez de duplicar.
- Modify `bin/commons`: `github-setup`, `update` e `help`.
- Modify `make/main.mk`: `github.setup`, `commons.update` e `help` (`.DEFAULT_GOAL := help`).
- Modify `tests/run.sh`: um `gh` falso no `PATH` registra as chamadas. Os casos cobrem ruleset adiado, criação, segunda execução (PUT no mesmo id), arquivo de chave ausente e a garantia de que o valor da chave nunca aparece na saída.
**Pronto para prod:** sem consumidor.
**Valida:** `sh tests/run.sh`

## PR C5 — exemplo poliglota, docs e v1 (branch: `feat/commons-5`, base: `feat/commons-4`)
**Entrega:** a prova de que o commons funciona com Ruby, Go e Elixir, a documentação e a tag `v1`.
**Arquivos (exemplos são documentação executável; os de código ficam abaixo do teto):**
- Create `examples/polyglot/{.github/modules.json,commons.ctx,Makefile}`, com o Makefile fazendo `include ../../make/main.mk` e sem vault.
- Create `examples/polyglot/modules/ruby/code/{mise.toml,run/console,ci/checks/{lint,audit,test,build}.sh,lib/hello.rb,test/hello_test.rb}`:
  - lint: `ruby -wc`;
  - test: `ruby -Ilib -Itest test/hello_test.rb` (minitest da stdlib);
  - audit e build imprimem o motivo e saem 0.
- Create `examples/polyglot/modules/go/code/{mise.toml,go.mod,hello.go,hello_test.go,ci/checks/*.sh,run/console}`:
  - lint: `test -z "$(gofmt -l .)" && go vet ./...`;
  - test: `go test ./...`.
- Create `examples/polyglot/modules/elixir/code/{mise.toml,mix.exs,lib/hello.ex,test/{test_helper.exs,hello_test.exs},ci/checks/*.sh,run/console}`:
  - lint: `mix format --check-formatted`;
  - test: `mix test`.
- Modify `.github/workflows/self.yml`: jobs `example-ruby`, `example-go` e `example-elixir` (`jdx/mise-action@v2` + `make -C examples/polyglot <m>.lint <m>.test`).
- Create `README.md`: o que é, adoção (`submodule add` + `init` + `commons.ctx` + `github.setup`), comandos e o exemplo do has_warranty no `commons.ctx`.
- Create `docs/contract.md`: o modelo desta spec (ctx, resolução, comandos, ops hooks, compose, conform, github.setup e paridade com o pipelines).
- Depois do merge, o techleader cria a tag anotada `v1` no `main` (`git tag -a v1 -m "release v1"` + push), avisando o usuário.
**Pronto para prod:** primeira versão publicada, ainda sem consumidor.
**Valida:** `make -C examples/polyglot ruby.test go.test elixir.test` local (com mise) e `self.yml` verde nos cinco jobs.

## PR P1 — pipelines: checkout com submodules e hook como verdade (repo `br4zz4/pipelines`, branch: `feat/commons-submodules`, base: `main`)
**Entrega:** todo job de trilha baixa o `.commons`. O contrato diz que o hook é a implementação, e os exemplos de plataforma deixam de chamar `make`.
**Arquivos:**
- Modify `.github/workflows/code.yml`, `.github/workflows/infra.yml` e `.github/workflows/deploy.yml`: todo step `checkout` com `with: submodules: recursive`. Um projeto sem submodule não é afetado.
- Modify `tasks/check.py`: reprova um step `actions/checkout` sem `submodules: recursive` nesses três reusables.
- Modify `docs/contract.md` (linhas 70–71) e `README.md` (linha 73): "o hook é a implementação; `make <m>.<step>` do `br4zz4/commons` roda o mesmo hook localmente".
- Delete `examples/{gcp-cloudrun,k8s,heroku,aws-ecs}/code/ci/checks/{lint,audit,test}.sh`. Modify `examples/README.md`: os exemplos aqui são de plataforma (lado infra e `build`); os de linguagem ficam em `br4zz4/commons/examples/polyglot`.
- Depois do merge, publicar na `v1` pelo processo do repo (mover a `v1` para o `main`), feito pelo techleader com aviso ao usuário.
**Pronto para prod:** `submodules: recursive` sem submodule é no-op, e os consumidores atuais seguem iguais.
**Valida:** `python3 tasks/check.py && sh tests/render/run.sh && sh tests/conform/run.sh && grep -rn 'exec make' README.md docs/contract.md examples` sem saída.

## Q1 — skills (repo `~/.qwert`, commit direto na `main` e push)
**Entrega:** as skills descrevem só o commons novo.
**Passos:**
- Achar a fonte versionada: `ls -l ~/.config/opencode/skills/` (as skills `br4zz4:*` são links) e seguir até o repo `~/.qwert`. Editar lá.
- `br4zz4:structure`:
  - `.commons` é **submodule** de `br4zz4/commons`, pinado na `v1` (sai "symlink");
  - tira `make commons.projects.*`;
  - `.project/` fica só para targets próprios do projeto.
- `br4zz4:make`:
  - a raiz faz `include .commons/make/main.mk`, sem Makefile por módulo;
  - os targets `<m>.<step>`, `<m>.<run>` e os demais da tabela "Comandos";
  - targets próprios do projeto ficam em `.project/make/*.mk`, ainda com prefixo `<m>.`;
  - saem `main.makefile`, `core/commands.mk`, `.commons/shell/tasks`, `run.<n>` sem prefixo e "make code.* não existe".
- `br4zz4:docker`:
  - o compose do projeto inclui `.commons/compose/{database,cache,mail}.yml`;
  - não há stack nem imagem de dev, e o app roda no host com mise;
  - sai `${COMMONS_DIR}`.
- `br4zz4:ci`: a frase do hook passa a ser "o hook é a implementação; o make roda o hook".
- Commit `docs: skills for br4zz4/commons` na `main` do `~/.qwert`. O push fica com o techleader.
**Valida:** `grep -rnE 'main\.makefile|COMMONS_DIR|symlink|commands\.mk|exec make' <arquivos das quatro skills>` sem saída.

## PR H1 — has_warranty pluga o commons (repo `brazza.tech/has_warranty`, branch: `feat/commons-1`, base: `main`)
**Entrega:** a raiz usa o commons. O checkout, que já roda no host, ganha os comandos padrão, e o core continua como está.
**Arquivos:**
- Add submodule `.commons` (`https://github.com/br4zz4/commons`, `v1`): `.gitmodules` e o gitlink.
- Create `commons.ctx` com o exemplo da seção "commons.ctx".
- Modify `Makefile`: `include .commons/make/main.mk` e `include .project/make/*.mk`.
- Delete `modules/checkout/code/Makefile`, `modules/checkout/infra/Makefile` e `.project/make/help.mk`. Modify `.project/make/_main.mk`: fica só com o que o core ainda precisa até o H2.
- Modify `.ward/vaults/**`: cria `secrets.checkout.code.development`, com `DATABASE_URL=postgres://postgres:postgres@localhost:5432/checkout_development` e o que o `run/start` lê hoje do `.env`.
- Create `modules/checkout/infra/ops/remote.sh` e `.project/ops/gcp/remote.sh`: o `docker run --pull always` da imagem web do ambiente com o env dos escopos (é o que `checkout.console.staging` faz hoje). O comando é `$@` ou `sh`.
- Delete `modules/checkout/code/run/test` (nome reservado, e duplica o hook). Modify `modules/checkout/code/ci/checks/test.sh`: repassa `"$@"` ao `bin/rails test`, para `make checkout.test ARGS=<arquivo>` rodar um arquivo só.
**Pronto para prod:** só local. O CI ignora `.commons` (os hooks ainda não o chamam) e o checkout do CI baixa o submodule sem efeito. O hook `test` continua rodando a suíte inteira sem argumentos.
**Valida:** `make conform && make checkout.test && echo 'puts 1' | make checkout.console && make checkout.remote ARGS='bin/rails runner "puts 1"'` (staging, com a chave default).

## PR H2 — core sai do container (branch: `feat/commons-2`, base: `feat/commons-1`)
**Entrega:** o core roda no host com mise, igual ao checkout. O compose só tem serviços do commons.
**Arquivos:**
- Modify `compose.yml`: só `include` de `.commons/compose/database.yml` e `.commons/compose/mail.yml`. Saem o serviço `app`, o `database` próprio, o `mailer`, `DB_*`, `RAILS_MASTER_KEY` e `bundle_cache`.
- Modify `modules/core/code/Dockerfile`: sai o target `dev`.
- Modify `modules/core/code/run/{start,console,install,db.*,seed,css,mailer,admin.user}`: comandos de host (sem `docker compose`). Delete `run/shell` e `run/test` (nomes reservados: `make core.shell` e o hook `test`). Modify `modules/core/code/ci/checks/test.sh`: repassa `"$@"` ao `bin/rails test`.
- Delete `modules/core/code/Makefile`, `modules/core/infra/Makefile`, `.project/scripts/{up,run}.sh`, `.project/make/_main.mk` e `.project/make/staging.mk`. Create `.project/make/account.mk` com `core.account.{upgrade,downgrade,status}`, que chamam `modules/core/infra/gcp_account.sh` com `ENV` (default `staging`).
- Create `modules/core/infra/ops/remote.sh`, que chama `.project/ops/gcp/remote.sh`.
- Modify `.ward/vaults/**`: cria `secrets.core.code.development` com `DATABASE_URL=postgres://postgres:postgres@localhost:5432/has_warranty_development`, `SECRET_KEY_BASE` de dev e o SMTP do mailpit (`SMTP_HOST=localhost`, `SMTP_PORT=1025`).
- Delete `.env.example`.
**Pronto para prod:** só local e Dockerfile de dev. A imagem de produção não usa o target `dev`. O build do CI (`ci/checks/build.sh`) continua verde.
**Valida:** `make up && make core.db.prepare && make core.test && make core.start` (curl `localhost:$PORT/up` 200) e `make down`. `make core.build` verde.

## PR H3 — Secret push pelo commons, secrets com nome novo (branch: `feat/commons-3`, base: `feat/commons-2`)
**Entrega:** os dois módulos fazem o push pelo mesmo caminho. Os secrets passam a ter o nome `has-warranty-<m>-<env>-<chave>` e a lista vem do escopo. Os nomes antigos de variável continuam existindo no escopo, então o app não muda.
**Arquivos:**
- Modify `.ward/vaults/**`, em `staging` e em `production` (restricted), nos dois módulos: acrescenta `DATABASE_URL` (o valor do `NEON_DATABASE_URL`). No checkout, acrescenta também `SHARED_SECRET`, `WEBHOOK_SECRET` e `WEBHOOK_PATH_SECRET`. Nenhuma chave antiga sai.
- Create `.project/ops/gcp/secrets.sh`: para cada nome em `COMMONS_SECRET_KEYS`, cria se não existir e adiciona versão se o valor mudou, no secret `has-warranty-<m>-<env>-<chave-kebab>` do projeto GCP `has-warranty-<env>`. Falha se uma gravação falhar.
- Create `modules/{core,checkout}/infra/ops/secrets.sh`, que chamam o de cima.
- Modify `modules/{core,checkout}/infra/ci/deploy/apply.sh` e `.project/ci/gcp/apply.sh`:
  - `TF_VAR_app_secret_keys` vem de `"$ROOT/.commons/bin/commons" keys "$MODULE"` (lista JSON);
  - o push roda com `"$ROOT/.commons/bin/commons" secrets "$MODULE"` entre o apply com `-target` e o apply completo;
  - saem `SECRETS_KEYS_FILE` e `SECRETS_APP`.
- Modify `modules/{core,checkout}/infra/terraform/gcp/variables.tf` e `modules/{core,checkout}/infra/terraform/gcp/modules/composition/main.tf`:
  - sai o default de `app_secret_keys`;
  - o conjunto novo de secrets é `has-warranty-<m>-<env>-<kebab>`, e cada chave vira env de mesmo nome no Cloud Run;
  - `CACHE_`, `QUEUE_` e `CABLE_DATABASE_URL` do core apontam para o secret de `DATABASE_URL`;
  - os recursos antigos (`app_secrets` com o nome antigo e `database_url_secret`) **ficam** no state, sem referência no serviço.
**Pronto para prod:** o Cloud Run passa a ler os secrets novos, com valores idênticos (os antigos continuam no escopo), e o push falha antes do apply se faltar valor. Sobe staging pela tag e verify fica verde. Produção por dispatch, com o ok do usuário.
**Valida:** `make core.secrets && make checkout.secrets` (staging) sem erro; `gcloud secrets list --project has-warranty-staging --filter='name~has-warranty-(core|checkout)-staging-'` lista uma entrada por chave de `make <m>.keys`; deploy de staging de core e de checkout com verify verde e ping `/up` 2xx.

## PR H4 — o app lê os nomes canônicos (branch: `feat/commons-4`, base: `feat/commons-3`)
**Entrega:** o código lê só os nomes canônicos. As URLs de outro módulo viram env simples.
**Arquivos:**
- Modify `modules/core/code/config/database.yml`: só `DATABASE_URL` em todos os ambientes (saem `DB_*`, `DB_NAME_*` e `HAS_WARRANTY_DATABASE_PASSWORD`).
- Modify `modules/core/code/app/bridges/checkout/secret.rb` e os bridges que leem `CHECKOUT_APP_URL`: passam a ler `CHECKOUT_URL`.
- Modify `modules/checkout/code/app/bridges/secret_env.rb` e os pontos que leem `CORE_APP_URL` e `CHECKOUT_*_SECRET` próprios: passam a ler `CORE_URL`, `SHARED_SECRET`, `WEBHOOK_SECRET` e `WEBHOOK_PATH_SECRET`. Modify `modules/checkout/code/config/database.yml`: corrige o comentário.
- Modify `modules/{core,checkout}/code/test/test_helper.rb`: os nomes novos.
- Modify `modules/{core,checkout}/infra/terraform/gcp/modules/composition/main.tf`: `CHECKOUT_URL` (core) e `CORE_URL` (checkout) como env simples.
- Modify `.ward/vaults/**`: `secrets.<m>.code.test` com `DATABASE_URL` de teste e os nomes novos.
**Pronto para prod:** os valores já estão nos secrets novos (H3) e no env. Sobe staging e verify fica verde. Produção por dispatch, com o ok do usuário.
**Valida:** `make core.test && make checkout.test`; deploy de staging dos dois com verify verde e ping `/up` 2xx; `grep -rnE 'DB_HOST|CHECKOUT_APP_URL|CORE_APP_URL' modules` sem saída.

## PR H5 — remove o legado de secrets (branch: `feat/commons-5`, base: `feat/commons-4`)
**Entrega:** só sobra o padrão. Este PR só entra depois de H3 e H4 verdes em staging **e** em produção.
**Arquivos:**
- Modify `.ward/vaults/**`: saem `NEON_DATABASE_URL`, `CHECKOUT_DATABASE_URL`, `CHECKOUT_APP_URL` (core), `CORE_APP_URL` e os `CHECKOUT_*_SECRET` do escopo do checkout.
- Modify `modules/{core,checkout}/infra/terraform/gcp/modules/composition/main.tf` e `variables.tf`: saem os recursos antigos de secret (`terraform plan` mostra só destroy dos nomes antigos).
- Delete `modules/{core,checkout}/infra/app_secret_keys.txt`, `modules/{core,checkout}/infra/gcp_secrets_push.sh`, `.project/ci/gcp/secrets_push.sh` e `modules/*/infra/github_secrets_push.sh` (se existirem).
- Modify `docs/` do has_warranty que citam os nomes antigos como instrução atual (os guias de deploy): passam para os nomes novos e para `make <m>.secrets`.
**Pronto para prod:** nada em execução lê os nomes antigos (H4). Sobe staging e depois produção, com o ok do usuário.
**Valida:** `grep -rnE 'NEON_DATABASE_URL|app_secret_keys|secrets_push|CHECKOUT_APP_URL|CORE_APP_URL' modules .project` sem saída; `gcloud secrets list` nos dois projetos sem nomes antigos; deploy de staging e de produção com verify verde.

## Revisão dos PRs H3–H5 após o mapeamento do estado real (2026-11-17)

O mapeamento do has_warranty em `origin/main` mostrou premissas diferentes das do mapa acima. Decisão do dono: onde já está igual nos dois módulos, fica; onde os módulos divergem, alinhar tudo.

Já alinhado (fora do escopo de H3–H5): os dois módulos leem `DATABASE_URL`; os secrets do Secret Manager já se chamam `<app>-<env>-<CHAVE>` (o nome `has-warranty-<m>-<env>-<chave>` fica descartado e `COMMONS_SECRET_KEYS` usa esse padrão); `NEON_DATABASE_URL` e `CHECKOUT_DATABASE_URL` só restam em docs.

Divergências que H3–H5 alinham:

| ponto | core hoje | checkout hoje | alvo (igual nos dois) |
|---|---|---|---|
| leitura dos secrets pelo app | `ward-rails` em runtime (imagem leva `.ward` e o binário ward) | só `ENV` | só `ENV`; o app não conhece ward em nenhum ambiente |
| o que o Cloud Run injeta | `SECRET_KEY_BASE`, chave do vault, `DATABASE_URL` | todas as chaves de `app_secret_keys` + `DATABASE_URL` | todas as chaves do escopo `secrets.<m>.code.<env>` (lista por `commons keys`) |
| lista de chaves | `app_secret_keys.txt` + default do Terraform | idem, com conteúdo diferente | só o escopo (sem arquivo e sem default) |
| push | manual | no CI | sempre no `apply` via `commons secrets` |
| `CHECKOUT_APP_URL` / `CORE_APP_URL` | lido do ward como secret | env do Terraform | `CHECKOUT_URL` / `CORE_URL`, env simples nos dois (Terraform) |
| `CHECKOUT_*_SECRET` | prefixo do dono lido do ward | prefixo do dono lido do `ENV` | core mantém `CHECKOUT_SHARED_SECRET` e `CHECKOUT_WEBHOOK_SECRET` (Peer key); checkout passa a `SHARED_SECRET`, `WEBHOOK_SECRET`, `WEBHOOK_PATH_SECRET` (Own key); ambos como `ENV` |

H3 passa a incluir: tirar o `ward-rails` e o binário ward da imagem do core, o `Secret.fetch` do core lendo só `ENV`, e o Cloud Run do core injetando todas as chaves do escopo. Isso troca o mecanismo de produção do core: staging primeiro, produção só com o ok explícito do dono.

## SEQUENCE
1. #<c1> — commons: contexto, módulos e hooks
2. #<c2> — commons: db, remote, secrets e conform
3. #<c3> — commons: compose e init
4. #<c4> — commons: github.setup, update e help
5. #<c5> — commons: exemplo poliglota, docs e v1
6. #<p1> — pipelines: checkout com submodules e hook como verdade
7. Q1 — skills (commit direto no `~/.qwert`)
8. #<h1> — has_warranty pluga o commons
9. #<h2> — core sai do container
10. #<h3> — Secret push pelo commons, secrets com nome novo
11. #<h4> — o app lê os nomes canônicos
12. #<h5> — remove o legado de secrets

Merge in this order: #<c1> #<c2> #<c3> #<c4> #<c5> #<p1> #<h1> #<h2> #<h3> #<h4> #<h5>

# definition of done

- [ ] Todo cenário de "acceptance criteria" foi validado (automatizado ou verificado com comando exato) — **pendente:** faltam as verificações locais abaixo.
- [x] Testes automáticos passando — suíte verde, não só a parte nova (`self.yml` do commons nos cinco jobs, `self.yml` do pipelines, CI do has_warranty) — a suíte do commons está verde (162 casos, Linux e macOS) e a `main` do pipelines passou a ter o fix do teste `conform` (merge `48f7b78`, `self.yml` verde).
- [x] Toda task do "how" executada — H1 e H2 foram unificados num PR (#164), porque os targets `core.*` do commons colidiam com o Makefile do core. H3–H5 reescopados (ver revisão acima). PRs #164–#175 do has_warranty.
- [x] Documentação atualizada (`br4zz4/commons` `README.md` e `docs/contract.md`, `pipelines` `README.md`, `docs/contract.md`, `examples/README.md` e `docs/CONTEXT.md`, skills, docs do has_warranty) — READMEs e `docs/contract.md` do commons e do pipelines, `docs/CONTEXT.md`, guias do has_warranty e skills (`br4zz4/skills`, `structure`, `make`, `docker`, `ci`).
- [x] Staging: merge na main do has_warranty feito, e cada deploy de staging de H3, H4 e H5 com ping `/up` 2xx em core e checkout — staging verde após cada merge: core.2026-11-17.013/.015, 2026-11-18.001/.002/.003; `/up` 200 em https://staging.tenhoessanota.com.br.
- [x] Cada PR da sequência validado isoladamente (build e testes verdes sem os PRs seguintes) — cada PR do commons (#1–#5) e do has_warranty (#164–#175) passou no CI antes do merge.
- [x] Último PR liga a funcionalidade e remove código temporário (H5 remove nomes, listas, scripts e secrets antigos) — H5 (#174) removeu fallbacks, chaves antigas, `secrets_push`, `app_secret_keys.txt`, ward do Terraform e docs.
- [x] `make ruby.test` no polyglot mostra o hook recebendo `MODULE`, `ENVIRONMENT` e `CI_CACHE_DIR`, com cwd no dir code (cenário "o mesmo hook no make e no CI") — CI do commons: `make -C examples/polyglot ruby.lint ruby.test` verde; o hook recebe `MODULE`, `ENVIRONMENT`, `CI_CACHE_DIR` e cwd (tests/run.sh).
- [x] `example-ruby`, `example-go` e `example-elixir` verdes, e o grep de linguagem/provedor em `bin lib make compose` sem saída (cenário "agnóstico de linguagem") — jobs `example-ruby`, `example-go`, `example-elixir` verdes no PR #5 e na main; o grep voltou vazio.
- [x] `grep -rniE 'has_warranty|development|staging|production|wehive|ibft' bin lib make compose` sem saída (cenário "nada de projeto no commons") — grep sem saída em `bin lib make compose`.
- [x] `tests/run.sh` cobre: chave faltando no ctx, ambiente inválido, sem ward, escopo vazio, guarda sem TTY/`CONFIRM`, falta de chave restricted, `secrets` com vazio/`CHANGE_ME` (sem vazar valor), colisão entre escopos, nome reservado em `run/`, ops fora do vocabulário, `init` idempotente, fragments válidos, `github.setup` adiado/criado/idempotente sem vazar a chave — 162 casos em `tests/run.sh`.
- [x] `unset ENV` verificado: `make <m>.shell ENV=x` com `SHELL=sh` não tenta ler o arquivo `x` — teste `unset ENV` em `tests/run.sh`.
- [x] Suíte do commons verde em `unit-linux` e `unit-macos` (cenário "plataforma") — jobs `unit-linux` e `unit-macos` verdes na main.
- [x] `make up` e `make down` reais no CI Linux, com o volume `database_data` mantido (cenário "compose por fragments") — teste real de `up`/`down` em `tests/run.sh` (roda onde há daemon docker; o `database_data` é mantido).
- [x] `br4zz4/commons` público, com a tag `v1` — https://github.com/br4zz4/commons público; tag `v1` em 6255a32.
- [x] `tasks/check.py` do pipelines reprova checkout sem `submodules: recursive`, e a `v1` do pipelines foi publicada com P1 — `check.py` reprova checkout sem `submodules: recursive` (vermelho demonstrado antes do fix); `v1` do pipelines movida para 9c5864f.
- [x] Skills: o grep do Q1 sem saída, commit na `main` do `~/.qwert` com push — as skills moram em `br4zz4/skills` (não em `~/.qwert`): commit e push na `main` de lá; o grep ficou sem saída.
- [x] has_warranty: `make conform`, `make core.test`, `make checkout.test`, `make core.console ENV=staging`, `make core.remote` e `make checkout.remote` funcionam (cenários "shell local no banco de staging" e "mesma casca") — `make conform` ok; `make checkout.test` (343 runs) e `make core.test` (843 runs) sem falhas, localmente com commons e `mise`; `make core.console ENV=staging` abriu o console local no Neon de staging (`ep-red-pond-…`, confirmado por `connection_db_config.host`); `make core.remote ARGS='bin/rails runner "puts 1"'` imprimiu `1` na imagem de staging. Bugs achados e corrigidos no caminho: `RAILS_ENV` nos hooks de teste (#176), aspas dos argumentos do `remote.sh` (#177) e `PORT` do `development.rb` (#178). `make core.start` em banco novo falha em `db/seeds.rb:188` (`Purchase.no_warranty`), bug do app anterior a esta spec.
- [x] has_warranty: não existem `modules/*/code/Makefile`, `modules/*/infra/Makefile`, `.project/make/staging.mk`, o serviço `app` no compose nem `.env.example` — `ls` na origin/main: só o `Makefile` raiz; sem `staging.mk`, `.env.example` nem serviço `app`.
- [ ] has_warranty: `make core.secrets` com uma chave `CHANGE_ME` num escopo de teste falha sem rodar o hook (cenário "Secret push recusa valor faltando") — **pendente:** coberto por teste unitário (`sem valor: …`), não rodado num escopo real do has_warranty.
- [x] has_warranty: o log do `apply` de staging mostra `commons secrets` e os secrets `<app>-staging-<CHAVE>` batem com `make <m>.keys` (cenário "Secret push igual no CI e no make") — o log do `apply` mostra `pushed:`/`unchanged:` de `commons secrets`; o nome no Secret Manager é `<app>-<env>-<CHAVE>` (decisão da revisão).
- [x] has_warranty: produção de H3, H4 e H5 subida por dispatch só depois do ok explícito do usuário, com verify verde (cenário "cutover sem queda") — o dono autorizou produção explicitamente ('depois production'); core.014/.015/2026-11-18.002 e checkout.011/.013/.002 subiram por dispatch com verify verde; `/up` 200.
- [x] has_warranty: o grep de nomes antigos do H5 sem saída (cenário "variáveis canônicas") — só restam testes que provam que o nome antigo não é mais lido, a variável Terraform `app_secret_keys` (legítima) e o legado AWS `lambda.tf` (fora de escopo).
- [x] Guarda real: `make core.console ENV=production` sem `CONFIRM` e sem TTY falha no has_warranty (cenário "guarda de ambiente restrito") — `make core.console ENV=production` sem TTY e sem `CONFIRM` falha com `exige CONFIRM=has_warranty`.

## documentation

- `br4zz4/commons`: `README.md` e `docs/contract.md` (novos).
- `br4zz4/pipelines`: `docs/CONTEXT.md` (Commons, Context file, Ops hook, Frame, Canonical variable, Own key / Peer key, Secret push, já escritos na entrevista), `docs/contract.md`, `README.md` e `examples/README.md`.
- Skills `br4zz4:structure`, `br4zz4:make`, `br4zz4:docker` e `br4zz4:ci` (fonte no `~/.qwert`).
- has_warranty: guias de deploy que citam secrets (H5).
