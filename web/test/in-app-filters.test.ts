import { describe, expect, it } from 'vitest';

import { triggerMatches } from '../src/in-app';

/**
 * The unfinished-row rule, and `triggerMatches`.
 *
 * The dashboard's filter builder saves `{ key: '', op: 'eq', value: '' }` the moment "Add filter"
 * is clicked. Read literally that row asks for a property named `''`, which nothing has, and the
 * whole trigger would match nobody. So an unfinished row is dropped, as the server drops it, and a
 * campaign keeps reaching the browsers it reached before the row was added.
 */
const trigger = (filters: { key: string; op: string; value?: unknown }[]) =>
  ({ kind: 'event', event_name: 'purchase', filters }) as never;

const matches = (filters: { key: string; op: string; value?: unknown }[], props: Record<string, unknown>) =>
  triggerMatches(trigger(filters), 'purchase', props);

describe('an unfinished filter row', () => {
  const props = { plan: 'pro' };

  it('is ignored rather than matching nobody', () => {
    expect(matches([{ key: '', op: 'eq', value: '' }], props)).toBe(true);
  });

  it('is still unfinished when it has a key and nothing to compare against', () => {
    expect(matches([{ key: 'plan', op: 'eq', value: '' }], props)).toBe(true);
  });

  it('is unfinished when the value is missing entirely, which is not `eq null`', () => {
    expect(matches([{ key: 'plan', op: 'eq' }], props)).toBe(true);
  });

  /*
   * The shape that matters. Dropped BEFORE the conjunction rather than failed inside it, so the real
   * filter is left deciding — which is why `matchesFilters` filters and then folds.
   */
  it('leaves a real filter beside it deciding', () => {
    expect(matches([{ key: 'plan', op: 'eq', value: 'pro' }, { key: '', op: 'eq', value: '' }], props)).toBe(true);
    expect(matches([{ key: 'plan', op: 'eq', value: 'gold' }, { key: '', op: 'eq', value: '' }], props)).toBe(false);
  });

  it('does not drop `exists`, which is complete on its key alone', () => {
    expect(matches([{ key: 'plan', op: 'exists' }], props)).toBe(true);
    expect(matches([{ key: 'coupon', op: 'exists' }], props)).toBe(false);
  });

  /*
   * A missing operator fails closed like an unknown one, but only on a row that has a value. With
   * no value either, the row is unfinished and dropped. The native SDKs pin the same two answers.
   */
  it('is not a row missing only its operator, which fails closed', () => {
    expect(matches([{ key: 'plan', value: 'pro' } as never], props)).toBe(false);
    expect(matches([{ key: 'plan' } as never], props)).toBe(true);
  });

  it('leaves an authored filter working', () => {
    expect(matches([{ key: 'plan', op: 'eq', value: 'pro' }], props)).toBe(true);
    expect(matches([{ key: 'plan', op: 'eq', value: 'gold' }], props)).toBe(false);
  });
});

/*
 * The browser reads a condition as the server does — the fourteen codes, `""` as not set, the negated codes
 * matching a missing value, lists, the server's number reading, and a malformed element failing the whole trigger.
 */
