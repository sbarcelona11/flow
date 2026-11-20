import { Head, Link, router, usePage } from '@inertiajs/react';
import { ActionIcon, Box, Button, Group, Modal, Table, Text, Tooltip } from '@mantine/core';
import {
  IconArrowLeft,
  IconEdit,
  IconFileImport,
  IconPlayerPlay,
  IconPlus,
  IconTrash,
  IconWand,
} from '@tabler/icons-react';
import { useState } from 'react';

import type { ApiConnector, ApiOperation, Project } from '@/types/generated';

import { useProjectPermissions } from 'shared/lib/hooks/useProjectPermissions';
import { companyProjectApiConnectorApiOperationPath, companyProjectApiConnectorsPath } from 'shared/routes';
import { PageHeader } from 'shared/ui/PageHeader';
import { ResourceTableShell, ResourceTh } from 'shared/ui/ResourceTable';
import { StatusBadge, type StatusTone } from 'shared/ui/StatusBadge';

import { persistentProjectLayout, setPageLayout } from '../ProjectLayout';

import { ConnectorForm } from './ConnectorForm';
import { ConnectorReviewDrawer } from './ConnectorReviewDrawer';
import { ImportDialog } from './ImportDialog';
import { OperationEditor } from './OperationEditor';
import { TryStep } from './ServiceWizard/TryStep';

type Props = {
  project: Project;
  apiConnector: ApiConnector | null;
  operations: ApiOperation[];
  configItemNames: string[];
  [key: string]: unknown;
};

const EFFECT_TONE: Record<string, StatusTone> = {
  read: 'success',
  write: 'warning',
  send: 'danger',
  irreversible: 'danger',
};

const isLive = (record: Pick<ApiConnector, 'enabled' | 'reviewState'>) =>
  record.enabled && record.reviewState === 'reviewed';

const isWaiting = (record: Pick<ApiOperation, 'reviewState'>) => record.reviewState === 'waiting';

/** The server refuses anything else, so only a read on an enabled, reviewed connector is offered. */
const canTry = (connector: ApiConnector, operation: ApiOperation) =>
  isLive(connector) && isLive(operation) && operation.effect === 'read';

