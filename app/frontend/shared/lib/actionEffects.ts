export type ActionEffect = 'read' | 'write' | 'send' | 'irreversible';

export const ACTION_EFFECTS: ActionEffect[] = ['read', 'write', 'send', 'irreversible'];

export const allowedEffects = (base: ActionEffect): ActionEffect[] =>
  ACTION_EFFECTS.slice(ACTION_EFFECTS.indexOf(base));

export const EFFECT_LABELS: Record<ActionEffect, string> = {
  read: 'Read',
  write: 'Write',
  send: 'Send',
  irreversible: 'Irreversible',
};

export const EFFECT_TEXTS: Record<ActionEffect, string> = {
  read: 'Only looks something up; nothing changes.',
  write: 'Creates or changes data in the connected system.',
  send: 'Sends something to other people, such as a message or an email.',
  irreversible: "Does something that can't be undone, such as deleting data.",
};
