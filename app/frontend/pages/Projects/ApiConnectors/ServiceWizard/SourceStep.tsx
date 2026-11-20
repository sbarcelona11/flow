import { Button, Radio, Stack, Textarea, TextInput } from '@mantine/core';
import { type FormEvent, type Ref, useState } from 'react';

import { StepHeading } from './StepHeading';
import { hostOf, type ImportPreview, STEP_TITLES } from './wizardState';

type Kind = 'openapi_url' | 'openapi_text' | 'curl' | 'address';

const KINDS: { value: Kind; label: string }[] = [
  { value: 'openapi_url', label: 'A link to the spec' },
  { value: 'openapi_text', label: 'Paste the spec' },
  { value: 'curl', label: 'A cURL command' },
  { value: 'address', label: 'I only have the address' },
];

interface SourceStepProps {
  headingRef: Ref<HTMLHeadingElement>;
  readPreview: (source: Exclude<Kind, 'address'>, value: string) => Promise<ImportPreview>;
  onPreview: (preview: ImportPreview) => void;
  onAddress: (baseUrl: string) => void;
  onError: (message: string | null) => void;
}

export function SourceStep({ headingRef, readPreview, onPreview, onAddress, onError }: SourceStepProps) {
  const [kind, setKind] = useState<Kind>('openapi_url');
  const [value, setValue] = useState('');
  const [busy, setBusy] = useState(false);

  const submit = async (event: FormEvent) => {
    event.preventDefault();
    onError(null);
    if (kind === 'address') {
      if (hostOf(value) === null) {
        onError('Enter the address as an https URL, such as https://api.example.com.');
        return;
      }
      onAddress(value.trim());
      return;
    }
    setBusy(true);
    try {
      const preview = await readPreview(kind, value);
      // A pasted cURL command may carry a credential; only the server-side import sees it.
      setValue('');
      onPreview(preview);
    } catch (failure) {
      onError(failure instanceof Error ? failure.message : 'The source could not be read.');
    } finally {
      setBusy(false);
    }
  };

  return (
    <form onSubmit={submit}>
      <Stack gap="md">
        <StepHeading title={STEP_TITLES.source} headingRef={headingRef} />
        <Radio.Group
          label="How do you want to start?"
          value={kind}
          onChange={(next) => {
            setKind(next as Kind);
            setValue('');
            onError(null);
          }}
        >
          <Stack gap={6} mt={6}>
            {KINDS.map((option) => (
              <Radio key={option.value} value={option.value} label={option.label} />
            ))}
          </Stack>
        </Radio.Group>

        {kind === 'openapi_url' && (
          <TextInput
            label="Link to the spec"
            placeholder="https://api.example.com/openapi.json"
            value={value}
            onChange={(e) => setValue(e.currentTarget.value)}
            data-autofocus
          />
        )}
        {kind === 'openapi_text' && (
          <Textarea
            label="The spec"
            description="JSON or YAML."
            autosize
            minRows={4}
            maxRows={10}
            value={value}
            onChange={(e) => setValue(e.currentTarget.value)}
          />
        )}
        {kind === 'curl' && (
          <Textarea
            label="The cURL command"
            description="Credentials in the command are never imported or kept."
            autosize
            minRows={3}
            maxRows={8}
            value={value}
            onChange={(e) => setValue(e.currentTarget.value)}
          />
        )}
        {kind === 'address' && (
          <TextInput
            label="Address"
            description="You can add the operations later."
            placeholder="https://api.example.com"
            value={value}
            onChange={(e) => setValue(e.currentTarget.value)}
          />
        )}

        <div>
          <Button type="submit" loading={busy} disabled={value.trim() === ''}>
            {kind === 'address' ? 'Use this address' : 'Read the spec'}
          </Button>
        </div>
      </Stack>
    </form>
  );
}
