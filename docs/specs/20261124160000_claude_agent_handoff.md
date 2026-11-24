---
title: Autofix com insumo real e handoff para um Agent run do Claude no GitHub
status: proposed
created: 2026-11-24
updated: 2026-11-24
owner: "@oporpino"
certainty: high
---

# Autofix com insumo real e handoff para um Agent run do Claude

> **TLDR**: a Critical issue passa a trazer a saída do hook que falhou. Quando o Autofix não abre PR, um Agent run do Claude (`anthropics/claude-code-action`, assinatura do Claude) assume a issue e abre um PR draft para revisão humana. Também se destravam três pontos que fazem o Autofix "parecer que não funciona".

# what

Como dono dos projetos br4zz4 (piloto: lunetamagica), quero que toda Critical issue chegue com a falha real e que, quando o Autofix desistir, um agente do Claude integrado ao GitHub continue o trabalho até um PR revisável, para que um bug crítico nunca morra num comentário "gave up".

Repos tocados:
- `br4zz4/pipelines` (principal, onde esta spec mora): PRs 1 a 4 e a release `v2`.
- `brazza-tech/lunetamagica`: PR 5.

## out of scope

- **Agent HQ / Copilot coding agent.** A org tem Copilot Business com 0 seats, e o agente Claude do Agent HQ cobra na assinatura do Copilot, não na do Claude.
- **Mudar o escopo do Autofix.** `e2e/`, `ci/`, `run/`, `mise.toml` e tudo fora do `code_dir` continuam proibidos, porque o Autofix faz automerge. Esses casos vão para o Agent run.
- **Mudar modelo, prompt ou limites do Autofix** (`actions/agent/prompt.md`, opus, 40 turns).
- **Fazer `run/regression` escrever `failures.md`.** A Hook output cobre esse caso.
- **Ligar o Agent run no has_warranty.** Vira issue de follow-up, depois do resultado do piloto.
- **Agent run com automerge**, em qualquer caso.
- **Agent run editando `.github/workflows/**` ou `.ward/**`.**

