import { router } from '@inertiajs/react';
import { Tabs } from '@mantine/core';

import { companyProjectApiConnectorsPath, companyProjectMCPServersPath } from 'shared/routes';

interface ConnectorsTabsProps {
  projectId: number;
  active: 'mcp' | 'rest';
}

export function ConnectorsTabs({ projectId, active }: ConnectorsTabsProps) {
  return (
    <Tabs
      value={active}
      mb="md"
      onChange={(value) =>
        router.visit(
          value === 'rest' ? companyProjectApiConnectorsPath(projectId) : companyProjectMCPServersPath(projectId),
        )
      }
    >
      <Tabs.List>
        <Tabs.Tab value="mcp">MCP servers</Tabs.Tab>
        <Tabs.Tab value="rest">REST APIs</Tabs.Tab>
      </Tabs.List>
    </Tabs>
  );
}
