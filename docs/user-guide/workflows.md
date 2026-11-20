# Workflows

A Workflow is a DAG of Steps that together accomplish a business
process — a code review, a feature spec, a bug triage. Each Step is one
agent session in one container.

> The workflow builder names these levels differently from the API: a
> **Step** on this page is a **session** in the builder, and a **SubStep** is a
> **step** in the builder. The API, the MCP tools (`create_workflow_step`,
> `create_sub_step`) and the field names below keep `step` and `sub_step`.

## Anatomy of a Workflow

| Field                            | Description                                                                 |
| -------------------------------- | --------------------------------------------------------------------------- |
| `name`                           | Unique within its scope (Company or Project).                                |
| `description`                    | What the workflow accomplishes.                                              |
| `config.base_tool_ids`           | Tools always available to every step in this workflow.                       |
| `config.base_skill_ids`          | Skills always injected into agent context.                                   |
| `config.base_mcp_server_ids`     | MCP servers always connected.                                                |
| `config.base_asset_ids`          | Files always pre-loaded into `/workspace/assets/`.                           |
| `config.inherit_all_project_resources` | If true, all project-level resources merge in additively.              |
| `execution_mode`                 | `interactive`, `non_interactive`, or `mixed` (per-step).                     |

## Anatomy of a Step

One Step = one agent session = one container = one major deliverable.

| Field                  | Description                                                              |
| ---------------------- | ------------------------------------------------------------------------ |
| `name`                 | Step name.                                                               |
| `position`             | Order in workflow.                                                       |
| `instructions`         | **The most important field.** Markdown instructions for the agent.       |
| `agent_id`             | Which agent persona runs this step.                                      |
| `allow_non_interactive`| Can the step run with no user in the loop.                                |
| `skip_policy`          | `never`, `if_outputs_exist`, or `manual`.                                |
| `on_failure`           | `retry`, `skip`, or `fail` (default). A step that stopped on its owner's agent quota is not retried — the same account would fail again — except in a run a team handed out, where the retry goes to the team's next member. |
| `max_retries`          | Times a failed step starts again when `on_failure` is `retry`: 1–10.     |
| `budget_cents`         | Spend cap for this step in a run, in cents (set as dollars in the builder). Empty means no cap. See Budget caps below. |
| `tool_ids`             | Tools available in this step (merged with workflow base).                |
| `skill_ids`            | Skills injected (merged with workflow base).                             |
| `mcp_server_ids`       | MCP servers connected (merged with workflow base).                       |
| `repository_ids`       | Repos cloned under `/workspace/repo/` (merged with workflow base).       |
| `depends_on_step_ids`  | DAG dependencies — enables parallel execution.                           |
| `preferred_model`      | LLM model override for this step.                                        |
| `reasoning_effort`     | Reasoning effort the step's CLI runs at (`low`, `high`, …). Unset keeps the CLI's default. It needs an explicit `required_agent_runtime` and `preferred_model`: a level without either is refused, so clear the level with them. Only the levels that runtime takes for that model are accepted. The CLI may still lower or ignore a level the model doesn't support. |
| `input_asset_specs`    | Expected inputs. A required one is checked before the step starts; a missing one fails the step ("Required input missing"). Needed only for files picked when a run starts: an `@` reference is checked without one. |
| `output_asset_specs`   | Expected outputs. A required one is checked when the step ends; a missing one fails the step ("Output validation failed"). A name is the file's path under `/workspace/outputs/` (a `/workspace/…` prefix is dropped), or a glob such as `reports/*.md`; `dir/**` takes everything under `dir`. |

## DAG and parallelism

A Step with `depends_on_step_ids: []` can start as soon as the workflow
run begins. Steps with dependencies wait until *all* listed
prerequisites complete successfully. Sibling steps that share no
dependency relationship run **in parallel**, each in its own container.

Dependencies cannot form a cycle: saving a step that would end up waiting on
itself is rejected with the cycle spelled out. If a run is left with steps that
can never start, it fails with `failure_reason: unsatisfiable_dependencies`
instead of reporting completion.

```
       ┌── Step B (lint)  ─┐
Step A ┤                   ├── Step D (merge)
       └── Step C (test)  ─┘
```

A step's starting context summarizes only the steps it depends on, directly or
through others, each from its latest completed or skipped attempt. In the diagram,
Step D gets A, B and C; Step B gets only A, never C, which runs beside it.
For spec-first workflows and the context budget, see
[Token-efficient workflows](token-efficient-workflows.md).

