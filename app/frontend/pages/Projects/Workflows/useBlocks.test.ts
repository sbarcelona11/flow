import { describe, expect, it, vi } from 'vitest';

import { buildBlock } from 'test/factories/moduleBlock';
import { jsonResponse, unansweredFetch } from 'test/fetchStub';
import { act, renderHook, waitFor } from 'test/renderPage';

import { useBlocks } from './useBlocks';

describe('Projects/Workflows/useBlocks', () => {
  it('keeps the blocks it had when a reload fails', async () => {
    const answers = [() => jsonResponse([buildBlock()]), () => jsonResponse({ error: 'down' }, 500)];
    vi.spyOn(globalThis, 'fetch').mockImplementation(async (input, init) => {
      const answer = answers.shift();
      return answer ? answer() : unansweredFetch(input, init);
    });
    const { result } = renderHook(() => useBlocks(7, true));
    await waitFor(() => expect(result.current.status).toBe('ready'));

    act(() => result.current.reload?.());

    await waitFor(() => expect(result.current.status).toBe('error'));
    expect(result.current.blocks).toHaveLength(1);
  });
});
