import '@testing-library/jest-dom/vitest';
import { describe, expect, it, vi } from 'vitest';

import type { Step } from '@/types/generated';
import { buildBlock } from 'test/factories/moduleBlock';
import { buildStep } from 'test/factories/step';
import { answerFetch } from 'test/fetchStub';
import { act, renderHook, waitFor } from 'test/renderPage';

import { useCompositeInsertion } from './useCompositeInsertion';

const EXPAND = 'POST /api/v1/projects/7/blocks/expand';
const INSTANCE = '11111111-1111-4111-8111-111111111111';

const composite = buildBlock({
  key: 'local/flow@1',
  label: 'Flow',
  executor: 'composite',
  target: null,
  ports: { in: {}, out: {} },
  composite: { ports: { in: {}, out: {} }, steps: [] },
});

/** What the server answers: the layout starts at `at`, one column every 320. */
const serverExpansion = (init?: RequestInit) => {
  const body = JSON.parse(String(init?.body)) as { at?: { x: number; y: number } };
  const at = body.at ?? { x: 0, y: 0 };
  return {
    instance: INSTANCE,
    warnings: [],
    unbound: [],
    steps: [
      {
        key: 'new-1',
        name: 'Summarise',
        kind: 'agent',
        canvas_position: { x: at.x, y: at.y },
        composite: { ref: 'local/flow@1', instance: INSTANCE, node: 'summarise' },
      },
      {
        key: 'new-2',
        name: 'Send',
        kind: 'agent',
        depends_on_step_ids: ['new-1'],
        canvas_position: { x: at.x + 320, y: at.y },
        composite: { ref: 'local/flow@1', instance: INSTANCE, node: 'send' },
      },
    ],
  };
};

function setup(initial: Step[] = []) {
  let steps = initial;
  const setSteps = vi.fn((updater: (prev: Step[]) => Step[]) => {
    steps = updater(steps);
  });
  const view = renderHook(() =>
    useCompositeInsertion({
      projectId: 7,
      workflowId: 3,
      steps,
      blocks: [composite],
      setSteps,
      announce: vi.fn(),
    }),
  );
  return { hook: view, current: () => steps };
}

describe('Projects/Workflows/useCompositeInsertion', () => {
  it('lands the steps at the canvas position once, not at twice the offset', async () => {
    answerFetch({ [EXPAND]: serverExpansion });
    const { hook, current } = setup();

    act(() => hook.result.current.start(composite, { x: 400, y: 200 }));

    await waitFor(() => expect(current()).toHaveLength(2));
    expect(current().map((s) => s.canvasPosition)).toEqual([
      { x: 400, y: 200 },
      { x: 720, y: 200 },
    ]);
  });

  it('gives two insertions started before a render different draft ids', async () => {
    answerFetch({ [EXPAND]: serverExpansion });
    const { hook, current } = setup();

    act(() => {
      hook.result.current.start(composite, { x: 0, y: 0 });
      hook.result.current.start(composite, { x: 0, y: 400 });
    });

    await waitFor(() => expect(current()).toHaveLength(4));
    expect(new Set(current().map((s) => s.id)).size).toBe(4);
  });

  it('makes the first steps of the block run after the step the insertion was made from', async () => {
    answerFetch({ [EXPAND]: serverExpansion });
    const { hook, current } = setup([buildStep({ id: 5, position: 1 })]);

    act(() => hook.result.current.start(composite, { x: 0, y: 0 }, 5));

    await waitFor(() => expect(current()).toHaveLength(3));
    const [, first, second] = current();
    expect(first.dependsOnStepIds).toEqual([5]);
    expect(second.dependsOnStepIds).toEqual([first.id]);
  });
});