Aixle Flow uses **Temporal** to orchestrate this — runs survive process
restarts, retries are durable, and you can attach to a long-running
workflow from a fresh page reload.

## SubSteps

SubSteps are what the builder shows as a session's steps. They are **not**
separate sessions — they're a checklist inside one container session. They
reach the agent as a numbered list under the Step's instructions, and the
agent marks each one with the `mark_sub_step` tool. Use them when you want
visible progress for a long step (e.g. "1/5: scanned codebase",
"2/5: drafted plan"…). Neither their order nor their `required` flag is
enforced at run time.

## Execution flow

```
WorkflowRun  (pending → running → completed | failed)
├── StepRun 1                      ← one container
│   ├── TerminalSession
│   ├── SubStepRun 1.1 → 1.2 → 1.3
│   └── Produces: WorkflowRunAssets
├── StepRun 2  (waits on StepRun 1 if depends_on_step_ids)
└── StepRun 3
```

A `WorkflowRun` can be triggered by:

- a column binding (auto or manual),
- the **Trigger workflow** button on a task,
- the workflow's "Run" button outside the board,
- a schedule, a Slack message, or an inbound webhook,
- the API (`POST /company/projects/:project_id/workflow_runs`).

> All of these flow through one event pipeline, and each off-board trigger carries a
> `subject_policy` deciding whether the run gets a board task. The in-app docs page
> **Triggers and Gates** (`/docs/triggers-and-gates`) has the full model — including
> why a CI **gate** is not a trigger.

## Approval gates and human-in-the-loop

For a step that should pause for a human:

1. Set `allow_non_interactive: false` on the step.
2. The container starts but the agent waits for explicit approval.
3. The UI shows an **Approve / Retry / Skip** control on the step run.

The API endpoints behind those buttons:

- `POST /company/projects/:id/workflow_runs/:run_id/approve_step`
- `POST /company/projects/:id/workflow_runs/:run_id/retry_step`
- `POST /company/projects/:id/workflow_runs/:run_id/skip_step`

