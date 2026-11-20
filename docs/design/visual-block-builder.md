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
| D5 | A budget cap stops the session when crossed, not after the run. Runtimes that report cost only at cleanup (cursor_cli, grok, antigravity_cli, kiro_cli) or never (codex) cannot be stopped while running. | Checking at the end only reports the overspend. |
| D6 | Approval is an explicit node (`approval` step), not a flag inside each block. | Visible in the graph; approvers and timeout live on it. |
| D7 | Port types map onto what exists: asset specs, `@` references, `DataFlow::Check`. | No parallel validation in the frontend. |
| D8 | Modules are pinned by version; upgrades are offered with a port diff, never applied silently. | A port change breaks running workflows. |
| D9 | No third-party code in the Rails process. Declarative modules run on platform executors; code modules run only in containers with declared egress. | Same doctrine as stdio MCP servers today (`MCP::ToolListProbe`). |
| D10 | Secrets are injected by the executor and never reach an agent's context. | |
| D11 | The marketplace extends the templates repository (`Templates::Package`), it is not a new distribution channel. | Namespaces, CI review, commit/digest pinning, revocation and setup checklists already exist. |
| D12 | UI: a sidebar entry **Automations** under *Work*, behind the company-scoped flag `automations_canvas`. | Default taken pending product confirmation; it opens the same workflows. |
| D13 | Integrations plug in through ports and adapters (§3.6): one `Connectors::Transport` port, a self-registering registry, a fixed action pipeline the platform owns, a shared contract test suite and a generator. Adding a connection type is one class; adding a connection over an existing type is a manifest. | Today each connection type (MCP, Wrapper, REST) is a branch in the action activity, the catalog, the target check and the call labels, so every new type edits the engine. |

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

### 3.6 Extension architecture (D13)

Two levels of extension, so most integrations need no code:

| Level | What is added | How | Who |
|---|---|---|---|
| Data | a connection over an existing transport (another REST API, another MCP server), types, capabilities, blocks, templates | a manifest with JSON Schema | anyone, including marketplace publishers |
| Code | a new transport (GraphQL, SQL, gRPC, SOAP, …) or a new executor | one class implementing the port | first party; third parties only as container code (D9) |

Patterns, each with a precedent in this codebase:

- **Ports and adapters.** The engine knows one port, `Connectors::Transport`: `operations(connection)` (what can be called, with input/output schemas and base effects), `call(connection, operation, arguments, context) → Result` and `probe(connection)`. `Result` is the shape MCP and REST already share: `ok`, `structured`, `text`, `error`, `unknown`, `status`, `config_item_names`. Precedents: `Trackers::Provider`, the `PullRequests` provider, the agent runtime adapters.
- **Self-registering registry.** A transport declares `transport :graphql` and is found by key; nothing in the engine switches on transport names. Precedent: `Tools::Registry` with `Tools::DefinitionDSL`.
- **Template method for governance.** The action pipeline is fixed and owned by the platform: target check, effect floor, approval in the run, argument validation, attempt record, `transport.call`, outcome classification, output, audit. A transport implements only the call, so no module can skip governance, at-most-once or redaction.
- **Strategy and adapter for capabilities.** A capability is a contract (input/output schemas); a provider connector implements it through a declarative field mapping, so switching providers is configuration.
- **Contract test suite.** `Connectors::TransportContract` is a shared Minitest module every transport includes: outcome classification (success, known failure, unknown after send), redaction, no hidden retries, size and time limits. Precedent: the pull-request provider contract tests.
- **Generator.** `bin/rails generate connector_transport <name>` scaffolds the class, its registration, the contract test, the connection config schema (from which the UI form is generated) and a docs stub.

Migrating MCP, Wrapper and REST onto the port with no behaviour change is the proof that
the port is right: if all three fit without exceptions, the next transport is one class.

## 4. Example scenarios used to check the design

The platform is generic: nothing in it knows about these scenarios. They were used only to
check that the step kinds, governance and connectors cover real problems; each one is built
by configuring connectors, actions, agents and approvals, not by platform code.

