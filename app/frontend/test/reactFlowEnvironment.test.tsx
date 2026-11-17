import '@xyflow/react/dist/style.css';

import { render, screen } from '@testing-library/react';
import { ReactFlow } from '@xyflow/react';
import { describe, expect, it } from 'vitest';

describe('React Flow in jsdom', () => {
  it('renders nodes by their accessible names', () => {
    render(
      <div style={{ width: 800, height: 600 }}>
        <ReactFlow
          nodes={[
            {
              id: 'a',
              position: { x: 0, y: 0 },
              data: { label: 'First' },
              width: 240,
              height: 96,
              ariaLabel: 'Node First',
            },
            {
              id: 'b',
              position: { x: 300, y: 0 },
              data: { label: 'Second' },
              width: 240,
              height: 96,
              ariaLabel: 'Node Second',
            },
          ]}
          edges={[{ id: 'a-b', source: 'a', target: 'b' }]}
        />
      </div>,
    );

    expect(screen.getByRole('group', { name: 'Node First' })).toBeInTheDocument();
    expect(screen.getByRole('group', { name: 'Node Second' })).toBeInTheDocument();
  });
});
