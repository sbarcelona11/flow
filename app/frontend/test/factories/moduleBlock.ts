import type { ModuleBlock } from '@/types/generated';

// The `: ModuleBlock` annotations are the compile-time drift contract, as for buildStep.
export const buildBlock = (overrides: Partial<ModuleBlock> = {}): ModuleBlock => ({
  key: 'local/fetch@1',
  label: 'Fetch',
  executor: 'action',
  config: {},
  status: 'valid',
  reason: null,
  unresolved: false,
  effect: 'read',
  origin: 'web',
  reviewState: 'reviewed',
  description: null,
  ports: { in: {}, out: {} },
  composite: null,
  target: {
    type: 'rest_operation',
    connection: null,
    operation: 'get',
    name: 'get',
    mcpServerId: null,
    tool: null,
    toolId: null,
    apiOperationId: 1,
  },
  ...overrides,
});

type CompositeShape = NonNullable<ModuleBlock['composite']>;

/** An enabled composite block: its ports and the steps it holds, as `GET blocks` lists it. */
export const buildCompositeBlock = (
  overrides: Partial<ModuleBlock> = {},
  composite: Partial<CompositeShape> = {},
): ModuleBlock =>
  buildBlock({
    key: 'local/invoice-flow@1',
    label: 'Invoice flow',
    executor: 'composite',
    effect: null,
    target: null,
    ports: { in: { invoice: 'string' }, out: { sent: 'string' } },
    composite: {
      ports: {
        in: { invoice: { type: 'string', description: null, targets: [{ node: 'send_invoice', argument: 'body' }] } },
        out: { sent: { type: 'string', step: 'send_invoice', output: 'sent.json' } },
      },
      steps: [
        { key: 'summarise', name: 'Summarise', kind: 'agent' },
        { key: 'send_invoice', name: 'Send invoice', kind: 'action' },
      ],
      ...composite,
    },
    ...overrides,
  });