| Scenario | Flow | Hard constraints |
|---|---|---|
| ProjectX weekly report | cron → ProjectX `list_reports` (action) → agent summary → approval → Slack | ProjectX publishes no OpenAPI and `/api/v1/reports/` without a session returns the SPA (checked 2026-11-16); needs an API token. Routes: MCP inside ProjectX (Ruby `mcp` gem), MCP generated from an OpenAPI spec, or the native REST connector. |
| Marketing | brief → agent copy/prompts → image, voice, video (capabilities) → approval → wait until time → Instagram + LinkedIn | Instagram needs a Business/Creator account linked to a Facebook page, a reviewed Meta app, and media at a public URL; posting as a LinkedIn page needs Community Management API access. Instagram does not publish standalone audio. Publishing needs an idempotency key. |
| Lead search (staff augmentation, Aixle Flow) | ICP preset → company data + buying signals → agent scoring → CRM dedup → agent drafts → approval → CRM | No LinkedIn scraping (terms). Personal data: GDPR / CAN-SPAM, retention. v1 leaves emails as CRM drafts. |
| Invoicing | monthly cron → ProjectX hours + rates → action computes lines → agent flags anomalies → approval → invoicing system → send | Amounts are computed by code, never by a model. Idempotency per client+period. An issued invoice is voided with a credit note, so approval is mandatory. Fiscal e-invoicing goes through a provider authorised in that country. |

All four need the same generic pieces — agent, connector, action, approval; three need
idempotency, two a budget cap, one wait-until and public asset URLs — which is why those
pieces are platform features and the scenarios themselves are not.

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
- Third-party code modules — default: not before the open-marketplace phase (D9).
- Monetisation of modules — out of scope until the open-marketplace phase.

## 7. Delivery phases

The phases build a generic platform; "done when" is stated in platform terms. Each phase
ships on its own. P1 and P3 can run in parallel. P4 can start on today's step kinds and
switches its palette to the registry when P2c lands. Built so far: P1, P2a, P2b (REST
connectors and OpenAPI / cURL import, which covers part of P5), P3 (budget caps on steps and runs; see
[Budget caps](../architecture/workflows.md#budget-caps)), P4 (the canvas, shipped behind
`automations_canvas`; see [Canvas](../architecture/workflows.md#canvas)), P5 (easy authoring: the REST wizard, review of connectors, operations and
blocks, the Blocks tab, composite blocks and the Builder's REST and block tools; see
[Authoring](../architecture/workflows.md#authoring-rest-wizard-blocks-composites-builder-tools)). P5 left one gap, which
**P5b** closes: MCP servers that tools create (`create_mcp_server`, `install_connector`, `install_template`) are still
enabled without review. P6 inherits the bind-by-id of blocks to connectors and P5b as prerequisites.

| Phase | Scope | Done when |
|---|---|---|
| P1 | `steps.kind` with `approval` (approve/reject in the run page, timeout) and `wait` (delay or time from shared context), capped at 6 days — below the 7-day run timeout | any workflow can pause for a person or for a time, in today's builder |
| P2a | `action` steps without an LLM that call one tool of an installed MCP server or one project Wrapper (container tool); full tool schemas kept in the MCP snapshot; effects with platform governance (D4: `send`/`irreversible` need an approval step upstream) and an at-most-once rule for non-`read` calls; per-call audit; output written as a run asset; behind the company flag `workflow_action_steps` | any MCP tool or Wrapper can be called from a workflow without an agent, under the same governance |
| P2b | REST connectors as project resources (base URL, auth from Config Items, declared egress, operations with effects), OpenAPI / cURL import of operations, executed by the same action executor | any REST API can be called from a workflow without an MCP server |
| P2c | Module SDK (D13, §3.6): the `Connectors::Transport` port and registry; MCP, Wrapper and REST moved onto it with no behaviour change; the action pipeline with no per-transport branches; the transport contract suite and generator; manifest v1 (`type`, `capability`, `connector`, `block`) with a project registry; connection config forms generated from schemas; typed ports; agent outputs validated against their type | a new connection type is one class plus its contract test, and a new connection, type or block for any problem needs no platform code |
| P3 | Budget cap per step and run that stops the session | a step crossing its cap ends with "budget exceeded" and no further spend |
| P4 | React Flow canvas behind `automations_canvas`: read-only, then editing with a palette (step kinds first, registry after P2c), typed ports, generated forms, stored positions | any workflow can be built, edited and run from the canvas |
| P5 | Agent-assisted authoring, composite blocks (OpenAPI / cURL import already shipped in P2b) | a non-developer adds an integration and a reusable block without editing YAML |
| P6 | Module catalog: new kinds in the templates repository, dependencies, private company catalog, permissions screen, pinned versions with upgrade diff | a module from one company installs in another with its dependencies |
| P8 | Open marketplace: external publishers, code modules in containers, ranking, monetisation | — |

**Outside the core — module packs.** Integrations for specific domains (media generation
capabilities and providers, social publishing, CRMs, invoicing systems, …) are built as
modules on top of P2c/P6, not as platform phases. Two platform features they will need are
tracked here: async actions (submit then poll or webhook) and temporary public URLs for run
assets. External prerequisites such as Meta or LinkedIn app reviews belong to whoever
builds those packs.
