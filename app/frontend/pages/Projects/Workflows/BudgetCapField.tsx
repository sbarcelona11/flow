import { NumberInput } from '@mantine/core';
import { useState } from 'react';

import { capCentsFromInput } from 'shared/lib/budgetCap';

interface BudgetCapFieldProps {
  id: string;
  label: string;
  help: string;
  /** The draft's cap in cents; `null` for none. */
  cents: number | null;
  readOnly: boolean;
  onChange: (cents: number | null) => void;
}

/**
 * Dollars in, integer cents out. An amount that is not usable (partial, zero, out of range) leaves the
 * draft alone, and blur puts the draft's last good value back rather than clamping to a one-cent cap.
 */
export function BudgetCapField({ id, label, help, cents, readOnly, onChange }: BudgetCapFieldProps) {
  const [text, setText] = useState<string | number>(cents == null ? '' : cents / 100);

  return (
    <NumberInput
      id={id}
      label={label}
      description={help}
      value={text}
      min={0.01}
      max={10000}
      decimalScale={2}
      allowNegative={false}
      clampBehavior="none"
      prefix="$"
      disabled={readOnly}
      onBlur={() => {
        if (capCentsFromInput(text) === undefined) setText(cents == null ? '' : cents / 100);
      }}
      onChange={(value) => {
        setText(value);
        const next = capCentsFromInput(value);
        if (next !== undefined) onChange(next);
      }}
    />
  );
}
