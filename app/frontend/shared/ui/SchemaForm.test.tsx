import '@testing-library/jest-dom/vitest';
import { useState } from 'react';
import { describe, expect, it } from 'vitest';

import { renderPage as render, screen, userEvent, within } from 'test/renderPage';

import { SchemaForm } from './SchemaForm';

type Args = Record<string, unknown>;

function Harness({ schema, initial = {}, readOnly = false }: { schema: Args; initial?: Args; readOnly?: boolean }) {
  const [value, setValue] = useState<Args>(initial);
  return (
    <>
      <SchemaForm schema={schema} value={value} onChange={setValue} readOnly={readOnly} />
      <output aria-label="emitted">{JSON.stringify(value)}</output>
    </>
  );
}

const emitted = () => JSON.parse(screen.getByLabelText('emitted').textContent ?? '{}') as Args;

describe('SchemaForm', () => {
  it('says so when the schema has no properties', () => {
    render(<SchemaForm schema={{}} value={{}} onChange={() => undefined} />);
    expect(screen.getByText('This takes no settings.')).toBeInTheDocument();
  });

  it('renders a string field, marks required ones and emits typed text', async () => {
    render(
      <Harness
        schema={{
          type: 'object',
          required: ['title'],
          properties: { title: { type: 'string', description: 'Heading' } },
        }}
      />,
    );
    const input = screen.getByRole('textbox', { name: /title/ });
    expect(input).toBeRequired();
    expect(screen.getByText('Heading')).toBeInTheDocument();
    await userEvent.type(input, 'Hello');
    expect(emitted()).toEqual({ title: 'Hello' });
  });

  it('renders descriptions as plain text, never as markup', () => {
    render(
      <Harness
        schema={{ type: 'object', properties: { a: { type: 'string', description: '<b>bold</b> <img src=x>' } } }}
      />,
    );
    expect(screen.getByText('<b>bold</b> <img src=x>')).toBeInTheDocument();
    expect(screen.queryByRole('img')).not.toBeInTheDocument();
  });

  it('emits numbers and integers as numbers and drops cleared ones', async () => {
    render(
      <Harness schema={{ type: 'object', properties: { points: { type: 'integer' }, ratio: { type: 'number' } } }} />,
    );
    await userEvent.type(screen.getByRole('textbox', { name: 'points' }), '3');
    await userEvent.type(screen.getByRole('textbox', { name: 'ratio' }), '1.5');
    expect(emitted()).toEqual({ points: 3, ratio: 1.5 });
    await userEvent.clear(screen.getByRole('textbox', { name: 'points' }));
    expect(emitted()).toEqual({ ratio: 1.5 });
  });

  it('emits a boolean and an enum choice', async () => {
    render(
      <Harness
        schema={{
          type: 'object',
          properties: { draft: { type: 'boolean' }, level: { type: 'string', enum: ['low', 'high'] } },
        }}
      />,
    );
    await userEvent.click(screen.getByRole('combobox', { name: 'draft' }));
    await userEvent.click(await screen.findByRole('option', { name: 'true' }));
    await userEvent.click(screen.getByRole('combobox', { name: 'level' }));
    await userEvent.click(await screen.findByRole('option', { name: 'high' }));
    expect(emitted()).toEqual({ draft: true, level: 'high' });
  });

  it('lets a number field take a reference instead', async () => {
    render(<Harness schema={{ type: 'object', properties: { points: { type: 'integer' } } }} />);

    await userEvent.click(screen.getByRole('checkbox', { name: 'points use a reference' }));
    await userEvent.type(screen.getByRole('textbox', { name: 'points' }), '{{{{output:4:count}}');

    expect(emitted()).toEqual({ points: '{{output:4:count}}' });
  });

  it('shows an existing reference in a boolean field as a reference', () => {
    render(
      <Harness
        schema={{ type: 'object', properties: { draft: { type: 'boolean' } } }}
        initial={{ draft: '{{context:is_draft}}' }}
      />,
    );
    expect(screen.getByRole('checkbox', { name: 'draft use a reference' })).toBeChecked();
    expect(screen.getByRole('textbox', { name: 'draft' })).toHaveValue('{{context:is_draft}}');
  });

  it('turning the reference off clears it', async () => {
    render(
      <Harness
        schema={{ type: 'object', properties: { level: { enum: ['a', 'b'] } } }}
        initial={{ level: '{{context:lvl}}' }}
      />,
    );
    await userEvent.click(screen.getByRole('checkbox', { name: 'level use a reference' }));
    expect(emitted()).toEqual({});
  });

  it('nests object properties', async () => {
    render(
      <Harness
        schema={{
          type: 'object',
          properties: {
            owner: { type: 'object', required: ['name'], properties: { name: { type: 'string' } } },
          },
        }}
      />,
    );
    const group = screen.getByRole('group', { name: 'owner' });
    await userEvent.type(within(group).getByRole('textbox', { name: /name/ }), 'Ada');
    expect(emitted()).toEqual({ owner: { name: 'Ada' } });
  });

  it('adds, edits and removes array items', async () => {
    render(<Harness schema={{ type: 'object', properties: { tags: { type: 'array', items: { type: 'string' } } } }} />);
    await userEvent.click(screen.getByRole('button', { name: 'Add tags item' }));
    await userEvent.type(screen.getByRole('textbox', { name: 'tags 1' }), 'x');
    await userEvent.click(screen.getByRole('button', { name: 'Add tags item' }));
    await userEvent.type(screen.getByRole('textbox', { name: 'tags 2' }), 'y');
    expect(emitted()).toEqual({ tags: ['x', 'y'] });

    await userEvent.click(screen.getByRole('button', { name: 'Remove tags 1' }));
    expect(emitted()).toEqual({ tags: ['y'] });
  });

  it('falls back to JSON for shapes it cannot draw', async () => {
    render(<Harness schema={{ type: 'object', properties: { any: { oneOf: [{ type: 'string' }] } } }} />);
    await userEvent.click(screen.getByRole('textbox', { name: 'any' }));
    await userEvent.paste('{"a":1}');
    expect(emitted()).toEqual({ any: { a: 1 } });
  });

  it('disables every control when read only', () => {
    render(
      <Harness readOnly schema={{ type: 'object', properties: { a: { type: 'string' }, n: { type: 'integer' } } }} />,
    );
    expect(screen.getByRole('textbox', { name: 'a' })).toBeDisabled();
    expect(screen.getByRole('textbox', { name: 'n' })).toBeDisabled();
    expect(screen.getByRole('checkbox', { name: 'n use a reference' })).toBeDisabled();
  });
});
