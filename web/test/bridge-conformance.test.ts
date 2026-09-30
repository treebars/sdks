import { readFileSync } from 'node:fs';

import { describe, expect, it } from 'vitest';

import { BridgeDisplay, type BridgeSdk } from '../src/bridge-calls';
import { bridgeDocument } from '../src/bridge-host';
import type { InAppMessage } from '../src/in-app';

/**
 * The web half of the bridge's two shared contracts, which the Android and iOS SDKs run too: the documents a host
 * builds, byte for byte (`bridge-documents.json`, generated), and what each call means (`bridge-conformance.json`,
 * written by hand).
 */
const fixture = (name: string) => JSON.parse(readFileSync(new URL(`./fixtures/${name}`, import.meta.url), 'utf8'));

describe('the golden documents', () => {
  const { cases } = fixture('bridge-documents.json') as { cases: { name: string; html: string; options: Parameters<typeof bridgeDocument>[1]; document: string }[] };

  it.each(cases)('$name', ({ html, options, document }) => {
    expect(bridgeDocument(html, options)).toBe(document);
  });
});

interface Step {
  call?: string;
  args?: unknown[];
  answer?: unknown;
  turn?: boolean;
}

interface Case {
  name: string;
  message: { delivery_id: string; campaign_id: string | null; declared: { events: string[]; traits: string[] }; stored: Record<string, string | number | boolean> };
  signed_in: boolean;
  steps: Step[];
  events?: [string, Record<string, unknown>][];
  event_count?: number;
  traits?: Record<string, unknown>[];
  opened?: [string, string][];
  /** What the server answers `claimReward` with, per pool; absent, every pool is refused. */
  rewards?: Record<string, Record<string, unknown>>;
  closes?: number;
  dismissed?: number;
  spent?: number;
  clicked?: number;
}

const turn = () => new Promise((resolve) => setTimeout(resolve, 0));

describe('what each call means', () => {
  const { cases } = fixture('bridge-conformance.json') as { cases: Case[] };

  it.each(cases)('$name', async (spec) => {
    const events: [string, Record<string, unknown>][] = [];
    const traits: Record<string, unknown>[] = [];
    const opened: [string, string][] = [];
    const count = { closes: 0, dismissed: 0, spent: 0, clicked: 0 };
    const sdk: BridgeSdk = {
      track: (name, properties) => events.push([name, properties]),
      // Signed in or not: a visitor's traits go on the anonymous person, and the page cannot tell.
      setTraits: (next) => {
        traits.push(next);
        return { ok: true };
      },
      requestPushPermission: async () => 'granted',
      announceClicked: () => (count.clicked += 1),
      open: (url, via) => opened.push([url, via]),
      spent: () => (count.spent += 1),
      dismissed: () => (count.dismissed += 1),
      flush: () => {},
      log: () => {},
      // The server's answers a case names (`rewards`); a pool it does not name is one the server refuses.
      claimReward: async (pool) => spec.rewards?.[pool] ?? { ok: false, reason: 'not_available' },
    };
    const message: InAppMessage = {
      delivery_id: spec.message.delivery_id,
      campaign_id: spec.message.campaign_id,
      content: { in_app: { surface: 'overlay', layout: 'modal', body_mode: 'html', html: '<p>x</p>', trigger: { kind: 'immediate' }, declared: spec.message.declared } },
      created_at: '2026-09-27T10:00:00.000Z',
      expires_at: null,
      stored: { ...spec.message.stored },
    };
    const display = new BridgeDisplay(message, sdk);
    for (const step of spec.steps) {
      if (step.turn) {
        await turn();
        continue;
      }
      const answer = await display.call(step.call!, step.args ?? [], () => (count.closes += 1));
      expect(JSON.parse(JSON.stringify(answer ?? null)), `${step.call}(${JSON.stringify(step.args)})`).toEqual(step.answer ?? null);
    }
    await turn();
    if (spec.events) expect(JSON.parse(JSON.stringify(events))).toEqual(spec.events);
    if (spec.event_count !== undefined) expect(events).toHaveLength(spec.event_count);
    if (spec.traits) expect(traits).toEqual(spec.traits);
    if (spec.opened) expect(opened).toEqual(spec.opened);
    for (const key of ['closes', 'dismissed', 'spent', 'clicked'] as const) if (spec[key] !== undefined) expect(count[key], key).toBe(spec[key]);
  });
});