const ApiConnectorPage = () => {
  const { project, apiConnector, operations, configItemNames } = usePage<Props>().props;
  const { canExecute } = useProjectPermissions();
  const [baseUrl, setBaseUrl] = useState(apiConnector?.baseUrl ?? '');
  const [editing, setEditing] = useState<ApiOperation | null>(null);
  const [editorOpen, setEditorOpen] = useState(false);
  const [importOpen, setImportOpen] = useState(false);
  const [trying, setTrying] = useState<ApiOperation | null>(null);
  const [reviewing, setReviewing] = useState(false);

  const openEditor = (operation: ApiOperation | null) => {
    setEditing(operation);
    setEditorOpen(true);
  };

  return (
    <>
      <Head title={`${apiConnector?.name ?? 'New REST API'} — ${project.name}`} />
      <Box>
        <PageHeader
          title={apiConnector?.name ?? 'New REST API'}
          subtitle="The host, credentials and operations a workflow action can call."
          actions={
            <>
              {apiConnector && (apiConnector.reviewState === 'waiting' || operations.some(isWaiting)) && (
                <Button variant="light" onClick={() => setReviewing(true)}>
                  {canExecute ? 'Review what is waiting' : 'See what is waiting'}
                </Button>
              )}
              <Button
                component={Link}
                href={companyProjectApiConnectorsPath(project.id)}
                variant="default"
                leftSection={<IconArrowLeft size={16} />}
              >
                Back to connectors
              </Button>
            </>
          }
        />

        <ConnectorForm
          key={apiConnector?.id ?? 'new'}
          projectId={project.id}
          connector={apiConnector}
          configItemNames={configItemNames}
          baseUrl={baseUrl}
          onBaseUrlChange={setBaseUrl}
          readOnly={!canExecute}
        />

        {!apiConnector && canExecute && (
          <Group mt="md">
            <Button variant="subtle" leftSection={<IconWand size={16} />} onClick={() => setImportOpen(true)}>
              Detect from OpenAPI or cURL
            </Button>
          </Group>
        )}

        {apiConnector && (
          <Box mt={40}>
            <PageHeader
              title="Operations"
              subtitle="Each operation is one call. Its effect decides whether an action step needs an approval."
              mb={12}
              actions={
                canExecute && (
                  <>
                    <Button
                      variant="default"
                      leftSection={<IconFileImport size={16} />}
                      onClick={() => setImportOpen(true)}
                    >
                      Import operations
                    </Button>
                    <Button leftSection={<IconPlus size={16} />} onClick={() => openEditor(null)}>
                      Add operation
                    </Button>
                  </>
                )
              }
            />
            {operations.length === 0 ? (
              <Text fz={13} c="dimmed">
                No operations yet. Add one, or import them from an OpenAPI document or a cURL command.
              </Text>
            ) : (
              <ResourceTableShell>
                <Table highlightOnHover layout="fixed">
                  <Table.Thead style={{ backgroundColor: 'var(--app-bg-deep)' }}>
                    <Table.Tr>
                      <ResourceTh w={90}>Method</ResourceTh>
                      <ResourceTh>Operation</ResourceTh>
                      <ResourceTh w={120}>Effect</ResourceTh>
                      <ResourceTh w={110}>Status</ResourceTh>
                      <ResourceTh align="right" w={100}>
                        Actions
                      </ResourceTh>
                    </Table.Tr>
                  </Table.Thead>
                  <Table.Tbody>
                    {operations.map((operation) => (
                      <Table.Tr key={operation.id}>
                        <Table.Td>
                          <StatusBadge tone="neutral" size="sm">
                            {operation.httpMethod}
                          </StatusBadge>
                        </Table.Td>
                        <Table.Td>
                          <Text fz={14} fw={500} truncate>
                            {operation.name}
                          </Text>
                          <Text fz={12} c="var(--app-text-tertiary)" truncate>
                            {operation.path}
                          </Text>
                        </Table.Td>
                        <Table.Td>
                          <StatusBadge tone={EFFECT_TONE[operation.effect] ?? 'neutral'} size="sm">
                            {operation.effect}
                          </StatusBadge>
                        </Table.Td>
                        <Table.Td>
                          {isWaiting(operation) ? (
                            <StatusBadge tone="info" size="sm">
                              Waiting for review
                            </StatusBadge>
                          ) : (
                            <StatusBadge state={operation.enabled ? 'enabled' : 'disabled'} size="sm" />
                          )}
                        </Table.Td>
                        <Table.Td>
                          <Group gap={4} justify="flex-end">
                            {canExecute && canTry(apiConnector, operation) && (
                              <Tooltip label="Try it">
                                <ActionIcon
                                  aria-label={`Try ${operation.name}`}
                                  variant="subtle"
                                  size="sm"
                                  onClick={() => setTrying(operation)}
                                >
                                  <IconPlayerPlay size={16} />
                                </ActionIcon>
                              </Tooltip>
                            )}
                            {canExecute && (
                              <>
                                <Tooltip label="Edit">
                                  <ActionIcon
                                    aria-label={`Edit ${operation.name}`}
                                    variant="subtle"
                                    size="sm"
                                    onClick={() => openEditor(operation)}
                                  >
                                    <IconEdit size={16} />
                                  </ActionIcon>
                                </Tooltip>
                                <Tooltip label="Delete">
                                  <ActionIcon
                                    aria-label={`Delete ${operation.name}`}
                                    variant="subtle"
                                    size="sm"
                                    color="red"
                                    onClick={() =>
                                      router.delete(
                                        companyProjectApiConnectorApiOperationPath(
                                          project.id,
                                          apiConnector.id,
                                          operation.id,
                                        ),
                                        { preserveScroll: true },
                                      )
                                    }
                                  >
                                    <IconTrash size={16} />
                                  </ActionIcon>
                                </Tooltip>
                              </>
                            )}
                          </Group>
                        </Table.Td>
                      </Table.Tr>
                    ))}
                  </Table.Tbody>
                </Table>
              </ResourceTableShell>
            )}
          </Box>
        )}

        {apiConnector && trying && (
          <Modal opened onClose={() => setTrying(null)} title={`Try ${trying.name}`} size="lg">
            <TryStep
              projectId={project.id}
              connectorId={apiConnector.id}
              operations={[{ id: trying.id, name: trying.name, inputSchema: trying.inputSchema }]}
            />
          </Modal>
        )}

        {apiConnector && (
          <ConnectorReviewDrawer
            projectId={project.id}
            connectorId={reviewing ? apiConnector.id : null}
            canAct={canExecute}
            onClose={() => setReviewing(false)}
            onChanged={() => router.reload({ only: ['apiConnector', 'operations'] })}
          />
        )}

        {apiConnector && (
          <OperationEditor
            opened={editorOpen}
            onClose={() => setEditorOpen(false)}
            projectId={project.id}
            connectorId={apiConnector.id}
            operation={editing}
          />
        )}
        <ImportDialog
          opened={importOpen}
          onClose={() => setImportOpen(false)}
          projectId={project.id}
          connectorId={apiConnector?.id ?? null}
          onUseBaseUrl={apiConnector ? undefined : setBaseUrl}
        />
      </Box>
    </>
  );
};

setPageLayout(ApiConnectorPage, persistentProjectLayout);

export default ApiConnectorPage;
