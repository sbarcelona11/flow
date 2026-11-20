import { describe, expect, it } from 'vitest';

import { buildImportDraft, buildImportPreview } from 'test/factories/serviceWizard';

import {
  initialWizardState,
  MAX_OPERATIONS,
  placeSetupErrors,
  problemsFor,
  readOperationIndexes,
  secretHostLines,
  secretsConfirmed,
  type WizardAction,
  type WizardState,
  wizardReducer,
} from './wizardState';

const run = (actions: WizardAction[], from: WizardState = initialWizardState()) => actions.reduce(wizardReducer, from);

const loaded = (
  drafts = [buildImportDraft(), buildImportDraft({ name: 'create_invoice', http_method: 'POST', effect: 'write' })],
) => run([{ type: 'previewLoaded', preview: buildImportPreview({ drafts }) }]);

describe('wizardState', () => {
  it('refuses to leave the source step until something was read', () => {
    const state = run([{ type: 'next' }]);

    expect(state.step).toBe('source');
    expect(state.errors.step).toEqual(['Read a source first, or enter the address.']);
  });

  it('prefills the connection from the first server and the first auth suggestion', () => {
    const state = loaded();

    expect(state.connection).toMatchObject({ baseUrl: 'https://api.stripe.com', name: 'stripe', authType: 'bearer' });
  });

  it('moves forward and back and keeps what was chosen', () => {
    let state = loaded();
    state = run(
      [
        { type: 'next' },
        { type: 'setConnection', patch: { configItem: 'STRIPE_KEY' } },
        { type: 'next' },
        { type: 'toggleOperation', index: 1, selected: true },
        { type: 'patchOperation', index: 1, patch: { label: 'Create an invoice' } },
        { type: 'next' },
        { type: 'back' },
        { type: 'back' },
      ],
      state,
    );

    expect(state.step).toBe('connection');
    expect(state.connection.configItem).toBe('STRIPE_KEY');
    expect(state.choices[1]).toMatchObject({ selected: true, label: 'Create an invoice' });
  });

  it('blocks the connection step until a secret and a name are chosen', () => {
    const state = run([{ type: 'next' }, { type: 'next' }], loaded());

    expect(state.step).toBe('connection');
    expect(state.errors.step).toEqual(['Choose the secret the service needs, or pick "No authentication".']);
  });

  it('only offers effects at or above the draft and refuses a lower one', () => {
    const state = run([{ type: 'patchOperation', index: 1, patch: { effect: 'read' } }], loaded());
    expect(state.choices[1].effect).toBe('write');

    const raised = run([{ type: 'patchOperation', index: 1, patch: { effect: 'irreversible' } }], loaded());
    expect(raised.choices[1].effect).toBe('irreversible');
  });

  it('treats an unknown effect as write', () => {
    const state = loaded([buildImportDraft({ effect: 'dangerous' })]);

    expect(state.choices[0].effect).toBe('write');
  });

  it('selects all reads', () => {
    const state = run([{ type: 'selectOperations', indexes: [0], selected: true }], loaded());

    expect(state.choices.map((choice) => choice.selected)).toEqual([true, false]);
    expect(readOperationIndexes(state)).toEqual([0]);
  });

  it('writes the secret and host line the server expects and drops the confirmation when it changes', () => {
    let state = run([{ type: 'setConnection', patch: { configItem: 'STRIPE_KEY' } }], loaded());
    const lines = secretHostLines(state.connection);
    expect(lines).toEqual(['STRIPE_KEY → api.stripe.com']);

    state = run([{ type: 'confirmSecretHosts', lines }], state);
    expect(secretsConfirmed(state)).toBe(true);

    state = run([{ type: 'setConnection', patch: { baseUrl: 'https://evil.example.com' } }], state);
    expect(secretsConfirmed(state)).toBe(false);
  });

  it('needs no confirmation without a secret', () => {
    expect(secretsConfirmed(run([{ type: 'setConnection', patch: { authType: 'none' } }], loaded()))).toBe(true);
  });

  it('goes to Try only when a read operation was created, otherwise to Done', () => {
    const service = { connector: { id: 1, name: 'stripe', editPath: '/x' }, operations: [], blocks: [], warnings: [] };
    const withRead = run(
      [
        { type: 'toggleOperation', index: 0, selected: true },
        { type: 'created', service },
      ],
      loaded(),
    );
    const writeOnly = run(
      [
        { type: 'toggleOperation', index: 1, selected: true },
        { type: 'created', service },
      ],
      loaded(),
    );

    expect(withRead.step).toBe('try');
    expect(writeOnly.step).toBe('done');
  });

  it('keeps server errors on the step they belong to', () => {
    const state = run(
      [{ type: 'failed', step: 'connection', errors: { connector: ['Name has already been taken'] } }],
      loaded(),
    );

    expect(state.step).toBe('connection');
    expect(state.errors.connector).toEqual(['Name has already been taken']);
  });

  describe('operations', () => {
    const toOperations = (state: WizardState) =>
      run([{ type: 'next' }, { type: 'setConnection', patch: { authType: 'none' } }, { type: 'next' }], state);

    it('cannot be left with nothing chosen, and an address alone has nothing to choose', () => {
      const addressOnly = run([{ type: 'addressOnly', baseUrl: 'https://api.example.com' }]);
      const state = run([{ type: 'next' }], toOperations(addressOnly));

      expect(state.step).toBe('operations');
      expect(state.errors.step).toEqual([
        'This service has no operations to choose from, and it needs at least one. Go back and read a spec or a curl example.',
      ]);
    });

    it('asks for at least one operation when there are some to choose from', () => {
      const state = run([{ type: 'next' }], toOperations(loaded()));

      expect(state.errors.step).toEqual(['Choose at least one operation.']);
    });

    it('refuses more than the most one setup can create, and says how many are chosen', () => {
      const many = Array.from({ length: MAX_OPERATIONS + 1 }, (_, i) =>
        buildImportDraft({ name: `op_${i}`, path: `/${i}` }),
      );
      let state = toOperations(loaded(many));
      state = run([{ type: 'selectOperations', indexes: many.map((_, i) => i), selected: true }], state);

      expect(problemsFor(state)).toEqual([
        `Choose at most ${MAX_OPERATIONS} operations at a time. ${MAX_OPERATIONS + 1} are chosen.`,
      ]);
      expect(run([{ type: 'next' }], state).step).toBe('operations');
    });

    it('lets go of an operation error once that operation is changed or let go', () => {
      let state = run(
        [
          { type: 'toggleOperation', index: 0, selected: true },
          { type: 'toggleOperation', index: 1, selected: true },
          { type: 'failed', errors: { operations: { 0: ['Name has already been taken'], 1: ['Bad path'] } } },
        ],
        loaded(),
      );

      state = run([{ type: 'patchOperation', index: 0, patch: { label: 'Other' } }], state);
      expect(state.errors.operations).toEqual({ 1: ['Bad path'] });
      state = run([{ type: 'toggleOperation', index: 1, selected: false }], state);
      expect(state.errors.operations).toEqual({});
    });

    it('puts a server error about the operations as a whole on the operations step', () => {
      const state = run([{ type: 'toggleOperation', index: 0, selected: true }], loaded());

      const placed = placeSetupErrors(state, { operations: ['Choose at least one operation'] }, 'fallback');

      expect(placed.step).toBe('operations');
      expect(placed.errors.step).toEqual(['Choose at least one operation']);
    });
  });

  it('asks for a name for each operation only while blocks are made from them', () => {
    const base = run(
      [
        { type: 'toggleOperation', index: 0, selected: true },
        { type: 'patchOperation', index: 0, patch: { label: '' } },
        { type: 'goto', step: 'names' },
      ],
      loaded(),
    );

    expect(problemsFor(base)).toEqual(['Every operation needs a name.']);
    expect(problemsFor(run([{ type: 'setCreateBlocks', value: false }], base))).toEqual([]);
  });
});
