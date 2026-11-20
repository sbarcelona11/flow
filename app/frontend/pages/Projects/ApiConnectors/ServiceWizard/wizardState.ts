import type { ApiConnector } from '@/types/generated';

import { ACTION_EFFECTS, type ActionEffect, allowedEffects } from 'shared/lib/actionEffects';

/** The most operations one setup creates; the server refuses more (`Rest::ServiceSetup::MAX_OPERATIONS`). */
export const MAX_OPERATIONS = 200;

export type StepId = 'source' | 'connection' | 'operations' | 'names' | 'review' | 'try' | 'done';

export const STEP_ORDER: StepId[] = ['source', 'connection', 'operations', 'names', 'review', 'try', 'done'];

export const STEP_TITLES: Record<StepId, string> = {
  source: 'Where is the API described?',
  connection: 'Connection',
  operations: 'Choose operations',
  names: 'Name the operations',
  review: 'Review and create',
  try: 'Try it',
  done: 'Done',
};

export const STEP_SHORT_TITLES: Record<StepId, string> = {
  source: 'Source',
  connection: 'Connection',
  operations: 'Operations',
  names: 'Names',
  review: 'Review',
  try: 'Try it',
  done: 'Done',
};

export type AuthType = ApiConnector['authType'];

export interface ImportDraft {
  name: string;
  http_method: string;
  path: string;
  summary: string | null;
  description: string | null;
  effect: string;
  input_schema: Record<string, unknown>;
  tag?: string | null;
  response_hint?: 'json' | 'text' | null;
}

export interface AuthSuggestion {
  auth_type: AuthType;
  header_name: string | null;
  query_param: string | null;
}

export interface ImportPreview {
  base_url: string | null;
  drafts: ImportDraft[];
  warnings: string[];
  servers?: string[];
  auth_suggestions?: AuthSuggestion[];
}

export interface Connection {
  name: string;
  baseUrl: string;
  authType: AuthType;
  configItem: string;
  headerName: string;
  queryParam: string;
  usernameItem: string;
  passwordItem: string;
}

export type SecretField = 'configItem' | 'usernameItem' | 'passwordItem';

export interface OperationChoice {
  selected: boolean;
  effect: ActionEffect;
  label: string;
  description: string;
}

export interface CreatedService {
  connector: { id: number; name: string; editPath: string };
  operations: { id: number; name: string }[];
  blocks: { id: number; key: string; label: string }[];
  warnings: string[];
}

export interface WizardErrors {
  /** Messages for the step being left: what is missing before Next works. */
  step: string[];
  connector: string[];
  /** Keyed by the draft's position in `drafts`. */
  operations: Record<number, string[]>;
  review: string[];
}

export interface WizardState {
  step: StepId;
  loaded: boolean;
  drafts: ImportDraft[];
  servers: string[];
  authSuggestions: AuthSuggestion[];
  warnings: string[];
  connection: Connection;
  choices: OperationChoice[];
  createBlocks: boolean;
  /** The secret-to-host lines the person ticked "I understand" for; it only counts while they still match. */
  confirmedFor: string | null;
  created: CreatedService | null;
  errors: WizardErrors;
}

const NO_ERRORS: WizardErrors = { step: [], connector: [], operations: {}, review: [] };

const EMPTY_CONNECTION: Connection = {
  name: '',
  baseUrl: '',
  authType: 'none',
  configItem: '',
  headerName: '',
  queryParam: '',
  usernameItem: '',
  passwordItem: '',
};

export const initialWizardState = (): WizardState => ({
  step: 'source',
  loaded: false,
  drafts: [],
  servers: [],
  authSuggestions: [],
  warnings: [],
  connection: EMPTY_CONNECTION,
  choices: [],
  createBlocks: true,
  confirmedFor: null,
  created: null,
  errors: NO_ERRORS,
});

export type WizardAction =
  | { type: 'previewLoaded'; preview: ImportPreview }
  | { type: 'addressOnly'; baseUrl: string }
  | { type: 'setConnection'; patch: Partial<Connection> }
  | { type: 'useAuthSuggestion'; suggestion: AuthSuggestion }
  | { type: 'toggleOperation'; index: number; selected: boolean }
  | { type: 'selectOperations'; indexes: number[]; selected: boolean }
  | { type: 'patchOperation'; index: number; patch: Partial<Pick<OperationChoice, 'effect' | 'label' | 'description'>> }
  | { type: 'setCreateBlocks'; value: boolean }
  | { type: 'confirmSecretHosts'; lines: string[] | null }
  | { type: 'next' }
  | { type: 'back' }
  | { type: 'goto'; step: StepId }
  | { type: 'created'; service: CreatedService }
  | { type: 'failed'; errors: Partial<WizardErrors>; step?: StepId }
  | { type: 'startOver' };

export const isActionEffect = (value: string): value is ActionEffect => ACTION_EFFECTS.includes(value as ActionEffect);

/** The lowest effect an operation may be given: what the spec says, or `write` when it says something unknown. */
export const effectFloor = (draft: ImportDraft): ActionEffect =>
  isActionEffect(draft.effect) ? draft.effect : 'write';