## acceptance criteria

    Cenário: e2e falha sem failures.md e a issue traz a saída do hook
      Dado um projeto com promote e um hook e2e que imprime 1 000 linhas e sai com código 1 sem escrever failures.md
      Quando o promote abre a Critical issue
      Então o corpo tem a seção "## output" com as últimas 300 linhas da saída
      E o trecho tem no máximo 20 000 caracteres, com e-mails, IPs e tokens mascarados
      E não aparece "no failures.md was written; see the run"

    Cenário alternativo: failures.md existe e tem prioridade
      Dado um hook regression que escreve tmp/artifacts/failures.md e falha
      Quando o promote abre a Critical issue
      Então a seção "## failures" traz o failures.md
      E não existe a seção "## output"

    Cenário alternativo: segredo do ambiente não vaza na Hook output
      Dado o hook e2e com E2E_PASSWORD="s3nh4-curta" e DATABASE_URL="postgres://u:p@h/db" no ambiente, ambos impressos na saída
      Quando a Hook output é gravada
      Então tmp/artifacts/output.log contém "<redacted>" no lugar dos dois valores

    Cenário alternativo: gravar a saída não muda o resultado do hook
      Dado um hook regression que sai com código 3
      Quando o step roda o hook
      Então o step falha (o código de saída do hook é preservado)
      E a saída continua aparecendo no log do job
      E um hook que sai com 0 continua verde

    Cenário alternativo: hooks fora de regression e e2e não gravam saída
      Dado o step test, lint ou deploy
      Quando o hook roda
      Então não existe tmp/artifacts/output.log

    Cenário: verify falha sem motivo e o comentário explica
      Dado um autofix cujo verify terminou failure com reason vazio
      Quando o publish roda
      Então a issue recebe "[autofix] rejected: verify failed before a verdict (<run url>)"

    Cenário: Autofix desiste e há handoff
      Dado um projeto com a chave agent no modules.json
      E uma Critical issue em que o fix termina em gave_up
      Quando o publish comenta "[autofix] gave up: …"
      Então a issue recebe o label agent:claude, aplicado com o GH_PIPELINES_TOKEN
      E o comentário "[autofix] handed off to Claude"
      E o workflow claude.yml do projeto inicia um Agent run nessa issue

    Cenário alternativo: handoff também em rejected (verify), failed e blocked
      Dado um projeto com a chave agent
      Quando o Autofix termina em rejected pelo verify, em failed, ou o select pula a issue por autofix:blocked
      Então a issue recebe o label agent:claude e o comentário "[autofix] handed off to Claude"

    Cenário alternativo: sem handoff quando o problema é da própria issue
      Dado uma Critical issue rejeitada no select por falta de label module:<m>, módulo desconhecido ou remetente sem permissão
      Quando o Autofix termina
      Então a issue não recebe agent:claude

    Cenário alternativo: projeto sem a chave agent mantém o comportamento atual
      Dado um projeto sem a chave agent
      Quando o Autofix desiste
      Então nenhum label agent:claude é aplicado e não existe .github/workflows/claude.yml

    Cenário: Agent run abre PR draft
      Dado a issue com agent:claude e module:core
      Quando o claude.yml roda
      Então o Claude lê a issue e os logs do run citado nela (actions: read)
      E roda os testes com ci-hook test e ci-hook lint
      E abre um pull request draft de uma branch claude/issue-<n>-…, com "Refs #<n>" no corpo
      E o PR não tem auto-merge nem o label autofix
      E o PR dispara o pr.yml (check/pr) normalmente

    Cenário alternativo: teto diário do handoff
      Dado um projeto com agent.max_per_day = 10
      E 10 Agent runs por label nas últimas 24 horas
      Quando uma issue recebe agent:claude
      Então o Agent run não começa
      E a issue recebe "[claude] skipped: daily cap reached (10/10)"

    Cenário: menção @claude por quem tem write, sem teto
      Dado um PR aberto e um colaborador com write
      Quando ele comenta "@claude ajusta o nome do método" (mesmo com o teto do handoff atingido)
      Então o Agent run faz commits na branch desse PR

    Cenário alternativo: menção por quem não tem write
      Dado um usuário sem write
      Quando ele comenta "@claude …"
      Então nenhum Agent run começa

    Cenário alternativo: Agent run não mexe em workflows nem no ward
      Dado um Agent run cuja tarefa sugere editar .github/workflows/pr.yml ou .ward/config.yaml
      Quando o Claude tenta Edit ou Write nesses caminhos
      Então a ferramenta é negada (deny rules)
      E se um PR do Agent run mudar um workflow gerado, o conform do pr.yml falha

    Cenário: render do claude.yml
      Dado o modules.json com "agent": {"max_per_day": 10}
      Quando o render roda
      Então gera .github/workflows/claude.yml com os gatilhos issue_comment, pull_request_review_comment, pull_request_review e issues (labeled)
      E o autofix.yml gerado passa handoff: true

    Cenário alternativo: chave agent inválida
      Dado "agent": {"max_per_day": -1} ou "agent": {"foo": 1}
      Quando o render roda
      Então falha com RenderError que nomeia a chave

    Cenário: lunetamagica com fluxo destravado
      Dado o PR 5 mergeado
      Quando o Autofix abre um PR
      Então o comentário é "[autofix] opened <url>", sem "auto-merge unavailable"
      E o .github/modules.json tem uma única chave autofix e a chave agent

    Cenário alternativo: macOS e Linux
      Dado o clone do pipelines
      Quando roda sh tests/<x>/run.sh no macOS (zsh, BSD sed/tail) e no Linux (CI)
      Então as suítes passam nos dois

# why

O Autofix do lunetamagica rodou em 8 Critical issues reais entre 21 e 24/nov e abriu 1 PR, o #106 da #104. As outras 7 terminaram sem PR, e o problema não foi o agente:

- 5 desistências (#105, #112, #129, #142, #143) vieram de issues abertas pelo promote com "no failures.md was written; see the run". O `run/regression` nunca escreve `failures.md`. O `e2e_helper.rb` só grava no `teardown`, então erro de carga não deixa rastro. E o agente não tem rede para ler o log do run. Sem a falha, nenhum agente conserta.
- #112 (de novo) e #113 tinham a causa em `e2e/` ou em infra/secret, que o Autofix não pode tocar, com razão, porque faz automerge. Hoje nada assume esses casos.
- O PR #106 precisou de merge manual porque o repo não tem "Allow auto-merge". A #104 também recebeu "[autofix] rejected: " com o motivo vazio.

O pedido era usar "os agents do GitHub" com a assinatura do Claude. O Agent HQ não usa a assinatura do Claude e exige seat de Copilot. A `anthropics/claude-code-action` usa `CLAUDE_CODE_OAUTH_TOKEN`, que já existe em `<ns>:secrets.ci.agent`, a Claude GitHub App já está instalada na org, e ela itera em comentários de issue e PR. O desenho mantém o Autofix como o caminho provado (red/green + automerge) e põe o Agent run como continuação supervisionada.

# how

Decisões:
- **Feature flag:** a mudança é aditiva e ligada por projeto via a chave `agent` do `modules.json`. Sem a chave, o render e o Autofix geram exatamente o que geram hoje. Não há Flipper, porque não é código de app.
- **Telas:** sem telas (só CI). O passo de staging do lunetamagica é "sem telas afetadas".
- **Plataforma:** os scripts são POSIX `sh` (sem `pipefail`) e Python 3 da stdlib. O `tail`, o `sed` e o `tee` usados funcionam iguais em BSD (macOS) e GNU (runner Ubuntu).
- **Ordem:** PRs 1 a 4 empilhados no pipelines → merge → `sh tasks/release.sh v2 --push` → PR 5 no lunetamagica, com base `main`.

## PR 1 — Motivo do verify e handoff preparado no publish (branch: `fix/autofix-verify-reason`, base: `main`)

**Repo:** `br4zz4/pipelines`
**Entrega:** o `publish.sh` nunca comenta "rejected: " vazio.
**Arquivos:**
- Modify `actions/publish/publish.sh`: no ramo `VERIFY_RESULT = failure`, se `VERIFY_REASON` estiver vazio, use `verify failed before a verdict`.
- Test `tests/publish/run.sh`: caso "verify failure com reason vazio" → comentário `[autofix] rejected: verify failed before a verdict (<run>)`.

**Passos:** teste que falha → correção → `sh tests/publish/run.sh` verde → commit `fix: autofix verify reason never empty`.
**Pronto para prod:** só muda o texto de um comentário.
**Valida:** `sh tests/publish/run.sh && shellcheck -S warning actions/publish/publish.sh`

## PR 2 — Hook output na Critical issue (branch: `feat/hook-output`, base: `fix/autofix-verify-reason`)

**Repo:** `br4zz4/pipelines`
**Entrega:** um `regression`/`e2e` que falha deixa `tmp/artifacts/output.log` redigido, e o `critical.py` usa esse arquivo quando não há `failures.md`.
**Arquivos:**
- Modify `actions/hook/hook.sh`: para `STEP` em `regression|e2e`:
  - `mkdir -p tmp/artifacts`;
  - roda o hook com `{ <hook> 2>&1; echo $? > "$RC"; } | tee "$RAW"`, onde `RC` e `RAW` são arquivos em `mktemp -d`;
  - grava `tmp/artifacts/output.log` com a redação aplicada (abaixo);
  - sai com o código lido de `RC`.
  - Redação: todo valor de variável de ambiente com pelo menos 8 caracteres, cujo nome casa `PASSWORD|SECRET|TOKEN|KEY|URL|DSN` (case-insensitive), vira `<redacted>`. É feita por um script Python lendo `os.environ` (sem `sed` com valor interpolado).
  - Os demais steps continuam exatamente como hoje.
- Create `actions/hook/redact.py`: lê o arquivo bruto, substitui os valores (do mais longo para o mais curto) e escreve `output.log`.
- Modify `actions/critical/critical.py`:
  - `open` ganha `--output FILE`;
  - sem `failures.md` válido e com `output` existente, o corpo ganha `## output` com `tail` das últimas 300 linhas, passado por `mask()` e truncado em `LIMIT` (20 000);
  - sem os dois, mantém `NO_FAILURES`.
- Modify `actions/critical/action.yml`: input `output` (default `''`).
- Modify `.github/workflows/promote.yml`: os dois passos `critical` passam `output: failures/failures-<hook>/output.log`. O upload `tmp/artifacts` já leva o arquivo.
- Test `tests/actions/run.sh` (ou `tests/hook/run.sh`, se o tester preferir separar, registrando no `self.yml`):
  - exit code 3 preservado;
  - 0 continua 0;
  - `output.log` existe só para regression/e2e;
  - a saída também vai para stdout;
  - redação de `E2E_PASSWORD` e `DATABASE_URL`.
- Test `tests/critical/run.sh`:
  - failures.md tem prioridade;
  - output com 1 000 linhas → 300 linhas na seção `## output`;
  - máscara;
  - truncamento em 20 000;
  - sem os dois → `NO_FAILURES`.

**Passos:** testes que falham → implementação → testes verdes → commit `feat: critical issue quotes the hook output`.
**Pronto para prod:** sem `output.log` (projetos antigos, hooks verdes), o comportamento é o atual. O código de saída é preservado.
**Valida:** `sh tests/actions/run.sh && sh tests/critical/run.sh && python3 -m py_compile actions/*/*.py && shellcheck -S warning actions/*/*.sh`

## PR 3 — Agent run: action, render e workflow gerado (branch: `feat/agent-run`, base: `feat/hook-output`)

**Repo:** `br4zz4/pipelines`
**Entrega:** a chave `agent` no `modules.json` gera `.github/workflows/claude.yml`, que roda a `claude-code-action` com a assinatura do Claude, os serviços e toolchain do módulo, e o teto diário para runs por label. Ainda ninguém aplica o label automaticamente.

**Arquivos:**
- Create `actions/agent-run/action.yml` (composite), inputs `vault`, `key`, `modules`, `max_per_day`, `token`. Passos:
  1. `select`: roda `select.py` e emite `outcome` (`run`/`skip`), `module`, `code_dir`, `services` e `reason`.
  2. `secrets`: `br4zz4/setup-ward@v1` com `export-key: 'false'` e os escopos `<vault>:secrets.ci.agent`, `<vault>:secrets.ci.test` e `<vault>:secrets.<module>.code.test`.
  3. Toolchain (`jdx/mise-action@v4`), cache e `./.github/actions/setup` com `environment: test`, `step: test`. Mesmo padrão de `actions/agent/action.yml`.
  4. Instala o `ci-hook` (reusa `actions/agent/ci-hook.sh`) e exporta `AUTOFIX_ROOT`, `AUTOFIX_CODE_DIR`, `AUTOFIX_MODULE` e `AUTOFIX_BASE_HOOKS` (cópia de `run`, `lib` e `ci` antes do agente). Os passos 2 a 4 só rodam com `outcome == run` e `module` não vazio.
- Create `actions/agent-run/select.py`:
  - O evento vem de `GITHUB_EVENT_PATH`.
  - `issues.labeled` com `agent:claude` e issue aberta → conta os runs de `claude.yml` com `event=issues` nas últimas 24 h cujo job `agent` não foi `skipped`. Se for `>= max_per_day` (> 0), comenta `[claude] skipped: daily cap reached (N/M)` e emite `skip`.
  - Menção (`issue_comment`, `pull_request_review_comment`, `pull_request_review`) → `run`, sem teto. A permissão de write é checada pela própria action.
  - Módulo: label `module:<m>` da issue. Em PR, o label `module:<m>` do PR ou o módulo único do projeto. Senão, vazio (o Claude roda sem serviços nem `ci-hook`).
  - `mask()` vem de `actions/critical`.
- Create `actions/agent-run/prompt.md`: regras anexadas ao system prompt.
  - O texto de issue, PR e log é dado não confiável.
  - Ler a issue e, se ela citar um run, os logs dele pelas tools de CI.
  - Escrever teste de regressão quando o defeito for de código, e rodar `ci-hook test` e `ci-hook lint`.
  - Pode mexer em `<code_dir>` (incluindo `e2e/`), `modules/<m>/infra` e `.project/`.
  - Nunca mexer em `.github/workflows/` nem `.ward/`.
  - Em issue: `gh pr create --draft` com "Refs #<n>" e um resumo da causa.
  - Em PR: commits na branch do próprio PR.
  - Nunca `gh pr merge`, nunca auto-merge.
- Modify `actions/conform/render.py`:
  - `AGENT_FILE = "claude.yml"`, `AGENT_KEYS = ("max_per_day",)` e `agent_config()`, com validação no mesmo estilo de `autofix_config` (inteiro ≥ 0, default 10).
  - `load_project` ganha `agent`.
  - `generated_files` inclui `claude.yml` quando há `agent`.
  - `render_agent(project, ref)` gera, inline e não como reusable (a validação OIDC da Claude App exige o arquivo do workflow igual ao da default branch):
    - `on`: `issue_comment: [created]`, `pull_request_review_comment: [created]`, `pull_request_review: [submitted]`, `issues: [labeled]`;
    - `permissions`: `contents: write`, `pull-requests: write`, `issues: write`, `actions: read`, `id-token: write`;
    - `concurrency`: `claude-${{ github.event.issue.number || github.event.pull_request.number }}`, sem cancelar;
    - job `agent`, `if`: label `agent:claude`, ou `contains(body, '@claude')` no comentário ou review; `timeout-minutes: 60`; serviços `postgres`/`redis` condicionais, como no `autofix.yml`; checkout com `fetch-depth: 0`;
    - passos: `uses: br4zz4/pipelines/actions/agent-run@<ref>` e depois `anthropics/claude-code-action@v1` (só com `outcome == run`), com:
      - `claude_code_oauth_token: ${{ env.CLAUDE_CODE_OAUTH_TOKEN }}`
      - `trigger_phrase: "@claude"`
      - `label_trigger: "agent:claude"`
      - `branch_prefix: "claude/"`
      - `use_sticky_comment: true`
      - `additional_permissions: "actions: read"`
      - `claude_args`: `--model opus --max-turns 80`, `--append-system-prompt` com o conteúdo do `prompt.md`, `--allowedTools "Read,Edit,Write,Glob,Grep,Bash(ci-hook:*),Bash(git:*),Bash(gh pr create:*),Bash(gh pr view:*),Bash(gh run view:*),Bash(gh issue view:*)"` e `--disallowedTools "Edit(.github/workflows/**),Write(.github/workflows/**),Edit(.ward/**),Write(.ward/**),Bash(gh pr merge:*),WebFetch,WebSearch"`.
  - O caminho do prompt é resolvido por output do `agent-run` (`prompt_file`), que aponta para o arquivo da action.
- Modify `tasks/check.py` e `tasks/check_rendered.sh`, se listarem arquivos gerados, para aceitar `claude.yml`.
- Test `tests/render/run.sh` + `tests/render/fixtures/`:
  - fixture com `agent` → `claude.yml` igual ao esperado;
  - sem `agent` → nenhum `claude.yml` e saída idêntica à atual;
  - `max_per_day: -1` e chave desconhecida → RenderError.
- Test `tests/conform/run.sh`: `claude.yml` é aceito com `agent` e rejeitado sem.
- Create `tests/agent_run/run.sh` + fixtures (`gh` simulado no `PATH`):
  - label com teto atingido → `skip` + comentário;
  - abaixo do teto → `run`;
  - menção → `run` sem consultar runs;
  - resolução de módulo (label, módulo único, vazio).
- Modify `.github/workflows/self.yml`: passo `sh tests/agent_run/run.sh`.

**Passos:** testes que falham → implementação → testes verdes → commit `feat: agent run renders claude.yml from modules.json`.
**Pronto para prod:** nenhum projeto tem a chave `agent` ainda, então o render dos projetos não muda.
**Valida:** `sh tests/render/run.sh && sh tests/conform/run.sh && sh tests/agent_run/run.sh && python3 tasks/check.py && sh tasks/check_rendered.sh`

## PR 4 — Handoff do Autofix para o Agent run (branch: `feat/autofix-handoff`, base: `feat/agent-run`)

**Repo:** `br4zz4/pipelines`
**Entrega:** com `handoff: true`, todo desfecho sem PR que não seja culpa da issue aplica `agent:claude`.

**Arquivos:**
- Modify `actions/issue/issue.py`: `autofix:blocked` emite `outcome=blocked` (reason `blocked: needs a human`) no lugar de `skipped`. Os demais `skipped` ficam iguais.
- Modify `.github/workflows/autofix.yml`:
  - input `handoff` (boolean, default `false`);
  - o `publish` ignora `blocked`: o `if` passa a excluir `blocked` além de `skipped`;
  - novo job `handoff` (`needs: [select, publish]`, `if: always() && inputs.handoff && (select.outcome == 'blocked' || contains(fromJSON('["gave up","rejected","failed"]'), publish.outputs.outcome))`, onde o `rejected` do publish só vem do verify ou do select). Ele roda `br4zz4/pipelines/actions/handoff@v2` com `GH_PIPELINES_TOKEN` (PAT, para que o `labeled` dispare o `claude.yml`).
  - O `publish` exporta `outcome` como output do job.
  - O `rejected` vindo do select (módulo, label) **não** faz handoff: o job `handoff` exige `select.outcome` em `selected|blocked`.
- Create `actions/handoff/action.yml` + `handoff.sh`: `gh label create agent:claude --force`, `gh issue edit <n> --add-label agent:claude` e comentário `[autofix] handed off to Claude`.
- Modify `actions/conform/render.py`: `render_autofix` passa `handoff: true` quando `project["agent"]` existe.
- Test `tests/issue/run.sh`: blocked → `outcome=blocked`.
- Create `tests/handoff/run.sh`: label e comentário com `gh` simulado. Registrar no `self.yml`.
- Test `tests/render/run.sh`: `autofix.yml` com e sem `handoff: true`.

**Passos:** testes que falham → implementação → testes verdes → commit `feat: autofix hands off to the agent run`.
**Pronto para prod:** o default `handoff: false` mantém os projetos atuais iguais.
**Valida:** `sh tests/issue/run.sh && sh tests/handoff/run.sh && sh tests/render/run.sh && sh tests/publish/run.sh`

**Depois do merge dos PRs 1 a 4 na `main`:** `sh tasks/release.sh v2 --push` (move o `v2` para o commit de merge).

## Documentação (no PR 4)

- Modify `README.md`:
  - seção "Agent run": chave `agent`, gatilhos, teto, escopo, PR draft, credencial `<ns>:secrets.ci.agent` e pré-requisito da Claude GitHub App com acesso ao repo;
  - seção "Autofix": handoff e desfecho `blocked`;
  - seção "Promote": Hook output.
- Modify `docs/contract.md`: tabela de jobs e escopos do `claude.yml`, `output.log` e redação, desfecho `blocked`, label `agent:claude`.
- `docs/CONTEXT.md`: termos **Agent run**, **Handoff** e **Hook output** (já adicionados com esta spec).

## PR 5 — Piloto no lunetamagica (branch: `chore/agent-run`, base: `main`)

**Repo:** `brazza-tech/lunetamagica` (depois da release `v2`)
**Entrega:** o fluxo destravado e o Agent run ligado.

**Arquivos:**
- Modify `.github/modules.json`: remove a primeira chave `autofix` duplicada (fica `"autofix": {"max_per_day": 20}`) e adiciona `"agent": {"max_per_day": 10}`.
- Create `.github/workflows/claude.yml` e Modify `.github/workflows/autofix.yml`: saída de `python3 <pipelines>/actions/conform/render.py --root . --ref v2`. Nunca editar à mão.
- Create `docs/learnings/autofix_vs_claude.md` (inglês): contexto do A/B sequencial e tabela `issue | autofix outcome | agent run outcome | PR | merged without rework | minutes | notes`, já com as 8 issues de 21 a 24/nov no lado do Autofix.

**Ações fora de arquivo (builder, com `gh`):**
- `gh api -X PATCH repos/brazza-tech/lunetamagica -F allow_auto_merge=true`
- Confirmar `gh api orgs/brazza-tech/installations --jq '.installations[] | select(.app_slug=="claude") | .repository_selection'`. Se for `selected`, incluir o lunetamagica no acesso da App (passo humano: reportar ao usuário).
- Confirmar `CLAUDE_CODE_OAUTH_TOKEN` em `lunetamagica:secrets.ci.agent` (`ward` catalog), sem ler o valor.
- Issue de acompanhamento no lunetamagica: "Avaliar autofix vs Agent run nas próximas 5 Critical issues", que aponta o learnings e define o critério (taxa de PR mergeado sem retrabalho).
- Issue no pipelines: "Ligar agent no has_warranty após o piloto".

**Pronto para prod:** só CI. Sem telas, então "sem telas afetadas" no staging.
**Valida:** `make conform` verde. O `check/pr` do PR verde (o conform aceita `claude.yml`). Smoke depois do merge:
1. comentar `@claude diga qual módulo está declarado no modules.json, sem mudar nada` numa issue de teste → o Agent run responde no sticky comment;
2. `gh workflow run autofix.yml -f issue=<issue de teste com urgency:critical e module:core descrevendo um defeito inexistente>` → gave up → `agent:claude` aplicado → `claude.yml` roda.

## SEQUENCE
1. #<pr1> — fix: autofix verify reason never empty (pipelines)
2. #<pr2> — feat: critical issue quotes the hook output (pipelines)
3. #<pr3> — feat: agent run renders claude.yml (pipelines)
4. #<pr4> — feat: autofix hands off to the agent run (pipelines)
5. release `v2`
6. #<pr5> — chore: agent run pilot (lunetamagica)

Merge in this order: #<pr1> #<pr2> #<pr3> #<pr4> → `release.sh v2 --push` → #<pr5>

# definition of done

- [ ] Todo cenário de "acceptance criteria" foi validado (automatizado ou verificado com comando exato)
- [ ] Testes automáticos passando: suíte inteira do `self.yml` do pipelines verde e `check/pr` do lunetamagica verde
- [ ] Toda task do "how" executada
- [ ] Documentação atualizada (README, contract.md, CONTEXT.md e learnings do lunetamagica)
- [ ] Staging: merge na main do lunetamagica feito, "sem telas afetadas" reportado
- [ ] Cada PR da sequência validado isoladamente (build e testes verdes sem os PRs seguintes)
- [ ] Último PR (PR 5) liga a funcionalidade (chave `agent` no lunetamagica)
- [ ] Hook output: `tests/critical` cobre `## output` com 300 linhas, máscara, 20 000 e prioridade do failures.md
- [ ] Redação: `tests/actions` (ou `tests/hook`) prova `<redacted>` para `E2E_PASSWORD` e `DATABASE_URL`
- [ ] Exit code: o teste prova 3 → falha, 0 → verde, saída no stdout, `output.log` só em regression/e2e
- [ ] `tests/publish` prova "verify failed before a verdict"
- [ ] `tests/handoff` e `tests/issue` provam handoff em gave up, rejected (verify), failed e blocked, e ausência em rejected do select
- [ ] `tests/render` prova o `claude.yml` com `agent`, nenhuma mudança sem `agent`, RenderError para chave inválida, e `handoff: true` no `autofix.yml`
- [ ] `tests/agent_run` prova teto (skip + comentário), menção sem teto e resolução de módulo
- [ ] `tests/conform` aceita `claude.yml` só com `agent`
- [ ] `claude.yml` renderizado contém os deny rules de `.github/workflows/**`, `.ward/**` e `gh pr merge`, e nenhum `--auto` ou merge
- [ ] Suítes `sh tests/*/run.sh` rodadas localmente no macOS e verdes no CI (Ubuntu)
- [ ] Tag `v2` movida para o merge dos PRs 1 a 4 (`git ls-remote --tags origin v2` == SHA do merge)
- [ ] lunetamagica: `.github/modules.json` com uma única `autofix` e a chave `agent` (`python3 -c` com `object_pairs_hook` sem duplicatas)
- [ ] lunetamagica: `gh api repos/brazza-tech/lunetamagica --jq .allow_auto_merge` == `true`
- [ ] Claude GitHub App com acesso ao lunetamagica confirmado (ou pendência reportada ao usuário)
- [ ] Smoke 1 (menção) e smoke 2 (handoff via dispatch) executados, com os links dos runs reportados
- [ ] Agent run do smoke 2 abriu PR draft `claude/issue-<n>-…` sem auto-merge e com `check/pr` disparado, ou comentou que não há defeito, sem PR
- [ ] `claude.yml` renderizado não define `allowed_non_write_users` nem `allowed_bots` (menção de quem não tem write é ignorada pela action)
- [ ] Issues de follow-up criadas: A/B das 5 próximas críticas (lunetamagica) e has_warranty (pipelines)
- [ ] Banner `FINISHED` impresso como última saída (`br4zz4:finish`, Step 7), só com todos os itens acima marcados

## documentation

- `br4zz4/pipelines`: `README.md`, `docs/contract.md`, `docs/CONTEXT.md` (Agent run, Handoff, Hook output).
- `brazza-tech/lunetamagica`: `docs/learnings/autofix_vs_claude.md`.
