import { Head, Link, router, usePage } from '@inertiajs/react';
import { ActionIcon, Box, Button, Group, Table, Text, Tooltip } from '@mantine/core';
import { IconApi, IconArchive, IconEdit, IconPlus, IconRestore } from '@tabler/icons-react';
import { useState } from 'react';

import type { ApiConnector, Project } from '@/types/generated';

import { ArchiveSwitch, type ArchiveView } from 'shared/components/versions/ArchiveSwitch';
import { useProjectPermissions } from 'shared/lib/hooks/useProjectPermissions';
import { ConnectorsTabs } from 'shared/resources/connectors/ConnectorsTabs';
import {
  archiveCompanyProjectApiConnectorPath,
  editCompanyProjectApiConnectorPath,
  newCompanyProjectApiConnectorPath,
  unarchiveCompanyProjectApiConnectorPath,
} from 'shared/routes';
import { EmptyState } from 'shared/ui/EmptyState';
import { PageHeader } from 'shared/ui/PageHeader';
import { ResourceTableShell, ResourceTh } from 'shared/ui/ResourceTable';
import { StatusBadge } from 'shared/ui/StatusBadge';

import { persistentProjectLayout, setPageLayout } from '../ProjectLayout';

import { AUTH_LABELS } from './apiConnectorLabels';

type Props = {
  project: Project;
  apiConnectors: ApiConnector[];
  archivedConnectors: ApiConnector[];
  [key: string]: unknown;
};

const ApiConnectorsPage = () => {
  const { project, apiConnectors, archivedConnectors } = usePage<Props>().props;
  const { canExecute } = useProjectPermissions();
  const [view, setView] = useState<ArchiveView>('active');
  const shown = view === 'active' ? apiConnectors : archivedConnectors;

  return (
    <>
      <Head title={`Connectors — ${project.name}`} />
      <Box>
        <ConnectorsTabs projectId={project.id} active="rest" />
        <PageHeader
          title="Connectors"
          subtitle="REST APIs this project's workflow actions can call."
          actions={
            canExecute && (
              <Button
                component={Link}
                href={newCompanyProjectApiConnectorPath(project.id)}
                leftSection={<IconPlus size={16} />}
              >
                Add REST API
              </Button>
            )
          }
        />
        <Group gap="md" mb="lg">
          <ArchiveSwitch
            value={view}
            onChange={setView}
            activeCount={apiConnectors.length}
            archivedCount={archivedConnectors.length}
          />
        </Group>

        {shown.length === 0 ? (
          <Box
            style={{
              border: '1px solid var(--app-border-default)',
              borderRadius: 'var(--mantine-radius-md)',
              backgroundColor: 'var(--app-bg-paper)',
            }}
          >
            <EmptyState
              icon={<IconApi size={22} />}
              title={view === 'active' ? 'No REST APIs configured' : 'No archived REST APIs'}
              description={
                view === 'active'
                  ? 'A REST API connector lets a workflow action call an HTTP endpoint with a Config Item as its credential.'
                  : undefined
              }
            />
          </Box>
        ) : (
          <ResourceTableShell>
            <Table highlightOnHover layout="fixed">
              <Table.Thead style={{ backgroundColor: 'var(--app-bg-deep)' }}>
                <Table.Tr>
                  <ResourceTh>Name</ResourceTh>
                  <ResourceTh w={200}>Authentication</ResourceTh>
                  <ResourceTh w={110}>Operations</ResourceTh>
                  <ResourceTh w={110}>Status</ResourceTh>
                  <ResourceTh align="right" w={100}>
                    Actions
                  </ResourceTh>
                </Table.Tr>
              </Table.Thead>
              <Table.Tbody>
                {shown.map((connector) => (
                  <Table.Tr key={connector.id}>
                    <Table.Td>
                      <Text fz={14} fw={500} c="var(--app-text-primary)" truncate>
                        {connector.name}
                      </Text>
                      <Text fz={12} c="var(--app-text-tertiary)" truncate>
                        {connector.baseUrl}
                      </Text>
                    </Table.Td>
                    <Table.Td>
                      <Text fz={13}>{AUTH_LABELS[connector.authType]}</Text>
                    </Table.Td>
                    <Table.Td>
                      <Text fz={13}>{connector.operationsCount}</Text>
                    </Table.Td>
                    <Table.Td>
                      <StatusBadge state={connector.enabled ? 'enabled' : 'disabled'} size="sm" />
                    </Table.Td>
                    <Table.Td>
                      <Group gap={4} justify="flex-end">
                        {view === 'active' && canExecute && (
                          <>
                            <Tooltip label="Edit">
                              <ActionIcon
                                component={Link}
                                href={editCompanyProjectApiConnectorPath(project.id, connector.id)}
                                aria-label={`Edit ${connector.name}`}
                                variant="subtle"
                                size="sm"
                              >
                                <IconEdit size={16} />
                              </ActionIcon>
                            </Tooltip>
                            <Tooltip label="Archive">
                              <ActionIcon
                                aria-label={`Archive ${connector.name}`}
                                variant="subtle"
                                size="sm"
                                color="red"
                                onClick={() =>
                                  router.post(archiveCompanyProjectApiConnectorPath(project.id, connector.id))
                                }
                              >
                                <IconArchive size={16} />
                              </ActionIcon>
                            </Tooltip>
                          </>
                        )}
                        {view === 'archived' && canExecute && (
                          <Button
                            size="compact-xs"
                            variant="light"
                            aria-label={`Restore ${connector.name}`}
                            leftSection={<IconRestore size={14} />}
                            onClick={() =>
                              router.post(unarchiveCompanyProjectApiConnectorPath(project.id, connector.id))
                            }
                          >
                            Restore
                          </Button>
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
    </>
  );
};

setPageLayout(ApiConnectorsPage, persistentProjectLayout);

export default ApiConnectorsPage;