To pause for a person without starting an agent session, use an approval step
instead (see [Approval and wait steps](#approval-and-wait-steps)).

## Approval and wait steps

Besides agent steps, a workflow has two kinds of control step. Action steps, which call a tool, are covered under
[Action steps](#action-steps). Control steps start no
agent session, cost no agent time, and take their place in the DAG like any
step, including next to agent steps in a parallel batch. Add one with
**Add an approval** or **Add a wait** in the builder, or change a step's
**Step type**. A control step never stops a workflow from running fully
automatic, so a scheduled or webhook trigger still fires a workflow that has
one.

**Approval.** The run stops at this step until a person decides.

- **Expires after** is 1 to 144 hours (default 24).
- **If no one decides** is **Fail** (default) or **Skip**: when the time runs
  out the step fails, or is skipped and the run goes on.

On the run page the step shows an approval panel. A reviewer chooses
**Approve** or **Reject** and may add a note. Approving continues the run;
rejecting fails the step ("Rejected by NAME"). The step waits for a person
even in a non-interactive run. Once someone has decided, a second decision is
refused. Agents cannot approve it through the `approve_step_run` tool.

**Wait.** The run pauses at this step, then continues by itself.

- **For** sets a duration in hours and minutes, up to 144 hours.
- **Until the time in shared context key** reads an ISO 8601 time from the
  run's shared context (for example `reminder_at`, a dotted snake_case key). A
  time already past continues at once; a missing or unreadable time, or one
  more than 6 days away, fails the step.

A wait cannot be approved. **Skip** it to stop waiting.

## Action steps

An action step calls one tool without an agent: a tool of a connected MCP server
one of your Wrappers, or an operation of a REST API connector. Its result is saved as a file for the next steps. Action
steps are behind the `workflow_action_steps` flag, so your company must have it
on. Add one with **Add an action**.

- **Tool** lists the tools of the project's MCP servers, your Wrappers and the
  operations of your REST APIs (shown as the connector, the method and the path). A tool
  whose definition changed since it was approved is disabled until the server is
  approved again.
- **Arguments** are generated from the tool's schema. Write `{{context:key}}` to
  fill a value from the run's shared context, or `{{output:<step>:<file>}}` to use a
  file an earlier step wrote (see below).
- **Effect** says what the call does outside Aixle Flow: **read**, **write**,
  **send** or **irreversible**. It starts at what the tool declares and can only be
  raised.
- **Output file** is where the result is saved (default `result.json`, up to 10 MB).

**REST APIs.** Under **Connectors → REST APIs**, add a connector with the API's
`https` base URL (including its base path, without credentials) and how it
authenticates: none, a bearer token, an API key in a header or in the query string,
or basic authentication. The secrets are names of your Secrets & Variables, never
pasted values. Then add operations by hand or **Import** them from an OpenAPI
document (JSON or YAML, up to 2 MB, pasted as text or fetched from an `https` URL) or
from a cURL command. Imports show a list of drafts to review before anything is
saved; credentials in a cURL command are dropped, never stored. Each operation has a
method, a path such as `/items/{id}`, the inputs it takes and an effect: **read** or
higher for `GET`, **write** or higher for the other methods. Calls go only to the
connector's host, don't follow redirects, and accept responses up to 10 MB. A
disabled or archived connector or operation makes the action fail as missing.
Workflows with REST actions can't be exported as templates yet.

**Why an approval comes first.** A **send** or **irreversible** action must depend
directly on an approval step that fails when it expires or is rejected. The builder
warns and offers **Add an approval before it**, and saving refuses the workflow
without one. At run time the action stops with "not approved" unless that approval
was granted in the same run.

**From a block.** A block is a ready-made, pre-configured way to call one tool, with
a name, a short description and just the settings that matter. Choose **Add from a
block** instead of **Add an action**, pick a block, and fill in its settings (they can
use `{{context:key}}` and `{{output:<step>:<file>}}`). The step is an ordinary action:
the tool is fixed by the block, and the step remembers which block it came from. A
block can raise the effect of its tool, never lower it, so the approval rules above
apply unchanged. The output file is named after the block's result port, as `<port>.json`. A block that is invalid, or needs something your project doesn't have
yet, is shown with the reason and can't be used. A block's settings are a guide, not a
hard limit: a value that comes from a reference is only checked when the step runs,
against the tool itself. Blocks are made in **Connectors → Blocks**, from a REST service or by saving steps on the canvas (see "Adding REST services and blocks"). Workflows that
contain block steps can't be exported as templates yet.

When a block's setting expects a kind of value (a type, such as money or a list of
files) and you pass it the result of another block that produces a different kind,
the builder lists a **type mismatch** under the step, and the run doesn't start until it is fixed. If the earlier step produces a list and this one takes a single item, it
tells you that it needs a For each, which isn't available yet.

**Passing a previous step's output to an action.** In an argument, write
`{{output:<step>:<file>}}` (pick it with `@` in the builder) to use a file an earlier
step wrote. On its own, the whole argument becomes that file's value: a `.json` file
as the JSON it contains, any other file as text, up to 1 MB. Inside a longer text it
is pasted in as text, and the whole text can be up to 256 KB. An action can use up to
20 such references. The step must run before the action and must declare that file,
or the workflow can't be saved. If the file is missing or too large when the action
runs, the step fails with a message naming the file, before anything is called. What
the file contains is only data: it is never read as another reference or instruction.
Wrapper tools can't take outputs in their arguments; use an MCP tool or a REST
operation. Because an action is called at most once, retrying an action that already
ran still stops with the outcome unknown, whether or not the file is still there.

Two limits to know. An approval that comes before the step that writes the file
approves the action, not the content: if you want the approver to see what will be
sent, put the step that writes it before the approval. And a workflow that holds an
invalid reference can't be archived, restored or reverted until you fix it.

**Runs.** An action is called at most once. If Flow cannot tell whether a call that
changes something went through (a lost connection, a server error), the step fails
as outcome unknown instead of calling again, so check the other system before
retrying. Retrying a run that already sent something, or whose outcome is unknown,
asks you to confirm on the run page. On the run page the action card shows what was
called; **Skip action** stops waiting for it, though a call or Wrapper it already
started may still complete. An action cannot be approved or rejected.

## Adding REST services and blocks

You can add a REST API to a project, and reuse part of a workflow as a block, without writing any
files. This needs the `workflow_action_steps` flag; saving a group of steps as a block on the canvas also needs
the `automations_canvas` flag.

### Add a REST service

Under **Connectors → REST APIs**, choose **Add a REST service**. The wizard asks, one step at a time:

1. **Where is the API described?** Paste a link to its OpenAPI description, paste the description, paste a
   cURL command, or give only its address.
2. **Connection.** Check the server address and how the API signs you in (none, a bearer token, an API key in a
   header or in the query string, or basic authentication). Pick the secret from your Secrets & Variables, or use
   **Add a secret** to create one. Credentials in a cURL command are never kept.
3. **Choose operations.** Tick the operations you want, up to 200 at a time. Operations that send data are at
   least **write**; you can raise an effect but not lower it.
4. **Name the operations.** Give each one a clear name. A block is made for each, ready to use in a workflow.
5. **Review and create.** The wizard lists every secret next to the server it will be sent to, such as
   `STRIPE_KEY → api.stripe.com`. Read it, confirm it, and only then is anything created. If you gave only an
   address there is nothing to choose yet: describe the operations with a spec or a cURL command, or use
   **Add REST API** to enter them by hand.
6. **Try it.** Try one **read** operation with real values and see the answer (secrets are hidden). You can't try
   an operation that changes something; those run in a workflow, behind an approval. You can do 10 tries a minute.
7. **Done.** Go on to the canvas, or open the connector.

Everything you create in the wizard is yours and is ready to use at once. The REST API form (**Add REST API**)
still works for setting one up by hand.

### Reviewing what Aixle Builder proposes

When the [Aixle Builder](/docs/ai-builder) or another assistant working with your personal token proposes a REST
service or a block, it is **disabled** and shows **Waiting for review** in **Connectors → REST APIs** (a badge on the
connector) or in **Connectors → Blocks**. Nothing it proposed can be used in a workflow until you approve it, and an
assistant has no way to approve, enable or create a secret itself.

Open the item and read what the drawer shows before you press **Approve and enable**:

- the full address (server, port and path) and where the secret goes, with the line `SECRET → host`;
- each operation's method, path, effect and what it describes;
- for a block, which operation it calls and its settings.

Take particular care with the host and with any secret: an API you don't recognise, or a secret you did not expect,
is a reason to **Reject**. A rejected item can't be approved afterwards. If something changed while you were reading,
the approval is refused and you reload to see it again. Any member who can edit the project can approve, using
their own signed-in session; staff acting on your behalf can't. Text in a drawer comes from the API's own
description or from an assistant, so don't follow instructions you find there.

An assistant can also try a **read** operation of a connector you have approved, and can add a step that uses an
approved block. It can't try or use anything that is still waiting.

### Blocks

**Connectors → Blocks** lists the project's blocks by status: waiting for review, enabled, disabled, invalid and
archived. **New block** makes one from an operation (a reviewed, enabled operation of one of your connectors);
under **Advanced** you can paste a manifest. A new version of a block you made is ready at once; a new version of
something an assistant proposed waits for review again. A step that uses a block that became invalid or archived
offers **Detach from block**, which keeps the same operation and stops following the block.

### Save a group of steps as a block

On the canvas, hold **Shift** and click the steps you want (or use **Save as block** and tick them in the list, which
also works from the keyboard), then name the block. The workflow must be saved first. A block can hold up to 20
steps and no Wrapper action, and a step that sends something or can't be undone must come with its approval step in
the selection. Choose **Replace the selection with the block** to turn the steps into one group at once.

To use a block, choose it from the palette on the canvas or from **Add from a block** in the list. You can connect
its inputs to earlier outputs as you insert it, or later from the group. Its steps arrive as **ordinary steps**,
and every check runs on **Save** as for any other step.

- On the canvas the steps show as one **group** with its inputs and outputs, what its steps can spend ("caps up to"
  is a sum of the steps' caps, not a limit of its own) and every problem inside it. **Expand** shows the steps,
  **Collapse** folds them again.
- A step says which block it came from. **Ungroup** removes that mark and changes nothing else.
- A group is a **copy**. A newer version of the block, or archiving it, never changes the steps already in your
  workflow; the group only tells you a newer version exists. Inputs can only be connected at insertion or from the
  group, not rebound later.
- A workflow with blocks or REST actions can't be exported as a template yet.

### What to check, and what isn't covered

- Secrets are sent only to the host you saw in the review. A saved credential typed into an argument is warned
  about (an assistant is refused outright for known key formats), but a secret under an innocuous name is not
  detected: keep secrets in Secrets & Variables and reference them.
- The Aixle Builder can still add and enable **MCP servers** without a review. Check **Connectors → MCP servers**
  after a Builder session until MCP servers wait for review too.
- Changing the address or the secret of an approved connector by hand does not ask you to confirm again.

## Budget caps

A cap limits what a step, or a whole run, may spend. Leave it empty for no cap.

**Setting a cap.** In the builder, open an agent or action step and fill **Budget cap (USD)**
(under Behavior for an agent step), or fill **Run budget cap (USD)** in the workflow's resources
for the whole run. A cap is from $0.01 to $10,000. The canvas shows a "Cap $x" chip on a capped
step. Anyone who can edit the workflow can set or raise a cap. Approval and wait steps have none.
A run keeps the cap it started with: editing the workflow changes later attempts and runs, not
one that is already running.

**What counts.** A step's cap covers everything the step spent in this run, including earlier
retries. The run cap covers every step. Spend is what the agent sessions used plus the declared
cost of each action call that was attempted (set on the REST operation as "Cost per call", or on
the block). Flow does not measure what an action really cost.

**What happens at the cap.** When spend reaches the cap, the step ends as "budget exceeded" with
what it spent, and nothing more starts for it: no new session, no retry and no paid action call.
A run cap also ends every session of the run that has not finished. An action whose declared cost
would not fit in what is left is not sent at all. Approval and wait steps are left alone. This is
not a quota stop, so it does not hand the step to another team member. The step's `on_failure`
still applies, but a retry is refused straight away because the cap is still reached. The cap is
a stop line, not a guarantee: the session usually ends within seconds, but it can run over by
what it spends before the stop lands.

**What the run page shows.** Each capped step shows "Spent $x of $y", and "Stopped at its budget
cap" when it was stopped. The run header shows "Run spend" against the run cap, and a run that
failed on its cap shows "Run stopped: budget cap reached". Spend refreshes when you reload or
when a step changes state, not continuously.

**Raising a cap and retrying.** Raise the cap in the workflow and save. **Retry** on a finished
run starts a new run with fresh spend and the new cap. Retrying a step in place keeps what its
earlier attempts spent, and that counts against the new cap too. A stopped session does not
resume.

**The warning.** Only some agent runtimes report cost while they work: Claude Code, Gemini CLI
and Copilot CLI. If a capped step is pinned to another runtime, the builder warns that the cap
can't stop it: Cursor CLI, Grok, Antigravity CLI and Kiro CLI report cost only when the session
ends (it counts afterwards, for retries and the run cap), and Codex never reports it, so its
spend is not counted. The warning appears only for a step with a pinned runtime; a step whose
runtime is chosen per run gets none, so pin the runtime when the cap matters.

## Assets in and out

Three sources of input assets, all merged additively:

1. **Workflow base assets** (`workflow.config.base_asset_ids`) — always.
2. **Run-time assets** (`workflow_run.input_asset_ids`) — chosen when
   the run starts.
3. **Outputs of every step it runs after** (`depends_on_step_ids`, followed through: a step after B, which runs after A, gets both), placed at `/workspace/assets/<name>`. When two of them wrote the same name, the nearest one's copy wins. The agent's context lists them.

Files attached to a board card are **not** mounted; the agent fetches them with `board_get_task_assets`.

Everything lands under `/workspace/assets/`. Agents write outputs to
`/workspace/outputs/` — those files become `WorkflowRunAssets` you can
download from the UI or via `GET /api/v1/projects/:id/workflow_runs/:run_id/workflow_run_assets`.

## References and the data-flow check

Typing `@` in a session's instructions inserts a reference to an asset, a declared
output, another session, an MCP server, a tool, a skill or a config item. It is stored
as a token with the row's id (`{{asset:12}}`, `{{output:45:summary.md}}`, `{{step:45}}`,
`{{mcp:7}}`, `{{tool:9}}`, `{{skill:4}}`, `{{config_item:3}}`), shown as a chip, and
replaced with the path or name when the session starts — a config item by its name
only, never its value. Picking an item attaches it, or adds Run after, when the session
would not otherwise get it. Duplicating a workflow or exporting it as a template carries the references.

The builder checks the whole workflow as you edit — references that no longer resolve,
outputs read from a session that does not run first, input and output names that cannot
match, braces nothing replaces — and lists what it finds under each session. Saving is
never blocked. A run that would fail for certain does not start, and `validate_workflow`
reports the same list.

## Saving, versions and the archive

Edits in the workflow builder stay in your browser until you press **Save** —
the header says *Unsaved changes* until you do, and leaving the page asks
first. One Save stores the whole workflow (its fields, every step and
sub-step) as one numbered **version**. Agents, skills, wrappers and MCP servers
are versioned the same way, one version per Save of their form.

- **History** (the clock icon on every workflow, agent, skill, wrapper and
  connector) lists the versions newest first: who saved each one — a person or
  the Aixle Builder acting for them — when, and what changed, compared with
  the version before it or with the current one.
- **Revert** puts an earlier version's content back and saves it as the newest
  version; nothing in the history is overwritten. The confirmation spells out
  what will change. MCP server secrets are never stored in a version, so a
  revert keeps the current header and env values — and one that moves the
  server to another address clears them, as an edit would.
- **If someone saved first**, your Save is refused rather than silently
  overwriting their change; reload to see it.
- **Archive** replaces delete. An archived entity leaves pickers and new
  sessions but keeps its history, and can be restored from the list screen's
  *Archived* view. Archiving is refused while a workflow still uses the entity.
  Restoring a workflow offers to switch back on the triggers archiving turned off.
- **Which version ran**: runs read the saved workflow at the moment each
  session launches, and the run page shows the version per session. A Save made
  while a run is in progress affects the sessions that have not started yet —
  the run page then says so.

## Building on the canvas

When your company has the **Automations** canvas turned on, a workflow can be built on a
canvas as well as in the list. Open **Automations** in the project sidebar, or switch the
builder from **List** to **Canvas**. It is the same workflow: the same Save, History, Revert
and Run, so a change made in one view shows in the other.

- Each step is a node and each dependency a line from the step that runs first. Block steps
  show their input and output ports with their types.
- Add a step or block from the palette: it appears to the right of the selected step and
  runs after it. Use the step's **Run after** menu to connect it to other steps, and
  **Tidy up** to lay the whole graph out again.
- To pass data between blocks, open an input port's **Bind** menu and pick another block's output.
  The step then runs after it. A bound port whose types differ is marked "type mismatch".
- Problems found by the builder's check show on each step as a badge; click it to see
  them and apply a fix. Rules about approvals before actions that send or can't be undone are
  checked when you press **Save**, which refuses and keeps your changes.
- Positions are saved with the workflow's versions, so moving steps and saving creates a
  version, and History shows "Canvas position". Duplicating a workflow keeps its layout.

Keyboard: Tab moves between steps, Enter or Space selects one, the arrow keys move the
selected step, and Delete removes the selected connection or, after a confirmation, the step.
Delete only works while focus is inside the canvas.

Not available yet: dragging between ports to bind them (use the Bind menu), dragging from
the palette, and warnings about approvals on the canvas itself.

## Aixle Builder

Building a workflow by hand is rare in practice. The **Aixle Builder**
is an in-app conversational agent: describe your process in plain
language, it generates the workflow, steps, instructions, and resource
links for you. Open it from the project sidebar (Workflows → "Build with AI").

## Gotchas

- **A step gets code only if some level names a repository** — the step's
  own `repository_ids`, the workflow's `base_repository_ids`, or the run's
  one-off override. An explicit pick anywhere wins outright; the project's
  full set is used only when nothing names one and the workflow has
  `inherit_all_project_resources`. How the run started never matters.
- **`if_outputs_exist`** skip policy compares asset filenames against
  `output_asset_specs`. Rename a spec and previously-skipped steps will
  re-run.
- **Parallel steps share the workflow run** but not their containers —
  they cannot read each other's `/workspace/` directly. Use
  `output_asset_specs` to hand artifacts forward.
- **An automatic step ends only when its agent calls `finish_session` or
  `fail_session`.** A Kiro agent that ends its turn without either gets a
  reminder typed into its terminal a minute or two later, up to 3 times. If it
  stops a fourth time, the step fails with a message saying so. Nothing is typed
  while someone has typed into the session's terminal in the last 10 minutes.
  A step whose terminal stays unchanged fails 30 to 35 minutes later. For Kiro,
  "unchanged" means its screen, even while the terminal keeps redrawing it; for
  other runtimes, that the terminal sent no output at all.

Writing the instructions themselves: see the [Prompt guide](prompt-guide.md).
