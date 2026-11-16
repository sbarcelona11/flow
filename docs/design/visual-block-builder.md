# Automations — visual block builder and modules

> Status: design, revision 2 (2026-11-16). Not implemented. Revision 1 (the first draft of
> this file) proposed agent-shaped blocks compiled to `Step`s; this revision keeps that idea
> and adds the module architecture, the use cases it was checked against, and the decisions
> taken after reviewing the code. Interactive version of the proposal:
> https://claude.ai/artifact/EXBcuU6iKeyr69LELEbqTi
>
> Delivery is split into the phases of §7.

## 1. Goal

A visual editor (React Flow) where people build automations from reusable blocks — inputs,
connectors, agents, controls, outputs — for any domain, not only engineering. Every block
in the palette is a **module**: a versioned package with a manifest and declared
permissions, so new integrations are added as packages and, later, distributed through a
module marketplace.

The difference from n8n stays the one revision 1 named: a block may delegate to an agent
working in a sandbox, under approval, with traceability and cost.

## 2. Decisions

| # | Decision | Why |
|---|---|---|
| D1 | The canvas is a view of `Workflow` + `Step`s, not a new model. | One engine, one truth; versioning, triggers and runs keep working. |
| D2 | Steps get a `kind`: `agent` (today's step), `action`, `approval`, `wait`. | A GET or an invoice total must not run through an LLM. |
| D3 | Steps stay flat. Composite blocks expand at compile time; `sub_steps` show inside a node. | The engine keeps one shape. |
| D4 | Governance comes from the platform, keyed on each operation's declared **effect** (`read`, `write`, `send`, `irreversible`). A package cannot lower it. | Third-party modules cannot skip approval. |
| D5 | A budget cap stops the session when crossed, not after the run. | Checking at the end only reports the overspend. |
| D6 | Approval is an explicit node (`approval` step), not a flag inside each block. | Visible in the graph; approvers and timeout live on it. |
| D7 | Port types map onto what exists: asset specs, `@` references, `DataFlow::Check`. | No parallel validation in the frontend. |
| D8 | Modules are pinned by version; upgrades are offered with a port diff, never applied silently. | A port change breaks running workflows. |
| D9 | No third-party code in the Rails process. Declarative modules run on platform executors; code modules run only in containers with declared egress. | Same doctrine as stdio MCP servers today (`MCP::ToolListProbe`). |
| D10 | Secrets are injected by the executor and never reach an agent's context. | |
| D11 | The marketplace extends the templates repository (`Templates::Package`), it is not a new distribution channel. | Namespaces, CI review, commit/digest pinning, revocation and setup checklists already exist. |
| D12 | UI: a sidebar entry **Automations** under *Work*, behind the company-scoped flag `automations_canvas`. | Default taken pending product confirmation; it opens the same workflows. |

## 3. Module kinds

| Kind | Answers | Example |
|---|---|---|
| `type` | What shape is the data? JSON Schema, named and versioned. Decides which ports connect and validates what an agent produces. | `aixle/money@1`, `dualboot/projectx-report@1`, `file<image/*>` |
| `capability` | What is asked, regardless of who does it? A generic contract several connectors implement. | `aixle/image.generate@1`, `aixle/speech.synthesize@1` |
| `connector` | How is the system reached? Base URL, auth, egress hosts, pagination, operations (input, output, effect), `transport: rest | mcp | container`, optional `implements:` capabilities with unit pricing. | `dualboot/projectx@1`, `google/gemini-media@1` |
| `block` | What does this node do? Typed ports, config form (JSON Schema), executor `agent | action | control`, `uses:` an operation or a capability. | `projectx-hours`, `lead-qualifier` |
| `workflow` (exists) | Which problem does it solve? A workflow built from blocks, installable. | `dualboot/monthly-invoicing@2` |

Manifests extend `template.yaml`. Examples (connector, action block, agent block, type,
capability + provider) are in the interactive proposal, section "Arquitectura de módulos".

### 3.1 Effects and default governance

| Effect | Approval | Idempotency key |
|---|---|---|
| `read` | none | not needed |
| `write` | optional per block | recommended |
| `send` | required by default | required |
| `irreversible` | always | required |

MCP tool annotations (`readOnlyHint`, `destructiveHint`) may only make the suggested effect
stricter. A tool without annotations is treated as `write` until a person confirms it.

### 3.2 Type rules in the editor

- Same type or subtype connects (`file<image/jpeg>` → `file<image/*>`; an object with every required field → its type).
- `list<T>` → `T`: the editor offers a *For each* block.
- Different types: the editor offers a converter block or an agent.
- An agent's declared output is validated against its type; a mismatch fails the step and its retry policy applies.

### 3.3 Capabilities and providers

A block uses a capability; the provider is chosen in its config, with a company default and
a fallback. Adding a provider is publishing a connector that declares
`implements: <capability>`; every existing block of that capability can select it. This is
the pattern `config/agent_runtimes.json` already uses for agent runtimes. Async providers
(video) submit and let Temporal wait durably; results are downloaded into an Asset in the
same step, since provider URLs expire. Unit pricing in the manifest lets the editor estimate
a run's cost and apply the cap before generating.

### 3.4 Adding an MCP server

An MCP server enters as a connector with `transport: mcp`, used two ways:

1. As a tool of an agent block — works today for every transport.
2. Each tool as an action block — new. Ports come from the tool's `inputSchema` and, when
   declared, `outputSchema`; otherwise output is untyped JSON until a person assigns a type.

What exists: install from the registry mirror or by URL, OAuth/static auth with shared or
per-user credentials, `ToolListProbe` reading `tools/list` for http/sse, and
`ToolDriftDetector`, which never moves the baseline without a person. What is missing: the
snapshot stores only names and digests, not schemas; stdio servers cannot be probed in Rails
(probe them in an isolated container or keep them agent-only); a tool selection screen; an
action executor acting as MCP client from Temporal. A block whose tool drifted is marked
*needs review* and does not run until a person accepts the change.

### 3.5 Creating modules, least effort first

1. From an installed MCP server (automatic).
2. From an OpenAPI spec or a cURL command: choose operations, set effects.
3. With an agent (reuses Aixle Builder): it reads docs, drafts the manifest, tests with the user's token in a sandbox, the user approves.
4. In the canvas: select nodes → *Save as block* (composite, D3).
5. With code: a container block, like today's Wrappers, with declared egress.

## 4. Use cases the design was checked against

| Case | Flow | Hard constraints |
|---|---|---|
| ProjectX weekly report | cron → ProjectX `list_reports` (action) → agent summary → approval → Slack | ProjectX publishes no OpenAPI and `/api/v1/reports/` without a session returns the SPA (checked 2026-11-16); needs an API token. Routes: MCP inside ProjectX (Ruby `mcp` gem), MCP generated from an OpenAPI spec, or the native REST connector. |
| Marketing | brief → agent copy/prompts → image, voice, video (capabilities) → approval → wait until time → Instagram + LinkedIn | Instagram needs a Business/Creator account linked to a Facebook page, a reviewed Meta app, and media at a public URL; posting as a LinkedIn page needs Community Management API access. Instagram does not publish standalone audio. Publishing needs an idempotency key. |
| Lead search (staff augmentation, Aixle Flow) | ICP preset → company data + buying signals → agent scoring → CRM dedup → agent drafts → approval → CRM | No LinkedIn scraping (terms). Personal data: GDPR / CAN-SPAM, retention. v1 leaves emails as CRM drafts. |
| Invoicing | monthly cron → ProjectX hours + rates → action computes lines → agent flags anomalies → approval → invoicing system → send | Amounts are computed by code, never by a model. Idempotency per client+period. An issued invoice is voided with a credit note, so approval is mandatory. Fiscal e-invoicing goes through a provider authorised in that country. |

All four use: agent, REST connector, action, approval. Three use idempotency; two use a
budget cap; one uses wait-until and public asset URLs. That ordering drives the roadmap.

## 5. Distribution (marketplace)

| Need | Exists | Added |
|---|---|---|
| Package format | `template.yaml`, kinds project/workflow/board/agent/skill/connector | kinds `type`, `capability`, `block`; `connector` with `transport: rest` |
| Publishers, review | namespaces with GitHub owners, repo CI, verified badge | manifest checks: egress, effects, valid schemas |
| Integrity | mirror pinned by `commit_sha` + digest, `revoked_at` | a revocation stops new runs of the module |
| Install | setup checklist (secret, oauth, trigger, …) | permissions screen: hosts, effects, secrets |
| Dependencies | none; an install copies resources | block → connector → types, resolved by the installer |
| Versions | no upgrade after install | pinned (D8) with upgrade notice and port diff |
| Visibility | public | project → company (private) → public |

## 6. Open questions

Defaults are taken where marked; product may override them.

- Sidebar entry vs. a Canvas tab inside Workflows — default D12.
- ProjectX: who owns its code and can issue API tokens? Decides the MCP route.
- Which Instagram/LinkedIn accounts, CRM, data provider, invoicing system and country.
- Third-party code modules — default: not before the open-marketplace phase (D9).
- Monetisation of modules — out of scope until the open-marketplace phase.

## 7. Delivery phases

Each phase ships on its own. P1 and P3 can run in parallel; P4 needs P2; P7 needs P2 and P3.

| Phase | Scope | Done when |
|---|---|---|
| P0 | No code: ProjectX token and MCP route; Meta and LinkedIn app reviews (weeks of lead time); CRM, data, invoicing providers chosen | each use case has a system, an account and a credential owner |
| P1 | `steps.kind` with `approval` (approve/reject in the run page, timeout) and `wait` (delay or time from shared context) | ProjectX and invoicing flows run with an approval step in today's builder |
| P2 | Manifest v1 (`type`, `capability`, `connector`, `block`), project registry, `action` steps without an LLM, effects and idempotency, REST connector, MCP tools as action blocks, typed agent outputs | the ProjectX connector is a module; invoice lines are computed in an action step |
| P3 | Budget cap per step and run that stops the session | a step crossing its cap ends with "budget exceeded" and no further spend |
| P4 | React Flow canvas behind `automations_canvas`: read-only, then editing with registry palette, typed ports, generated forms, stored positions | the four use cases are built and run from the canvas |
| P5 | OpenAPI / cURL import, agent-assisted authoring, composite blocks | a non-developer adds a REST service without editing YAML |
| P6 | Module catalog: new kinds in the templates repository, dependencies, private company catalog, permissions screen, pinned versions with upgrade diff | a module from one company installs in another with its dependencies |
| P7 | Media capabilities and providers, async actions, temporary public asset URLs, Instagram and LinkedIn publishing | the marketing flow publishes to both networks at the chosen time |
| P8 | Open marketplace: external publishers, code modules in containers, ranking, monetisation | — |
