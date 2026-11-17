# Adding a connector transport

A transport is how the platform reaches an external system: MCP, a Wrapper, REST. Adding
one (GraphQL, SQL, gRPC, SOAP) is one class plus its contract test, then a short list of literal edits (see "Literal touchpoints"). Design background:
`docs/design/visual-block-builder.md` §3.6 (D13).

## Two levels of extension

| Level | What is added | How |
|---|---|---|
| Data | a connection over an existing transport (another REST API, another MCP server) | a record or manifest; no code |
| Code | a new transport | one class implementing the port, its contract test, and the literal edits listed below |

Reach for code only when no existing transport can speak to the system.

## The port

`Connectors::Transport` (`app/services/connectors/transport.rb`) is the only thing the
action engine knows. A subclass declares `transport :key, target: "<key>_operation", position: N`
and is found through `Connectors::Registry`. The pipeline's governance does not depend on a transport's name, but several models, resources and the builder still carry a literal per built-in transport (see "Literal touchpoints").

| Hook | Purpose |
|---|---|
| `connections(project)` | the connections a project can pick from |
| `connection_for(kind_config, project)` / `connection_of(action_call)` | resolve a step's connection, and the connection an action call used |
| `operations(connection)` | `Connectors::Operation` entries: key, name, description, `input_schema`, `output_schema`, `base_effect`, `drifted` |
| `target_attributes`, `target_name`, `label`, `owner`, `scope_of` | identify and display the target; never include a secret |
| `call(connection:, operation:, arguments:, context:)` | make the call, return a `Connectors::Result` |
| `probe(connection)` | check the connection works, without side effects |

Defaults exist for `find_operation`, `awaiting_operations?`, `action_blocker`,
`operation_noun`, `recorded_name`, `config_label`, `missing_config_item_names` and `async?`
(false). `status` and `finish` are only for async transports.

`Connectors::Result` carries `ok`, `structured`, `text`, `error`, `unknown`, `status`,
`config_item_names` and `redactor`. `unknown: true` means the request may have been sent
and its outcome is not known; the pipeline then never retries it.

## The pipeline contract

The transport only makes the call. Governance belongs to `Actions::Pipeline`: target
check, effect floor, approval, argument validation, attempt marks, redaction, outcome
classification, outputs and audit. A transport must not reimplement or skip any of it.

Constraints for every new transport:

- **Exactly one backend call, no automatic retries.** The contract asserts this.
- **Classify the failure.** A definite rejection, or a failure before anything was sent, is a known failure. A failure after the request may have reached the backend is `unknown`.
- **Bound the response.** REST caps at 10 MB streamed; the MCP gem caps at 4 MB. A new transport caps its own, and the body of an oversize answer is not carried in the result.
- **Never follow redirects with credentials.**
- **Return fields free of secrets, and a redactor.** `Result#redactor` must scrub every secret the call used. The pipeline applies it to `error`, `text` and every string (and key) of `structured` before storing the output or writing `ActionCall#error`, and the contract asserts that a secret echoed back appears nowhere in the Result's own fields, so a transport redacts its own strings and the redactor is the second line.
- **Async transports** (`async? == true`) need a `Tool` connection and every required hook, including `status` and `finish`; otherwise the pipeline refuses before the attempt mark. The Wrapper transport still carries Wrapper wording in the pipeline ("the Wrapper"); a second async transport will need that moved behind the port.

## Generate the skeleton

```bash
docker compose exec -T web bin/rails generate connector_transport graphql
```

The name is snake_case, `/\A[a-z][a-z0-9_]{1,31}\z/`, and does not end in `_contract` or `_test`. The generator refuses a name that is
already a transport key or target, a constant, or has any of its files. It creates:

- `app/services/connectors/transports/graphql.rb`: registered as `transport :graphql, target: "graphql_operation", position: <next>`. Every required hook raises `NotImplementedError` with a TODO until implemented; `connections` returns `[]` so the unfinished transport does not break the catalog.
- `test/services/connectors/transports/graphql_contract_test.rb`: includes `Connectors::TransportContract`. Its `stub_backend` raises `NotImplementedError` ("wire this to your backend seam"), so the test fails until the transport and the seam are real.
- `config/connectors/graphql.schema.json`: JSON Schema of the connection settings (base URL, auth type enum, config item name). The connection form will be generated from it.

It edits no existing file and prints the manual steps.

### Literal touchpoints a new transport still needs

These places still hold a literal for each of the three built-in transports, so a fourth
transport does not work from its class alone:

| Where | What it needs today |
|---|---|
| `Step::ACTION_TARGETS`, `validate_action_config` and `normalized_action_config` (`app/models/step.rb`) | the target in the list, a branch in the `case` that validates its connection key, and its connection key kept by the normalization (otherwise it is dropped on save) |
| `Actions::Catalog#target_for` and `Catalog::Target` | `target_attributes` may only return keys `Target` already has; a new key raises `ArgumentError` and breaks the project's whole target list |
| `ActionCall` and `Pipeline#call_attributes` | the audit row has a foreign-key column per transport, so `connection_of(action_call)` has nothing to read for a new one |
| `Pipeline` and `Actions::TargetCheck` | literal `"wrapper"` branches (output tokens refused, async start); a transport that pastes arguments into a shell needs the same guard, and there is no port hook for it |
| `ActionTargetResource`, `StepResource` and `ModuleBlockResource` | literal TypeScript unions (run `bin/rails typelizer:generate`) |
| Builder frontend (`ActionStepFields.tsx`, `builderDraft.ts`) | ternaries over the target; an unknown target is drafted as an MCP step |
| `WorkflowDuplicator`, `Templates::Exporter`, `Installer`, `Validator` | a `case` on the target |

