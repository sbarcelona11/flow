// jsdom gaps React Flow needs to measure and place nodes. Environment polyfills only — React Flow
// itself is never mocked.

class DOMMatrixReadOnlyStub {
  m22: number;

  constructor(transform?: string) {
    const scale = transform?.match(/scale\(([\d.]+)\)/)?.[1];
    this.m22 = scale ? Number(scale) : 1;
  }
}
window.DOMMatrixReadOnly ??= DOMMatrixReadOnlyStub as unknown as typeof DOMMatrixReadOnly;

const NODE_WIDTH = 240;
const NODE_HEIGHT = 96;

function nodeSize(element: HTMLElement, fallback: number, size: number) {
  return element.classList.contains('react-flow__node') ? size : fallback;
}

Object.defineProperties(HTMLElement.prototype, {
  offsetWidth: {
    configurable: true,
    get(this: HTMLElement) {
      return nodeSize(this, 0, NODE_WIDTH);
    },
  },
  offsetHeight: {
    configurable: true,
    get(this: HTMLElement) {
      return nodeSize(this, 0, NODE_HEIGHT);
    },
  },
});

(SVGElement.prototype as unknown as { getBBox: () => DOMRect }).getBBox = () =>
  ({ x: 0, y: 0, width: 0, height: 0, top: 0, left: 0, right: 0, bottom: 0, toJSON: () => ({}) }) as DOMRect;

const PANE_WIDTH = 1200;
const PANE_HEIGHT = 600;

/**
 * Lets a test see React Flow as it runs in a browser: each observed element is reported once, after a
 * tick (React Flow only knows a node's handles, and so draws its edges, from that report; the stub in
 * setup.ts never reports), and the flow's own box is 1200x600 instead of 0x0 (so a viewport exists to
 * cull nodes against). Returns the function that restores the defaults.
 */
export function reportResizes(): () => void {
  const previous = window.ResizeObserver;
  window.ResizeObserver = class {
    constructor(private readonly callback: ResizeObserverCallback) {}

    observe(target: Element) {
      setTimeout(() => this.callback([{ target } as ResizeObserverEntry], this as unknown as ResizeObserver), 0);
    }

    unobserve() {}

    disconnect() {}
  } as unknown as typeof ResizeObserver;

  const width = Object.getOwnPropertyDescriptor(HTMLElement.prototype, 'offsetWidth');
  const height = Object.getOwnPropertyDescriptor(HTMLElement.prototype, 'offsetHeight');
  const boxed = (descriptor: PropertyDescriptor | undefined, size: number) => ({
    configurable: true,
    get(this: HTMLElement) {
      return this.classList.contains('react-flow') ? size : (descriptor?.get?.call(this) as number);
    },
  });
  Object.defineProperty(HTMLElement.prototype, 'offsetWidth', boxed(width, PANE_WIDTH));
  Object.defineProperty(HTMLElement.prototype, 'offsetHeight', boxed(height, PANE_HEIGHT));

  return () => {
    window.ResizeObserver = previous;
    if (width) Object.defineProperty(HTMLElement.prototype, 'offsetWidth', width);
    if (height) Object.defineProperty(HTMLElement.prototype, 'offsetHeight', height);
  };
}
