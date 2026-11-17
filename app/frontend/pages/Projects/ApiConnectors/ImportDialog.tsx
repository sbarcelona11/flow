import { router } from '@inertiajs/react';
import { Alert, Button, Checkbox, Group, Modal, Stack, Tabs, Text, Textarea, TextInput } from '@mantine/core';
import { useState } from 'react';

import { apiFetch, apiRequest } from 'shared/lib/apiFetch';
import {
  companyProjectApiConnectorApiConnectorImportsPath,
  previewCompanyProjectApiConnectorImportsPath,
} from 'shared/routes';

interface Draft {
  name: string;
  method: string;
  path: string;
  summary: string | null;
  description: string | null;
  effect: string;
  input_schema: Record<string, unknown>;
}

interface Preview {
  base_url: string | null;
  drafts: Draft[];
  warnings: string[];
}

type Source = 'openapi' | 'curl';

interface ImportDialogProps {
  opened: boolean;
  onClose: () => void;
  projectId: number;
  connectorId: number | null;
  onUseBaseUrl?: (url: string) => void;
}

const JSON_HEADERS = { 'Content-Type': 'application/json' };

export function ImportDialog({ opened, onClose, projectId, connectorId, onUseBaseUrl }: ImportDialogProps) {
  const [source, setSource] = useState<Source>('openapi');
  const [url, setUrl] = useState('');
  const [text, setText] = useState('');
  const [curl, setCurl] = useState('');
  const [preview, setPreview] = useState<Preview | null>(null);
  const [selected, setSelected] = useState<boolean[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [rowErrors, setRowErrors] = useState<Record<number, string[]>>({});
  const [busy, setBusy] = useState(false);

  const reset = () => {
    setUrl('');
    setText('');
    setCurl('');
    setPreview(null);
    setSelected([]);
    setError(null);
    setRowErrors({});
  };

  const close = () => {
    reset();
    onClose();
  };

  const canPreview = source === 'curl' ? curl.trim() !== '' : url.trim() !== '' || text.trim() !== '';

  const runPreview = async () => {
    const body =
      source === 'curl'
        ? { source: 'curl', value: curl }
        : text.trim() !== ''
          ? { source: 'openapi_text', value: text }
          : { source: 'openapi_url', value: url.trim() };
    setBusy(true);
    setError(null);
    setRowErrors({});
    try {
      const result = await apiRequest<Preview>(previewCompanyProjectApiConnectorImportsPath(projectId), {
        method: 'POST',
        headers: JSON_HEADERS,
        body: JSON.stringify(body),
      });
      setPreview(result);
      setSelected(result.drafts.map(() => true));
      if (source === 'curl') setCurl('');
    } catch (failure) {
      setPreview(null);
      setError(failure instanceof Error ? failure.message : 'The import could not be read.');
    } finally {
      setBusy(false);
    }
  };

  const chosen = preview ? preview.drafts.filter((_, index) => selected[index]) : [];

  const runImport = async () => {
    if (connectorId === null || !preview) return;
    const indexes = preview.drafts.flatMap((_, index) => (selected[index] ? [index] : []));
    setBusy(true);
    setError(null);
    setRowErrors({});
    try {
      const res = await apiFetch(companyProjectApiConnectorApiConnectorImportsPath(projectId, connectorId), {
        method: 'POST',
        headers: JSON_HEADERS,
        redirect: 'manual',
        body: JSON.stringify({ drafts: chosen }),
      });
      if (res.status === 422) {
        const body = (await res.json()) as { error?: string; errors?: Record<string, string[]> };
        const mapped: Record<number, string[]> = {};
        Object.entries(body.errors ?? {}).forEach(([position, messages]) => {
          mapped[indexes[Number(position)]] = messages;
        });
        setRowErrors(mapped);
        setError(body.error ?? null);
        return;
      }
      if (!res.ok && res.type !== 'opaqueredirect') {
        setError('The operations could not be imported.');
        return;
      }
      close();
      router.reload();
    } catch {
      setError('The operations could not be imported.');
    } finally {
      setBusy(false);
    }
  };

  return (
    <Modal opened={opened} onClose={close} title="Import operations" size="lg">
      <Stack gap="md">
        <Tabs value={source} onChange={(value) => value && setSource(value as Source)}>
          <Tabs.List>
            <Tabs.Tab value="openapi">OpenAPI</Tabs.Tab>
            <Tabs.Tab value="curl">cURL</Tabs.Tab>
          </Tabs.List>
          <Tabs.Panel value="openapi" pt="md">
            <Stack gap="sm">
              <TextInput
                label="OpenAPI URL"
                placeholder="https://api.example.com/openapi.json"
                value={url}
                onChange={(e) => setUrl(e.currentTarget.value)}
              />
              <Textarea
                label="Or paste the document"
                description="JSON or YAML. Used instead of the URL when filled in."
                autosize
                minRows={3}
                maxRows={8}
                value={text}
                onChange={(e) => setText(e.currentTarget.value)}
              />
            </Stack>
          </Tabs.Panel>
          <Tabs.Panel value="curl" pt="md">
            <Textarea
              label="cURL command"
              description="Credentials in the command are never imported or kept."
              autosize
              minRows={3}
              maxRows={8}
              value={curl}
              onChange={(e) => setCurl(e.currentTarget.value)}
            />
          </Tabs.Panel>
        </Tabs>

        <Group>
          <Button variant="light" onClick={runPreview} loading={busy && !preview} disabled={!canPreview}>
            Preview
          </Button>
        </Group>

        {error && (
          <Alert color="red" variant="light">
            {error}
          </Alert>
        )}

        {preview && (
          <Stack gap="sm">
            {preview.warnings.length > 0 && (
              <Alert color="yellow" variant="light" title="Review before importing">
                <Stack gap={2}>
                  {preview.warnings.map((warning) => (
                    <Text key={warning} fz={13}>
                      {warning}
                    </Text>
                  ))}
                </Stack>
              </Alert>
            )}
            {preview.base_url && onUseBaseUrl && (
              <Group>
                <Button
                  size="compact-sm"
                  variant="light"
                  onClick={() => {
                    onUseBaseUrl(preview.base_url ?? '');
                    close();
                  }}
                >
                  {`Use ${preview.base_url}`}
                </Button>
              </Group>
            )}
            {preview.drafts.length === 0 ? (
              <Text fz={13} c="dimmed">
                No operations were found.
              </Text>
            ) : (
              <Stack gap="xs">
                {preview.drafts.map((draft, index) => (
                  <div key={`${draft.name}-${index}`}>
                    <Checkbox
                      label={`${draft.method} ${draft.path} — ${draft.name}`}
                      checked={selected[index] ?? false}
                      onChange={(e) => {
                        const checked = e.currentTarget.checked;
                        setSelected((current) => current.map((value, i) => (i === index ? checked : value)));
                      }}
                    />
                    {(rowErrors[index] ?? []).map((message) => (
                      <Text key={message} fz={12} c="red" ml={28}>
                        {message}
                      </Text>
                    ))}
                  </div>
                ))}
              </Stack>
            )}
            {connectorId === null && preview.drafts.length > 0 && (
              <Text fz={12} c="dimmed">
                Save the connector first to import these operations.
              </Text>
            )}
            {connectorId !== null && preview.drafts.length > 0 && (
              <Group justify="flex-end">
                <Button onClick={runImport} loading={busy} disabled={chosen.length === 0}>
                  {`Import selected (${chosen.length})`}
                </Button>
              </Group>
            )}
          </Stack>
        )}
      </Stack>
    </Modal>
  );
}