describe('the fourteen codes, as the server reads them', () => {
  const on = (filter: Record<string, unknown>, props: Record<string, unknown>) => matches([{ key: 'v', ...filter } as never], props);

  it('answers each new code, and the negated ones on a value that is not set', () => {
    expect(on({ op: 'starts_with', value: 'pro' }, { v: 'pro-plan' })).toBe(true);
    expect(on({ op: 'ends_with', value: 'plan' }, { v: 'pro-plan' })).toBe(true);
    expect(on({ op: 'not_contains', value: 'team' }, { v: 'pro' })).toBe(true);
    expect(on({ op: 'in', value: '["pro","team"]' }, { v: 'pro' })).toBe(true);
    expect(on({ op: 'not_in', value: '["pro"]' }, { v: 'team' })).toBe(true);
    for (const props of [{}, { v: null }, { v: '' }]) {
      for (const [op, value] of [['neq', 'pro'], ['not_contains', 'x'], ['not_in', '["x"]'], ['not_exists', true]] as const) {
        expect(on({ op, value }, props), `${op} ${JSON.stringify(props)}`).toBe(true);
      }
      expect(on({ op: 'exists' }, props), `exists ${JSON.stringify(props)}`).toBe(false);
      expect(on({ op: 'lt', value: 'm' }, props), `lt ${JSON.stringify(props)}`).toBe(false);
    }
  });

  it('reads a list once, and a list that does not decode matches nobody', () => {
    expect(on({ op: 'in', value: '[1,2]' }, { v: 2 })).toBe(true);
    expect(on({ op: 'in', value: '[1,2]' }, { v: '2' })).toBe(false);
    expect(on({ op: 'in', value: '[1,2]', type: 'number' }, { v: '2' })).toBe(true);
    expect(on({ op: 'not_in', value: '[]' }, {})).toBe(false);
    expect(on({ op: 'not_in', value: '["a",1]' }, { v: 'z' })).toBe(false);
  });

  it('reads text as the server does', () => {
    expect(on({ op: 'eq', value: '150' }, { v: 150 })).toBe(true);
    expect(on({ op: 'eq', value: true }, { v: 'true' })).toBe(true);
    expect(on({ op: 'contains', value: '23' }, { v: 12345 })).toBe(true);
  });

  it('reads a number row strictly with no type', () => {
    expect(on({ op: 'eq', value: 150 }, { v: '150' })).toBe(false);
    expect(on({ op: 'gt', value: 100 }, { v: '150' })).toBe(false);
    expect(on({ op: 'gt', value: 0 }, { v: true })).toBe(false);
    // Under `type: 'number'`, text reads through the one grammar: "150" is 150, " 42" and "0x10" nothing.
    expect(on({ op: 'gt', value: 100, type: 'number' }, { v: '150' })).toBe(true);
    expect(on({ op: 'gte', value: 0, type: 'number' }, { v: ' 42' })).toBe(false);
    expect(on({ op: 'gte', value: 0, type: 'number' }, { v: '0x10' })).toBe(false);
  });

  it('fails the whole trigger on a malformed element, rather than dropping it and drawing', () => {
    const pro = { key: 'plan', op: 'eq', value: 'pro' };
    for (const bad of [null, 'x', { op: 'eq', value: 'pro' }, { key: 7, op: 'eq', value: 'pro' }]) {
      expect(triggerMatches(trigger([pro, bad] as never), 'purchase', { plan: 'pro' }), JSON.stringify(bad)).toBe(false);
    }
    expect(triggerMatches({ kind: 'event', event_name: 'purchase', filters: 'plan' } as never, 'purchase', { plan: 'pro' })).toBe(false);
  });

  it('fails closed on a property that is not a scalar, the negated codes included', () => {
    expect(on({ op: 'neq', value: 'pro' }, { v: ['pro'] })).toBe(false);
    expect(on({ op: 'exists' }, { v: { tier: 'pro' } })).toBe(true);
  });

  it('reads a row whose value is not a scalar as saying nothing, except under exists', () => {
    expect(on({ op: 'eq', value: ['pro'] }, { v: 'pro' })).toBe(false);
    expect(on({ op: 'not_in', value: { tier: 'pro' } }, {})).toBe(false);
    expect(on({ op: 'exists', value: ['pro'] }, { v: 'pro' })).toBe(true);
  });

  it('answers an unknown side or type with nothing, and a dimension row without a map', () => {
    expect(on({ op: 'eq', value: 'ios', source: 'dimension' }, { v: 'ios' })).toBe(false);
    expect(on({ op: 'eq', value: 'ios', source: 'device' }, { v: 'ios' })).toBe(false);
    expect(on({ op: 'eq', value: 'ios', type: 'colour' }, { v: 'ios' })).toBe(false);
  });
});

/*
 * A dimension row reads the map the SDK stamped on this event, normalised as the ingest endpoint will store
 * it, and a version row compares part by part.
 */
