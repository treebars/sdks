import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

import { beforeEach, describe, expect, it, vi } from 'vitest';
import { InAppStore, type InAppMessage, type InAppPolicy } from '../src/in-app';

/*
 * The shared fixture every SDK's store answers: nudges and modals and the caps, one file, so the three SDKs cannot
 * drift. Kotlin's `InAppCapsFixtureTest` and Swift's `InAppCapsFixtureTests` read copies of the same file.
 */
interface Case {
  name: string;
  restart?: boolean;
  policy: Partial<InAppPolicy>;
  messages: { id: string; layout: 'modal' | 'nudge'; test?: boolean }[];
  shown: { id: string; session: string; seconds: number }[];
  asks: {
    id: string;
    session: string;
    seconds: number;
    in_flight?: number;
    expect: string | null;
  }[];
}
const FIXTURE = JSON.parse(readFileSync(fileURLToPath(new URL('./fixtures/in-app-caps.json', import.meta.url)), 'utf8')) as {
  cases: Case[];
};
const T = Date.UTC(2026, 8, 28, 9, 0);

describe('the shared caps fixture', () => {
  // A store that keeps what it holds, so `restart` can build a second one from it.
  beforeEach(() => {
    const kept = new Map<string, string>();
    vi.stubGlobal('localStorage', {
      getItem: (k: string) => kept.get(k) ?? null,
      setItem: (k: string, v: string) => void kept.set(k, v),
      removeItem: (k: string) => void kept.delete(k),
    });
  });

  it.each(FIXTURE.cases.map((c) => [c.name, c] as const))('%s', (_name, c) => {
    const messages: InAppMessage[] = c.messages.map((m) => ({
      delivery_id: m.id,
      campaign_id: null,
      created_at: new Date(T).toISOString(),
      expires_at: null,
      ...(m.test ? { test: true } : {}),
      content: {
        in_app: {
          surface: 'overlay',
          layout: m.layout,
          body_mode: 'html',
          html: '<p>x</p>',
          trigger: { kind: 'immediate' },
        } as never,
      },
    }));
    let store = new InAppStore(true);
    store.accept({
      messages,
      policy: {
        max_per_day: null,
        min_gap_seconds: null,
        messages_shown_today: 0,
        last_shown_at: null,
        ...c.policy,
      },
      server_time: new Date(T).toISOString(),
    });
    const byId = new Map(messages.map((m) => [m.delivery_id, m]));
    for (const shown of c.shown) store.recordDisplay(byId.get(shown.id)!, shown.session, T + shown.seconds * 1000);
    if (c.restart) store = new InAppStore(true);
    for (const ask of c.asks)
      expect(
        store.blockedBy(byId.get(ask.id)!, ask.session, T + ask.seconds * 1000, ask.in_flight ?? 0),
        `${ask.id} in ${ask.session} at ${ask.seconds}s, ${ask.in_flight ?? 0} in flight`,
      ).toBe(ask.expect);
  });
});