const AUTH_ITEM_FIELDS: Record<AuthType, (keyof Connection)[]> = {
  none: [],
  bearer: ['configItem'],
  api_key_header: ['configItem'],
  api_key_query: ['configItem'],
  basic: ['usernameItem', 'passwordItem'],
};

/** The Config Item names the connection will send, once each, in a stable order. */
export const secretNames = (connection: Connection): string[] => {
  const names = AUTH_ITEM_FIELDS[connection.authType].map((field) => connection[field].trim()).filter(Boolean);
  return [...new Set(names)];
};

export const hostOf = (baseUrl: string): string | null => {
  try {
    const url = new URL(baseUrl.trim());
    if (url.protocol !== 'https:') return null;
    return url.hostname.toLowerCase().replace(/\.$/, '') || null;
  } catch {
    return null;
  }
};

/** The exact lines the server expects back as `confirmed_secret_host`: "ITEM → host". */
export const secretHostLines = (connection: Connection): string[] => {
  const host = hostOf(connection.baseUrl);
  return host ? secretNames(connection).map((name) => `${name} → ${host}`) : [];
};

export const secretsConfirmed = (state: WizardState): boolean => {
  const lines = secretHostLines(state.connection);
  return lines.length === 0 || state.confirmedFor === lines.join('\n');
};

const defaultName = (baseUrl: string): string => {
  const host = hostOf(baseUrl);
  if (!host) return '';
  const parts = host.split('.').filter((part) => part !== 'api' && part !== 'www');
  return (parts.length > 1 ? parts[parts.length - 2] : (parts[0] ?? '')).replace(/[^a-z0-9_-]/g, '');
};

const choiceFor = (draft: ImportDraft): OperationChoice => ({
  selected: false,
  effect: effectFloor(draft),
  label: draft.summary ?? '',
  description: draft.description ?? '',
});

const applySuggestion = (connection: Connection, suggestion: AuthSuggestion | undefined): Connection =>
  suggestion
    ? {
        ...connection,
        authType: suggestion.auth_type,
        headerName: suggestion.header_name ?? '',
        queryParam: suggestion.query_param ?? '',
      }
    : connection;

export const selectedIndexesOf = (choices: OperationChoice[]): number[] =>
  choices.flatMap((choice, index) => (choice.selected ? [index] : []));

export const selectedIndexes = (state: WizardState): number[] => selectedIndexesOf(state.choices);

/** What stops the person leaving `state.step` going forward. Empty means they can go on. */
export const problemsFor = (state: WizardState): string[] => {
  const { connection } = state;
  switch (state.step) {
    case 'source':
      return state.loaded ? [] : ['Read a source first, or enter the address.'];
    case 'connection': {
      const problems: string[] = [];
      if (connection.name.trim() === '') problems.push('Give the service a name.');
      if (hostOf(connection.baseUrl) === null)
        problems.push('Enter the address as an https URL, such as https://api.example.com.');
      if (AUTH_ITEM_FIELDS[connection.authType].some((field) => connection[field].trim() === '')) {
        problems.push('Choose the secret the service needs, or pick "No authentication".');
      }
      if (connection.authType === 'api_key_header' && connection.headerName.trim() === '') {
        problems.push('Enter the name of the header that carries the key.');
      }
      if (connection.authType === 'api_key_query' && connection.queryParam.trim() === '') {
        problems.push('Enter the name of the query parameter that carries the key.');
      }
      return problems;
    }
    case 'operations': {
      const chosen = selectedIndexes(state).length;
      if (state.drafts.length === 0)
        return [
          'This service has no operations to choose from, and it needs at least one. Go back and read a spec or a curl example.',
        ];
      if (chosen === 0) return ['Choose at least one operation.'];
      if (chosen > MAX_OPERATIONS)
        return [`Choose at most ${MAX_OPERATIONS} operations at a time. ${chosen} are chosen.`];
      return [];
    }
    case 'names':
      // The name is the block's label; without blocks it is not kept.
      return state.createBlocks && selectedIndexes(state).some((index) => state.choices[index].label.trim() === '')
        ? ['Every operation needs a name.']
        : [];
    default:
      return [];
  }
};

/** The operation errors without those of the operations that were just changed: the error was about what they were. */
const withoutErrorsOf = (errors: Record<number, string[]>, indexes: number[]): Record<number, string[]> =>
  Object.fromEntries(Object.entries(errors).filter(([index]) => !indexes.includes(Number(index))));

const move = (state: WizardState, step: StepId): WizardState => ({
  ...state,
  step,
  errors: { ...state.errors, step: [] },
});

const nextStep = (state: WizardState): StepId => {
  const index = STEP_ORDER.indexOf(state.step);
  const following = STEP_ORDER[Math.min(index + 1, STEP_ORDER.length - 1)];
  return following;
};

export const readOperationIndexes = (state: WizardState): number[] =>
  selectedIndexes(state).filter((index) => state.choices[index].effect === 'read');

