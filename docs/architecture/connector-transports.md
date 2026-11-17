# Adding a connector transport

A transport is how the platform reaches an external system: MCP, a Wrapper, REST. Adding
one (GraphQL, SQL, gRPC, SOAP) is one class plus its contract test. Design background:
`docs/design/visual-block-builder.md` §3.6 (D13).

## Two levels of extension

| Level | What is added | How |
|---|---|---|
| Data | a connection over an existing transport (another REST API, another MCP server) | a record or manifest; no code |
| Code | a new transport | one class implementing the port, this guide |

Reach for code only when no existing transport can speak to the system.

## The port

`Connectors::Transport` (`app/services/connectors/transport.rb`) is the only thing the
action engine knows. A subclass declares `transport :key, target: "<key>_operation", position: N`
and is found through `Connectors::Registry`; nothing switches on transport names.

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
- **Secrets only through `Result#redactor`.** Return a redactor that scrubs every secret the call used; the contract checks that a secret echoed back appears nowhere once redacted, in text, error or structured output.
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

### Known extra step

`Step::ACTION_TARGETS` (`app/models/step.rb`) and the type union in `ActionTargetResource`
are fixed lists today. Add the new target (`graphql_operation`) to both, then run
`bin/rails typelizer:generate`, but do it last, once the contract test is green: adding the target makes the transport's hooks reachable. This goes away when they are derived from the registry.

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
