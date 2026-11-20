import { router } from '@inertiajs/react';
import { Alert, Button, Group, Modal, PasswordInput, Select, Stack, Textarea, TextInput } from '@mantine/core';
import { useForm } from '@mantine/form';
import { zod4Resolver as zodResolver } from 'mantine-form-zod-resolver';
import { useEffect, useState, type FC } from 'react';
import { z } from 'zod';

import type { ConfigItem } from '@/types/generated';

import { useUnsavedChanges } from 'shared/lib/unsaved-changes/useUnsavedChanges';

const createSchema = z.object({
  name: z.string().min(1, 'Name is required'),
  value: z.string().min(1, 'Value is required'),
  description: z.string().optional(),
  itemType: z.string().min(1, 'Type is required'),
});

const editSchema = z.object({
  name: z.string().min(1, 'Name is required'),
  value: z.string().optional(),
  description: z.string().optional(),
  itemType: z.string().min(1, 'Type is required'),
});

type FormData = z.infer<typeof createSchema>;
export type ConfigItemFormValues = FormData;

const EMPTY_VALUES: FormData = { name: '', value: '', description: '', itemType: 'variable' };

interface Props {
  opened: boolean;
  onClose: () => void;
  item?: Pick<ConfigItem, 'id' | 'name' | 'value' | 'description' | 'itemType'> | null;
  basePath: string;
  /** Starts a new item as this type. */
  defaultType?: 'secret' | 'variable';
  /** The type is `defaultType` and cannot be changed, for a caller that needs one kind of item. */
  lockType?: boolean;
  /**
   * Saves a new item instead of the Inertia post, so the caller keeps its own page. Resolves false to stay open, or
   * `{ error }` to stay open and show why.
   */
  onCreate?: (values: FormData) => Promise<boolean | { error: string }>;
}

const TYPE_OPTIONS = [
  { value: 'variable', label: 'Variable' },
  { value: 'secret', label: 'Secret' },
];

export const ConfigItemFormModal: FC<Props> = ({
  opened,
  onClose,
  item,
  basePath,
  defaultType,
  lockType = false,
  onCreate,
}) => {
  const [loading, setLoading] = useState(false);
  const [problem, setProblem] = useState<string | null>(null);
  const isEditing = !!item;

  const form = useForm<FormData>({
    validate: zodResolver(isEditing ? editSchema : createSchema),
    initialValues: EMPTY_VALUES,
  });

  useEffect(() => {
    if (opened) {
      setProblem(null);
      form.setInitialValues(
        item
          ? {
              name: item.name,
              // A variable's value is shown and editable in place; a secret's never
              // reaches the browser, so its field starts empty and empty keeps it.
              value: item.itemType === 'secret' ? '' : item.value,
              description: item.description ?? '',
              itemType: item.itemType,
            }
          : { ...EMPTY_VALUES, itemType: defaultType ?? EMPTY_VALUES.itemType },
      );
      form.reset();
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [opened, item]);

  const handleSubmit = (values: FormData) => {
    if (!isEditing && onCreate) {
      setLoading(true);
      setProblem(null);
      void onCreate(values)
        .then((saved) => {
          if (saved === true) onClose();
          else if (saved !== false) setProblem(saved.error);
        })
        .finally(() => setLoading(false));
      return;
    }

    setLoading(true);

    const opts = {
      preserveScroll: true,
      onFinish: () => setLoading(false),
      onSuccess: () => onClose(),
    };

    if (isEditing) {
      router.patch(`${basePath}/${item!.id}`, { configItem: values }, opts);
    } else {
      router.post(basePath, { configItem: values }, opts);
    }
  };

  const requestClose = useUnsavedChanges({ opened, dirty: form.isDirty(), saving: loading, onClose });

  return (
    <Modal opened={opened} onClose={requestClose} title={isEditing ? 'Edit secret' : 'Add secret'} centered>
      <form onSubmit={form.onSubmit(handleSubmit)}>
        <Stack gap="md">
          {problem && (
            <Alert color="red" role="alert">
              {problem}
            </Alert>
          )}
          <TextInput
            label="Name"
            placeholder="API_KEY"
            description="Uppercase with underscores (e.g., API_KEY)"
            {...form.getInputProps('name')}
            onChange={(e) =>
              form.setFieldValue('name', e.currentTarget.value.toUpperCase().replace(/[^A-Z0-9_]/g, '_'))
            }
            disabled={isEditing}
            required
            ff="monospace"
          />
          <Select
            label="Type"
            data={TYPE_OPTIONS}
            {...form.getInputProps('itemType')}
            disabled={isEditing || lockType}
          />
          {form.values.itemType === 'secret' ? (
            <PasswordInput
              label={isEditing ? 'New Value (leave empty to keep current)' : 'Value'}
              placeholder="Enter secret value..."
              {...form.getInputProps('value')}
              required={!isEditing}
            />
          ) : (
            <TextInput
              label={isEditing ? 'Value (leave empty to keep current)' : 'Value'}
              placeholder="Enter value..."
              {...form.getInputProps('value')}
              required={!isEditing}
            />
          )}
          <Textarea label="Description" placeholder="Optional description..." {...form.getInputProps('description')} />
          <Group justify="flex-end" mt="sm">
            <Button variant="default" onClick={requestClose} disabled={loading}>
              Cancel
            </Button>
            <Button type="submit" loading={loading}>
              {isEditing ? 'Update' : 'Create'}
            </Button>
          </Group>
        </Stack>
      </form>
    </Modal>
  );
};