describe('a dimension row, and a version', () => {
  const dim = (filter: Record<string, unknown>, dimensions: Record<string, unknown> | null, props: Record<string, unknown> = {}) =>
    triggerMatches(trigger([{ source: 'dimension', ...filter } as never]), 'purchase', props, { dimensions });

  it('reads the dimension, never a property of the same name — and a property row never the dimension', () => {
    const dims = { platform_type: 'android' };
    expect(dim({ key: 'platform_type', op: 'eq', value: 'android' }, dims, { platform_type: 'ios' })).toBe(true);
    expect(dim({ key: 'platform_type', op: 'eq', value: 'ios' }, dims, { platform_type: 'ios' })).toBe(false);
    const property = trigger([{ key: 'platform_type', op: 'eq', value: 'ios' }]);
    expect(triggerMatches(property, 'purchase', { platform_type: 'ios' }, { dimensions: dims })).toBe(true);
    expect(triggerMatches(property, 'purchase', {}, { dimensions: { platform_type: 'ios' } })).toBe(false);
  });

  it('is false, not "not set", for geo, a name outside the list, an unknown side and a missing map — neq included', () => {
    expect(dim({ key: 'country', op: 'neq', value: 'DE' }, { country: 'FR' })).toBe(false);
    expect(dim({ key: 'plan', op: 'neq', value: 'pro' }, {})).toBe(false);
    expect(dim({ key: 'platform_type', op: 'neq', value: 'ios' }, null)).toBe(false);
    const side = trigger([{ key: 'platform_type', op: 'neq', value: 'ios', source: 'device' } as never]);
    expect(triggerMatches(side, 'purchase', {}, { dimensions: { platform_type: 'android' } })).toBe(false);
    // A map without the name is a map, so the name is not set, and a negated code matches it.
    expect(dim({ key: 'network_type', op: 'neq', value: 'wifi' }, { platform_type: 'web' })).toBe(true);
  });

  it('normalises a stamped value as ingest stores it: trimmed as trim() trims, cut at 128, a screen name untrimmed', () => {
    expect(dim({ key: 'device_model', op: 'eq', value: 'Pixel 8' }, { device_model: '\uFEFF Pixel 8\n' })).toBe(true);
    const long = 'x'.repeat(200);
    expect(dim({ key: 'device_model', op: 'eq', value: long.slice(0, 128) }, { device_model: long })).toBe(true);
    expect(dim({ key: 'screen_name', op: 'eq', value: ' Cart' }, { screen_name: ' Cart' })).toBe(true);
    expect(dim({ key: 'device_model', op: 'exists' }, { device_model: '   ' })).toBe(false);
  });

  it('compares versions part by part, as the measured pairs say', () => {
    const version = (op: string, value: string, stamped: string) =>
      dim({ key: 'app_version', op, value, type: 'version' }, { app_version: stamped });
    expect(version('gt', '2.9.1', '2.10')).toBe(true);
    expect(version('eq', '2.3', 'v2.3.0.0')).toBe(true);
    expect(version('lt', '10.0', '9.9.9')).toBe(true);
    expect(version('eq', '2.3', '2.3\n')).toBe(true); // Trimmed first, as ingest trims it.
  });

  it('reads a version that does not parse as false under neq and not_in, and set under exists', () => {
    for (const stamped of ['2.4.0-beta', '\uFF12.\uFF13', '+1', '1.2.3.4.5', '2.3 (45)']) {
      expect(dim({ key: 'app_version', op: 'neq', value: '2.3', type: 'version' }, { app_version: stamped }), stamped).toBe(false);
      expect(dim({ key: 'app_version', op: 'not_in', value: '["2.3"]', type: 'version' }, { app_version: stamped }), stamped).toBe(false);
      expect(dim({ key: 'app_version', op: 'exists', type: 'version' }, { app_version: stamped }), stamped).toBe(true);
    }
    // An authored value that does not parse says nothing — before the not-set reading, so a browser, which
    // stamps no app version at all, is not drawn by "is not 2.4.0-beta".
    expect(dim({ key: 'app_version', op: 'neq', value: '2.4.0-beta', type: 'version' }, { platform_type: 'web' })).toBe(false);
    expect(dim({ key: 'app_version', op: 'neq', value: '2.3', type: 'version' }, { platform_type: 'web' })).toBe(true);
    // A property row holding the JSON number 2.3 is no version either.
    const property = trigger([{ key: 'v', op: 'neq', value: '2.3', type: 'version' } as never]);
    expect(triggerMatches(property, 'purchase', { v: 2.3 }, {})).toBe(false);
  });
});