`WorkflowRun#resendable_action_calls` is derived from `Connectors::Registry.targets`
and needs no edit. Do the edits above last, once the contract test is green: adding the
target to `ACTION_TARGETS` makes the transport's hooks reachable. Removing these literals
(a port-driven connection key, a generic connection reference on `ActionCall`, a port hook
for "may read step outputs") is deferred: see "Deferred".

## The contract suite

`Connectors::TransportContract` (`test/support/connectors/transport_contract.rb`) is the
shared Minitest module. The including test defines `transport`, `connection`, `operation`,
`context`, `secret`, `backend_calls` and `stub_backend(outcome)` for `:success`,
`:known_failure`, `:unknown_after_send`, `:timeout_before_send`, `:oversize`,
`:secret_echo` and `:secret_echo_structured`. Stub at the app-owned backend seam, not a
vendor gem (`docs/testing.md`). Run it with:

```bash
docker compose exec -T web bin/rails test test/services/connectors/transports/graphql_contract_test.rb
```

## Worked example: REST

`app/services/connectors/transports/rest.rb` is the reference for a synchronous transport.

- **Registration:** `transport :rest, target: "rest_operation", position: 3`.
- **Connection:** an `ApiOperation`; `connections` and `connection_for` scope to the project's enabled connectors, `connection_of` returns `action_call.api_operation`.
- **Operations:** one `Operation` per `ApiOperation`, with its `input_schema` and the base effect from `Actions::Effect`.
- **Display:** `owner` is the connector name, `target_name` is `"POST /charges"`, `label` joins them; none holds a secret.
- **Call:** delegates to `Rest::OperationCaller`, which streams the response up to the cap, blocks redirects with credentials, and returns a `Result` with a redactor; `call` only normalizes `structured` to JSON.
- **Contract test:** `test/services/connectors/transports/rest_contract_test.rb` builds a connector with a secret config item and stubs the HTTP endpoint with WebMock for each outcome; `backend_calls` counts requests to that endpoint.

Follow the same shape: resolve the connection, build one request, bound the answer,
classify, return a `Result` with a redactor.

## Module schemas (manifest v1)

Types and block `config` in a module manifest are JSON Schemas written by project members, and later by marketplace publishers. `Modules::Manifest` refuses patterns that are invalid or not linear-time (`Regexp.linear_time?`), `format: "regex"` and the `$ref`/`$id`/`$schema` family at save time. Anything that later validates data against these schemas must still build the validator with `regexp_resolver: "ecma"` (so `^`/`$` anchor the whole value, as in `Runners::ConfigSchema`) and rescue `Regexp::TimeoutError`, because the global `Regexp.timeout` (1 s) is the only backstop for a pattern that slipped through.

Blocks, typed ports and the upstream-output arguments that build on a transport are in
`docs/architecture/workflows.md` ("Blocks and typed ports"). A block names a transport's
operation, so a transport added here is usable from a block with no further change;
note that action arguments can't read step outputs when the target is a Wrapper.

### Deferred

Not built, and not needed to add a transport:

- **Capability provider mapping.** A capability manifest is a contract (input and output types); no connection can declare that it implements one, so a block that uses a capability stays `unresolved`.
- **Transport extensibility beyond the port.** Removing the literal touchpoints above: a port-driven connection key and config validation, a generic connection reference on `ActionCall`, a port hook for "may read step outputs", registry-derived TypeScript unions and builder.
- **`probe`.** Declared on the port and generated as a TODO; nothing implements or calls it, and `ProbeResult` is a placeholder.
- **Connection settings form.** `config/connectors/<name>.schema.json` is generated, but nothing reads it.
- **Generator docs stub.** The generator creates no documentation stub.
- **Blocks in `Actions::Catalog`.** Blocks are served by `GET /api/v1/projects/:project_id/blocks`, not as catalog targets.
- **A `type_mismatch` fix suggestion.** The issue carries none.
- **UI or API for module definitions.** Rows are created through the model only (create, enable, archive).
- **Template export of workflows with blocks.** Refused today.
- **Detaching a block.** A step whose block was removed or became invalid is locked and refuses later changes; there is no "detach from block".
- **Block `default` / `const` prefill.** A new step from a block starts with empty arguments.
- **`ActionCall#transport` on an unregistered stored target.** It raises instead of falling back to a label.
- **Agent output validation against declared types.** The type of a block's out port is checked only by the builder's data-flow check.
- **Subtype compatibility** between types, and `file<image/*>`-style references.
- **For each insertion.** A `list<T>` output feeding a `T` argument is reported as a mismatch; the builder does not insert the loop.
