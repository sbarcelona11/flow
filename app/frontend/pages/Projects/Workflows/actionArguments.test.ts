import { describe, expect, it } from 'vitest';

import type { Step } from '@/types/generated';

import {
  allowedEffects,
  fieldsFor,
  fromArguments,
  MAX_OUTPUT_TOKENS,
  toArguments,
  withoutPortBinding,
  withPortBinding,
} from './actionArguments';
import { aggregatePayload, draftStep } from './builderDraft';

const schema = {
  type: 'object',
  required: ['title'],
  properties: {
    title: { type: 'string', description: 'Issue title' },
    points: { type: 'integer' },
    ratio: { type: 'number' },
    draft: { type: 'boolean' },
    priority: { type: 'string', enum: ['low', 'high'] },
    labels: { type: 'array', items: { type: 'string' } },
    meta: { type: 'object' },
    anything: {},
  },
};

describe('fieldsFor', () => {
  it('maps each top-level property to a field', () => {
    expect(fieldsFor(schema).map(({ name, type, required }) => ({ name, type, required }))).toEqual([
      { name: 'title', type: 'string', required: true },
      { name: 'points', type: 'integer', required: false },
      { name: 'ratio', type: 'number', required: false },
      { name: 'draft', type: 'boolean', required: false },
      { name: 'priority', type: 'enum', required: false },
      { name: 'labels', type: 'json', required: false },
      { name: 'meta', type: 'json', required: false },
      { name: 'anything', type: 'json', required: false },
    ]);
  });

  it('keeps the enum options and the description', () => {
    const fields = fieldsFor(schema);
    expect(fields.find((f) => f.name === 'priority')?.options).toEqual(['low', 'high']);
    expect(fields.find((f) => f.name === 'title')?.description).toBe('Issue title');
  });

  it('is empty for a schema without properties', () => {
    expect(fieldsFor({})).toEqual([]);
  });
});

describe('toArguments', () => {
  const fields = fieldsFor(schema);

  it('converts each value to its field type and leaves empty values out', () => {
    expect(
      toArguments(
        { title: 'Bug', points: '3', ratio: '0.5', draft: 'true', priority: 'high', labels: '["a","b"]', meta: '' },
        fields,
      ),
    ).toEqual({ title: 'Bug', points: 3, ratio: 0.5, draft: true, priority: 'high', labels: ['a', 'b'] });
  });

  it('keeps a context placeholder as a string in any field', () => {
    const values = {
      title: '{{context:issue.title}}',
      points: '{{context:issue.points}}',
      draft: '{{context:issue.draft}}',
      labels: '{{context:issue.labels}}',
    };
    expect(toArguments(values, fields)).toEqual(values);
  });

  it('keeps text that is not a valid number or JSON as typed', () => {
    expect(toArguments({ points: 'abc', labels: '[1,' }, fields)).toEqual({ points: 'abc', labels: '[1,' });
  });

  it('keeps a placeholder inside a text value', () => {
    expect(toArguments({ title: 'Fix {{context:issue.key}} now' }, fields)).toEqual({
      title: 'Fix {{context:issue.key}} now',
    });
  });
});

describe('fromArguments', () => {
  const fields = fieldsFor(schema);

  it('round trips typed values and placeholders', () => {
    const values = {
      title: 'Bug',
      points: '3',
      ratio: '0.5',
      draft: 'false',
      priority: 'low',
      labels: '{{context:issue.labels}}',
      meta: '{\n  "a": 1\n}',
    };
    expect(fromArguments(toArguments(values, fields), fields)).toEqual(values);
  });

  it('is empty for missing arguments', () => {
    expect(fromArguments({}, fields)).toEqual({});
  });
});

describe('allowedEffects', () => {
  it('never lists an effect below the base', () => {
    expect(allowedEffects('read')).toEqual(['read', 'write', 'send', 'irreversible']);
    expect(allowedEffects('write')).toEqual(['write', 'send', 'irreversible']);
    expect(allowedEffects('irreversible')).toEqual(['irreversible']);
  });
});

const action = (id: number, patch: Partial<Step['kindConfig']> = {}, deps: number[] = []): Step => ({
  ...draftStep([], `Step ${id}`, 'action'),
  id,
  position: id,
  dependsOnStepIds: deps,
  kindConfig: { target: 'mcp_tool', arguments: {}, ...patch },
});

describe('withPortBinding', () => {
  const bind = { from: 1, port: 'rows', to: 2, argument: 'input' };

  it('writes the whole-value output token and the dependency it needs', () => {
    const next = withPortBinding([action(1), action(2)], bind);
    const target = next?.find((s) => s.id === 2);
    expect(target?.kindConfig.arguments).toEqual({ input: '{{output:1:rows.json}}' });
    expect(target?.dependsOnStepIds).toEqual([1]);
  });

  it('keeps an existing dependency and the other arguments', () => {
    const next = withPortBinding([action(1), action(2, { arguments: { other: 'x' } }, [1])], bind);
    const target = next?.find((s) => s.id === 2);
    expect(target?.dependsOnStepIds).toEqual([1]);
    expect(target?.kindConfig.arguments).toEqual({ other: 'x', input: '{{output:1:rows.json}}' });
  });

  it('refuses a binding whose dependency would close a cycle', () => {
    expect(withPortBinding([action(1, {}, [2]), action(2)], bind)).toBeNull();
  });

  it('refuses a binding to itself', () => {
    expect(withPortBinding([action(1), action(2)], { ...bind, from: 2 })).toBeNull();
  });

  it('refuses a Wrapper target, which cannot read step outputs', () => {
    expect(withPortBinding([action(1), action(2, { target: 'wrapper' })], bind)).toBeNull();
  });

  it('refuses a twenty-first output token on one action', () => {
    const arguments_ = Object.fromEntries(
      Array.from({ length: MAX_OUTPUT_TOKENS }, (_, i) => [`a${i}`, `{{output:1:p${i}.json}}`]),
    );
    expect(withPortBinding([action(1), action(2, { arguments: arguments_ })], bind)).toBeNull();
    expect(
      withPortBinding([action(1), action(2, { arguments: arguments_ })], { ...bind, argument: 'a3' }),
    ).not.toBeNull();
  });

  it('counts output tokens nested in arrays and objects towards the cap', () => {
    const nested = { many: Array.from({ length: MAX_OUTPUT_TOKENS }, (_, i) => ({ v: `{{output:1:p${i}.json}}` })) };
    expect(withPortBinding([action(1), action(2, { arguments: nested })], bind)).toBeNull();
  });

  it('names an unsaved step by the key the Save payload uses, so the binding survives Save', () => {
    const draft = [action(-1), action(-2)];
    const next = withPortBinding(draft, { from: -1, port: 'rows', to: -2, argument: 'input' }) as Step[];
    const payload = aggregatePayload({} as never, next).steps;
    const target = payload.find((s) => s.key === 'new-2');
    expect((target?.kindConfig.arguments as Record<string, string>).input).toBe('{{output:new-1:rows.json}}');
    expect(target?.dependsOnStepIds).toEqual(['new-1']);
  });
});

describe('withoutPortBinding', () => {
  it('clears only the argument and keeps the dependency', () => {
    const steps = [action(1), action(2, { arguments: { input: '{{output:1:rows.json}}', other: 'x' } }, [1])];
    const target = withoutPortBinding(steps, 2, 'input').find((s) => s.id === 2);
    expect(target?.kindConfig.arguments).toEqual({ other: 'x' });
    expect(target?.dependsOnStepIds).toEqual([1]);
  });
});
