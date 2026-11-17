import { useCallback, useState } from 'react';

/** The text of one polite live region; a repeated message gains a trailing space so the region's text still changes. */
export function useCanvasAnnouncer() {
  const [message, setMessage] = useState('');
  const announce = useCallback((next: string) => {
    setMessage((current) => (current === next ? `${next} ` : next));
  }, []);
  return { message, announce };
}
