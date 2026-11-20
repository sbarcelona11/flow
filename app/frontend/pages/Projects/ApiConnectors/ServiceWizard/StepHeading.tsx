import { Title } from '@mantine/core';
import type { Ref } from 'react';

/** Every step opens on its own heading, which receives focus when the person arrives. */
export function StepHeading({ title, headingRef }: { title: string; headingRef: Ref<HTMLHeadingElement> }) {
  return (
    <Title order={2} fz={18} tabIndex={-1} ref={headingRef} style={{ outline: 'none' }}>
      {title}
    </Title>
  );
}
