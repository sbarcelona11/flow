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
