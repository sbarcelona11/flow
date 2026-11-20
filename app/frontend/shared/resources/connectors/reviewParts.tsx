import { Alert, Badge, Code, Group, Stack, Text, UnstyledButton } from '@mantine/core';
import { IconChevronRight } from '@tabler/icons-react';
import { type ReactNode, useState } from 'react';

import { type ActionEffect, EFFECT_LABELS, EFFECT_TEXTS } from 'shared/lib/actionEffects';

const isEffect = (value: string | undefined): value is ActionEffect => value !== undefined && value in EFFECT_LABELS;

/** Everything a reviewer reads comes from a spec, a manifest or an agent, so it is only ever rendered as plain text. */
export function CallLine({ method, path, host }: { method: string; path: string; host: string }) {
  return (
    <Group gap={6} wrap="nowrap" align="baseline">
      <Badge size="sm" variant="light" radius="sm">
        {method}
      </Badge>
      <Text fz={13} ff="monospace" style={{ wordBreak: 'break-all' }}>{`${path} on ${host}`}</Text>
    </Group>
  );
}

/** The only place "ITEM → host" appears: built from the server's checked Config Item names and parsed host, boxed apart from
 * everything a proposer wrote. */
export function SecretLines({ bindings }: { bindings: string[] }) {
  const routes = bindings
    .map((binding) => binding.split(' → '))
    .filter((parts): parts is [string, string] => parts.length === 2 && parts[0] !== '' && parts[1] !== '');
  if (routes.length === 0) return <Text fz={13}>No secret is sent.</Text>;
  return (
    <Stack
      gap={2}
      p="xs"
      aria-label="Secrets sent"
      role="group"
      style={{ border: '1px solid var(--app-border-default)', borderRadius: 'var(--mantine-radius-sm)' }}
    >
      {routes.map(([item, host]) => (
        <Text key={`${item}|${host}`} fz={13} ff="monospace" style={{ wordBreak: 'break-all' }}>
          {`${item} → ${host}`}
        </Text>
      ))}
    </Stack>
  );
}

export function EffectLine({ effect }: { effect: string | undefined }) {
  if (!isEffect(effect)) return <Text fz={13}>{effect ?? 'Unknown'}</Text>;
  return (
    <Text fz={13}>
      <b>{EFFECT_LABELS[effect]}</b>
      {`. ${EFFECT_TEXTS[effect]}`}
    </Text>
  );
}

export function ReviewSection({ title, children }: { title: string; children: ReactNode }) {
  return (
    <Stack gap={4}>
      <Text fz={12} fw={600} c="dimmed" tt="uppercase">
        {title}
      </Text>
      {children}
    </Stack>
  );
}

/** The raw definition, read-only and shut by default: the summary above it is what a person is asked to approve. */
export function AdvancedJson({
  value,
  label = 'Advanced: the definition as written',
}: {
  value: unknown;
  label?: string;
}) {
  const [open, setOpen] = useState(false);
  return (
    <Stack gap={4}>
      <UnstyledButton onClick={() => setOpen((current) => !current)} aria-expanded={open} aria-label="Advanced">
        <Group gap={4}>
          <IconChevronRight size={14} style={{ transform: open ? 'rotate(90deg)' : undefined }} />
          <Text fz={13}>{label}</Text>
        </Group>
      </UnstyledButton>
      {open && (
        <Code block mah={320} style={{ overflow: 'auto', whiteSpace: 'pre-wrap', wordBreak: 'break-word' }}>
          {JSON.stringify(value, null, 2)}
        </Code>
      )}
    </Stack>
  );
}

export function ReviewProblem({ message }: { message: string | null }) {
  if (!message) return null;
  return (
    <Alert color="red" variant="light" role="alert">
      {message}
    </Alert>
  );
}
