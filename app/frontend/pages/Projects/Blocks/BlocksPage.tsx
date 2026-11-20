import { Head, router, usePage } from '@inertiajs/react';
import { Box, Button, Group, Stack, Table, Text } from '@mantine/core';
import { modals } from '@mantine/modals';
import { notifications } from '@mantine/notifications';
import { IconBox, IconPlus } from '@tabler/icons-react';
import { useState } from 'react';

import type { ModuleDefinition, Project } from '@/types/generated';

import { ApiError, apiRequest } from 'shared/lib/apiFetch';
import { useProjectPermissions } from 'shared/lib/hooks/useProjectPermissions';
import { ConnectorsTabs } from 'shared/resources/connectors/ConnectorsTabs';
import { plainLine, proposedBy } from 'shared/resources/connectors/reviewText';
import {
  archiveCompanyProjectModuleDefinitionPath,
  disableCompanyProjectModuleDefinitionPath,
  enableCompanyProjectModuleDefinitionPath,
} from 'shared/routes';
import { EmptyState } from 'shared/ui/EmptyState';
import { PageHeader } from 'shared/ui/PageHeader';
import { ResourceTableShell, ResourceTh } from 'shared/ui/ResourceTable';
import { StatusBadge, type StatusTone } from 'shared/ui/StatusBadge';

import { persistentProjectLayout, setPageLayout } from '../ProjectLayout';

import { BlockReviewDrawer } from './BlockReviewDrawer';
import { type BlockSourceOperation, NewBlockDialog } from './NewBlockDialog';

type Props = {
  project: Project;
  definitions: ModuleDefinition[];
  operations: BlockSourceOperation[];
  truncated: boolean;
  [key: string]: unknown;
};

type Group = 'waiting' | 'enabled' | 'disabled' | 'invalid' | 'archived';

const GROUPS: { key: Group; title: string }[] = [
  { key: 'waiting', title: 'Waiting for review' },
  { key: 'enabled', title: 'Enabled' },
  { key: 'disabled', title: 'Disabled' },
  { key: 'invalid', title: 'Invalid' },
  { key: 'archived', title: 'Archived' },
];

const BADGES: Record<Group, { tone: StatusTone; label: string }> = {
  waiting: { tone: 'info', label: 'Waiting' },
  enabled: { tone: 'success', label: 'Enabled' },
  disabled: { tone: 'neutral', label: 'Disabled' },
  invalid: { tone: 'danger', label: 'Invalid' },
  archived: { tone: 'neutral', label: 'Archived' },
};

const groupOf = (definition: ModuleDefinition): Group => {
  if (definition.archivedAt) return 'archived';
  if (definition.reviewState === 'waiting') return 'waiting';
  if (definition.status === 'invalid') return 'invalid';
  return definition.enabled ? 'enabled' : 'disabled';
};

const refresh = () => router.reload({ only: ['definitions', 'truncated'] });

