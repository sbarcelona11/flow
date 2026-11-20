import { ActionIcon, TextInput } from '@mantine/core';
import { IconChevronLeft, IconChevronRight } from '@tabler/icons-react';
import { useEffect, useId, useState } from 'react';

import type { ModuleBlock } from '@/types/generated';

import { EFFECT_LABELS } from 'shared/lib/actionEffects';

import { KIND_LABELS, type StepKind } from '../builderDraft';
import { type Blocks, isActionBlock, isCompositeBlock } from '../useBlocks';

import classes from './WorkflowCanvas.module.css';

interface Props {
  actionsEnabled: boolean;
  blocks: Blocks;
  onWantBlocks: () => void;
  onAdd: (kind: StepKind) => void;
  onAddBlock: (block: ModuleBlock) => void;
  /** Inserts a composite block as a group of steps. */
  onAddComposite?: (block: ModuleBlock) => void;
  readOnly: boolean;
}

const matches = (block: ModuleBlock, query: string) =>
  `${block.label} ${block.description ?? ''}`.toLowerCase().includes(query.trim().toLowerCase());

export function CanvasPalette({
  actionsEnabled,
  blocks,
  onWantBlocks,
  onAdd,
  onAddBlock,
  onAddComposite,
  readOnly,
}: Props) {
  const [open, setOpen] = useState(true);
  const [query, setQuery] = useState('');
  const stepsId = useId();
  const blocksId = useId();
  const wantsBlocks = actionsEnabled && !readOnly;

  useEffect(() => {
    if (wantsBlocks) onWantBlocks();
  }, [wantsBlocks, onWantBlocks]);

  if (readOnly) return null;

  const kinds: StepKind[] = actionsEnabled ? ['agent', 'approval', 'wait', 'action'] : ['agent', 'approval', 'wait'];
  const choices = blocks.blocks
    .filter((block) => isActionBlock(block) || (onAddComposite !== undefined && isCompositeBlock(block)))
    .filter((block) => matches(block, query));

  return (
    <div className={`${classes.palette} nopan nodrag nowheel`}>
      <ActionIcon
        size="sm"
        variant="subtle"
        aria-expanded={open}
        aria-label={open ? 'Hide palette' : 'Show palette'}
        onClick={() => setOpen((was) => !was)}
      >
        {open ? <IconChevronLeft size={14} aria-hidden /> : <IconChevronRight size={14} aria-hidden />}
      </ActionIcon>
      {open && (
        <>
          <h3 id={stepsId} className={classes.paletteHeading}>
            Steps
          </h3>
          <ul aria-labelledby={stepsId} className={classes.paletteList}>
            {kinds.map((kind) => (
              <li key={kind}>
                <button type="button" className={classes.paletteEntry} onClick={() => onAdd(kind)}>
                  {KIND_LABELS[kind]}
                </button>
              </li>
            ))}
          </ul>
          {actionsEnabled && (
            <>
              <h3 id={blocksId} className={classes.paletteHeading}>
                Blocks
              </h3>
              <TextInput
                size="xs"
                aria-label="Search blocks"
                placeholder="Search blocks"
                value={query}
                onChange={(event) => setQuery(event.currentTarget.value)}
              />
              {blocks.status === 'error' && <p className={classes.paletteNote}>The blocks could not be loaded.</p>}
              {blocks.status !== 'error' && blocks.status !== 'ready' && (
                <p className={classes.paletteNote}>Loading blocks…</p>
              )}
              {blocks.status === 'ready' && choices.length === 0 && (
                <p className={classes.paletteNote}>
                  {query.trim() ? 'No block matches.' : 'No blocks are available in this project.'}
                </p>
              )}
              <ul aria-labelledby={blocksId} className={classes.paletteList}>
                {choices.map((block) => (
                  <li key={block.key}>
                    <button
                      type="button"
                      className={classes.paletteEntry}
                      title={block.description ?? undefined}
                      onClick={() => (isCompositeBlock(block) ? onAddComposite?.(block) : onAddBlock(block))}
                    >
                      {block.label} {isCompositeBlock(block) && <span className={classes.paletteEffect}>Group</span>}
                      {block.effect && <span className={classes.paletteEffect}>{EFFECT_LABELS[block.effect]}</span>}
                    </button>
                  </li>
                ))}
              </ul>
            </>
          )}
        </>
      )}
    </div>
  );
}
