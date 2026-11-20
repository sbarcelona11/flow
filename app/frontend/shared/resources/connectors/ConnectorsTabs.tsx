import { router } from '@inertiajs/react';
import { Tabs } from '@mantine/core';

import {
  companyProjectApiConnectorsPath,
  companyProjectMCPServersPath,
  companyProjectModuleDefinitionsPath,
} from 'shared/routes';

type ConnectorsTab = 'mcp' | 'rest' | 'blocks';

interface ConnectorsTabsProps {
  projectId: number;
  active: ConnectorsTab;
}

const PATHS: Record<ConnectorsTab, (projectId: number) => string> = {
  mcp: companyProjectMCPServersPath,
  rest: companyProjectApiConnectorsPath,
  blocks: companyProjectModuleDefinitionsPath,
};

export function ConnectorsTabs({ projectId, active }: ConnectorsTabsProps) {
  return (
    <Tabs
      value={active}
      mb="md"
      onChange={(value) => {
        if (value && value in PATHS) router.visit(PATHS[value as ConnectorsTab](projectId));
      }}
    >
      <Tabs.List>
        <Tabs.Tab value="mcp">MCP servers</Tabs.Tab>
        <Tabs.Tab value="rest">REST APIs</Tabs.Tab>
        <Tabs.Tab value="blocks">Blocks</Tabs.Tab>
      </Tabs.List>
    </Tabs>
  );
}
