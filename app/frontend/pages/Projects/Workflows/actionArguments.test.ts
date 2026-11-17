import { describe, expect, it } from 'vitest';

import { allowedEffects, fieldsFor, fromArguments, toArguments } from './actionArguments';

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

  it('finds an argument the server served with camelized keys', () => {
    const snake = fieldsFor({ type: 'object', properties: { page_size: { type: 'integer' } } });
    expect(fromArguments({ pageSize: 5 }, snake)).toEqual({ page_size: '5' });
  });
});

describe('allowedEffects', () => {
  it('never lists an effect below the base', () => {
    expect(allowedEffects('read')).toEqual(['read', 'write', 'send', 'irreversible']);
    expect(allowedEffects('write')).toEqual(['write', 'send', 'irreversible']);
    expect(allowedEffects('irreversible')).toEqual(['irreversible']);
  });
});