export function wizardReducer(state: WizardState, action: WizardAction): WizardState {
  switch (action.type) {
    case 'previewLoaded': {
      const { preview } = action;
      const servers =
        preview.servers && preview.servers.length > 0 ? preview.servers : preview.base_url ? [preview.base_url] : [];
      const baseUrl = servers[0] ?? '';
      const suggestions = preview.auth_suggestions ?? [];
      const connection = applySuggestion({ ...EMPTY_CONNECTION, baseUrl, name: defaultName(baseUrl) }, suggestions[0]);
      return {
        ...initialWizardState(),
        loaded: true,
        drafts: preview.drafts,
        servers,
        authSuggestions: suggestions,
        warnings: preview.warnings,
        connection,
        choices: preview.drafts.map(choiceFor),
        step: 'source',
      };
    }
    case 'addressOnly':
      return {
        ...initialWizardState(),
        loaded: true,
        servers: [action.baseUrl],
        connection: { ...EMPTY_CONNECTION, baseUrl: action.baseUrl, name: defaultName(action.baseUrl) },
      };
    case 'setConnection':
      return {
        ...state,
        connection: { ...state.connection, ...action.patch },
        errors: { ...state.errors, step: [], connector: [] },
      };
    case 'useAuthSuggestion':
      return { ...state, connection: applySuggestion(state.connection, action.suggestion) };
    case 'toggleOperation':
      return {
        ...state,
        choices: state.choices.map((choice, index) =>
          index === action.index ? { ...choice, selected: action.selected } : choice,
        ),
        errors: { ...state.errors, step: [], operations: withoutErrorsOf(state.errors.operations, [action.index]) },
      };
    case 'selectOperations': {
      const wanted = new Set(action.indexes);
      return {
        ...state,
        choices: state.choices.map((choice, index) =>
          wanted.has(index) ? { ...choice, selected: action.selected } : choice,
        ),
        errors: { ...state.errors, step: [], operations: withoutErrorsOf(state.errors.operations, action.indexes) },
      };
    }
    case 'patchOperation': {
      const { index, patch } = action;
      const floor = state.drafts[index] ? allowedEffects(effectFloor(state.drafts[index])) : ACTION_EFFECTS;
      const effect = patch.effect && floor.includes(patch.effect) ? patch.effect : undefined;
      return {
        ...state,
        choices: state.choices.map((choice, position) =>
          position === index ? { ...choice, ...patch, effect: effect ?? choice.effect } : choice,
        ),
        errors: { ...state.errors, step: [], operations: withoutErrorsOf(state.errors.operations, [index]) },
      };
    }
    case 'setCreateBlocks':
      return { ...state, createBlocks: action.value };
    case 'confirmSecretHosts':
      return {
        ...state,
        confirmedFor: action.lines ? action.lines.join('\n') : null,
        errors: { ...state.errors, review: [] },
      };
    case 'next': {
      if (state.step === 'review' || state.step === 'done') return state;
      const problems = problemsFor(state);
      if (problems.length > 0) return { ...state, errors: { ...state.errors, step: problems } };
      return move(state, nextStep(state));
    }
    case 'back': {
      const index = STEP_ORDER.indexOf(state.step);
      if (state.step === 'done' || state.step === 'try' || index === 0) return state;
      return move(state, STEP_ORDER[index - 1]);
    }
    case 'goto':
      return move(state, action.step);
    case 'created': {
      const reads = readOperationIndexes(state).length > 0;
      return { ...state, created: action.service, errors: NO_ERRORS, step: reads ? 'try' : 'done' };
    }
    case 'failed':
      return { ...state, errors: { ...NO_ERRORS, ...action.errors }, step: action.step ?? state.step };
    case 'startOver':
      return initialWizardState();
  }
}

/** Where each server error belongs. Server positions in `operations.N` count the operations that were sent. */
export function placeSetupErrors(
  state: WizardState,
  errors: Record<string, string[]>,
  fallback: string,
): { step: StepId; errors: Partial<WizardErrors> } {
  const sent = selectedIndexes(state);
  const connector: string[] = [];
  const review: string[] = [];
  const operations: Record<number, string[]> = {};
  const whole: string[] = [];

  Object.entries(errors).forEach(([key, messages]) => {
    const position = /^operations\.(\d+)$/.exec(key);
    if (key === 'operations') whole.push(...messages);
    else if (key === 'connector.confirmed_secret_host') review.push(...messages);
    else if (key === 'connector' || key.startsWith('connector.')) connector.push(...messages);
    else if (position && sent[Number(position[1])] !== undefined) {
      const index = sent[Number(position[1])];
      operations[index] = [...(operations[index] ?? []), ...messages];
    } else review.push(...messages);
  });

  if (connector.length > 0) return { step: 'connection', errors: { connector, operations, review } };
  if (Object.keys(operations).length > 0 || whole.length > 0) {
    const step = [...whole, ...(Object.keys(operations).length > 0 ? ['Some operations need attention.'] : [])];
    return { step: 'operations', errors: { operations, review, step } };
  }
  return { step: 'review', errors: { review: review.length > 0 ? review : [fallback] } };
}
