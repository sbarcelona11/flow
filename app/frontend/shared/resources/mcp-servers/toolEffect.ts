export type ToolEffect = 'read' | 'write' | 'irreversible';

export function toolEffect(annotations: Record<string, unknown>): ToolEffect {
  if (annotations.readOnlyHint === true) return 'read';
  if (annotations.destructiveHint === true) return 'irreversible';
  return 'write';
}