const BlocksPage = () => {
  const { project, definitions, operations, truncated } = usePage<Props>().props;
  const { canExecute } = useProjectPermissions();
  const [reviewing, setReviewing] = useState<number | null>(null);
  const [creating, setCreating] = useState(false);
  const [versioning, setVersioning] = useState<ModuleDefinition | null>(null);

  const blocks = definitions.filter((definition) => definition.kind === 'block');

  const act = async (path: string, failure: string) => {
    try {
      await apiRequest(path, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}' });
      refresh();
    } catch (error) {
      notifications.show({ color: 'red', message: error instanceof ApiError ? error.message : failure });
    }
  };

  const archive = (definition: ModuleDefinition) =>
    modals.openConfirmModal({
      title: 'Archive block',
      children: (
        <Text size="sm">
          Archive <b>{definition.label}</b>? Steps already using it keep working on this version only until it is
          archived; they will show it as unavailable.
        </Text>
      ),
      labels: { confirm: 'Archive', cancel: 'Cancel' },
      confirmProps: { color: 'red' },
      onConfirm: () =>
        act(archiveCompanyProjectModuleDefinitionPath(project.id, definition.id), 'The block was not archived.'),
    });

  return (
    <>
      <Head title={`Blocks — ${project.name}`} />
      <Box>
        <ConnectorsTabs projectId={project.id} active="blocks" />
        <PageHeader
          title="Blocks"
          subtitle="Ready-made steps built from an operation. Anything proposed by Aixle Builder or a token waits here until you approve it."
          actions={
            canExecute && (
              <Button leftSection={<IconPlus size={16} />} onClick={() => setCreating(true)}>
                New block
              </Button>
            )
          }
        />

        {truncated && (
          <Text fz={12} c="dimmed" mb="sm">
            Only the first blocks are listed.
          </Text>
        )}

        {blocks.length === 0 ? (
          <Box
            style={{
              border: '1px solid var(--app-border-default)',
              borderRadius: 'var(--mantine-radius-md)',
              backgroundColor: 'var(--app-bg-paper)',
            }}
          >
            <EmptyState
              icon={<IconBox size={22} />}
              title="No blocks yet"
              description="A block wraps one REST operation with a name, settings and an effect, so a workflow step can use it in a click."
            />
          </Box>
        ) : (
          <Stack gap="xl">
            {GROUPS.map(({ key, title }) => {
              const rows = blocks.filter((definition) => groupOf(definition) === key);
              if (rows.length === 0) return null;
              return (
                <Box key={key} component="section" aria-label={title}>
                  <Text fz={13} fw={600} mb={6}>{`${title} (${rows.length})`}</Text>
                  <ResourceTableShell>
                    <Table highlightOnHover layout="fixed">
                      <Table.Thead style={{ backgroundColor: 'var(--app-bg-deep)' }}>
                        <Table.Tr>
                          <ResourceTh>Block</ResourceTh>
                          <ResourceTh w={110}>Status</ResourceTh>
                          <ResourceTh align="right" w={330}>
                            Actions
                          </ResourceTh>
                        </Table.Tr>
                      </Table.Thead>
                      <Table.Tbody>
                        {rows.map((definition) => (
                          <Table.Tr key={definition.id}>
                            <Table.Td>
                              <Text fz={14} fw={500} truncate>
                                {plainLine(definition.label, 120)}
                              </Text>
                              <Text fz={12} c="var(--app-text-tertiary)" ff="monospace" truncate>
                                {plainLine(definition.key, 120)}
                              </Text>
                              <Text fz={12} c="var(--app-text-tertiary)" truncate>
                                {proposedBy(
                                  definition.origin,
                                  definition.originSessionId,
                                  definition.createdBy?.name ?? null,
                                )}
                              </Text>
                              {key === 'invalid' && definition.reason && (
                                <Text fz={12} c="red">
                                  {plainLine(definition.reason, 300)}
                                </Text>
                              )}
                            </Table.Td>
                            <Table.Td>
                              <StatusBadge tone={BADGES[key].tone}>{BADGES[key].label}</StatusBadge>
                            </Table.Td>
                            <Table.Td>
                              <Group gap={6} justify="flex-end">
                                <Button
                                  size="compact-xs"
                                  variant="light"
                                  aria-label={`${canExecute && key === 'waiting' ? 'Review' : 'Details of'} ${definition.label}`}
                                  onClick={() => setReviewing(definition.id)}
                                >
                                  {canExecute && key === 'waiting' ? 'Review' : 'Details'}
                                </Button>
                                {canExecute && key !== 'archived' && key !== 'waiting' && (
                                  <>
                                    <Button
                                      size="compact-xs"
                                      variant="default"
                                      aria-label={`${definition.enabled ? 'Disable' : 'Enable'} ${definition.label}`}
                                      onClick={() =>
                                        act(
                                          definition.enabled
                                            ? disableCompanyProjectModuleDefinitionPath(project.id, definition.id)
                                            : enableCompanyProjectModuleDefinitionPath(project.id, definition.id),
                                          'The block was not changed.',
                                        )
                                      }
                                    >
                                      {definition.enabled ? 'Disable' : 'Enable'}
                                    </Button>
                                    <Button
                                      size="compact-xs"
                                      variant="default"
                                      aria-label={`New version of ${definition.label}`}
                                      onClick={() => setVersioning(definition)}
                                    >
                                      New version
                                    </Button>
                                  </>
                                )}
                                {canExecute && key !== 'archived' && (
                                  <Button
                                    size="compact-xs"
                                    variant="subtle"
                                    color="red"
                                    aria-label={`Archive ${definition.label}`}
                                    onClick={() => archive(definition)}
                                  >
                                    Archive
                                  </Button>
                                )}
                              </Group>
                            </Table.Td>
                          </Table.Tr>
                        ))}
                      </Table.Tbody>
                    </Table>
                  </ResourceTableShell>
                </Box>
              );
            })}
          </Stack>
        )}
      </Box>

      <BlockReviewDrawer
        projectId={project.id}
        definitionId={reviewing}
        canAct={canExecute}
        onClose={() => setReviewing(null)}
        onChanged={refresh}
      />
      {(creating || versioning) && (
        <NewBlockDialog
          opened
          projectId={project.id}
          operations={operations}
          previous={versioning ? { id: versioning.id, label: versioning.label, key: versioning.key } : null}
          onClose={() => {
            setCreating(false);
            setVersioning(null);
          }}
          onCreated={refresh}
        />
      )}
    </>
  );
};

setPageLayout(BlocksPage, persistentProjectLayout);

export default BlocksPage;
