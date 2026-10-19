import { readFileSync } from 'node:fs';

import { afterEach, describe, expect, it, vi } from 'vitest';

import { AppActions, type AppAction } from '../src/app-actions';

/**
 * The page's `onAction`: the dispatcher every SDK runs, held to the shared cases (`app-action-scenarios.json`) — which
 * handlers an action reaches, how long one nothing has subscribed to waits, and what is recorded about each.
 */

interface Step {
  on?: string | null;
  id?: string;
  throws?: boolean;
  off?: string;
  fire?: AppAction;
  record?: boolean;
  advance?: number;
}

const { cases } = JSON.parse(readFileSync(new URL('./fixtures/app-action-scenarios.json', import.meta.url), 'utf8')) as {
  cases: { name: string; steps: Step[]; delivered: [string, string, Record<string, unknown>][]; events: [string, Record<string, unknown>][] }[];
};

describe('the app action cases every SDK runs', () => {
  afterEach(() => vi.useRealTimers());

  it.each(cases)('$name', (spec) => {
    vi.useFakeTimers();
    const events: [string, Record<string, unknown>][] = [];
    const delivered: [string, string, Record<string, unknown>][] = [];
    const actions = new AppActions({ track: (name, properties) => events.push([name, properties]) });
    const stops = new Map<string, () => void>();
    for (const step of spec.steps) {
      if (step.on !== undefined) {
        const id = step.id!;
        stops.set(
          id,
          actions.on(step.on, (action) => {
            delivered.push([id, action.name, action.payload]);
            if (step.throws) throw new Error('the app’s handler threw');
          }),
        );
      } else if (step.off) stops.get(step.off)?.();
      else if (step.fire) actions.fire(step.fire, step.record !== false);
      else if (step.advance !== undefined) vi.advanceTimersByTime(step.advance);
    }
    expect(delivered).toEqual(spec.delivered);
    expect(events).toEqual(spec.events);
  });
});

describe('onAction on the page', () => {
  afterEach(() => {
    vi.useRealTimers();
    vi.resetModules();
  });

  it('takes a name and a handler, or a handler for every action, and refuses a name that is not one', async () => {
    const { default: treebars } = await import('../src/index');
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => undefined);
    const stop = treebars.onAction('Add To Cart', () => undefined);
    expect(warn).toHaveBeenCalledOnce();
    expect(stop()).toBeUndefined();
    const got: string[] = [];
    const named = treebars.onAction('add_to_cart', (action) => got.push(`named ${action.name}`));
    const every = treebars.onAction((action) => got.push(`every ${action.name}`));
    (treebars as unknown as { appActions: { fire(action: AppAction, record: boolean): void } }).appActions.fire(
      { name: 'add_to_cart', payload: { sku: 'A' }, source: { kind: 'in_app', message_id: 'd-1' } },
      false,
    );
    named();
    every();
    (treebars as unknown as { appActions: { fire(action: AppAction, record: boolean): void } }).appActions.fire(
      { name: 'add_to_cart', payload: {}, source: { kind: 'in_app' } },
      false,
    );
    expect(got).toEqual(['named add_to_cart', 'every add_to_cart']);
    warn.mockRestore();
  });
});
