import { describe, expect, it } from 'vitest';

import { byPriority, contextsMatch, countdownText, pageRulesMatch, sessionRulesMatch, urlRuleMatches } from '../src/on-site';
import { InAppStore, triggerMatches, type InAppMessage } from '../src/in-app';
import type { InAppUrlRule } from '../src/on-site';

const facts = {
  href: 'https://shop.example/sale/shoes?utm_source=mail',
  isNewVisitor: true,
  now: new Date(2026, 8, 23, 23, 30),
  country: 'IN',
  device: 'desktop' as const,
};

/*
 * The server reads page rules the same way, so a rule decides alike on the page and on the server. `equals`, `not_equals`, `starts_with` and `ends_with` read the
 * address without its query and fragment unless the rule's value names one; `contains`, `not_contains` and the regex
 * rules read it whole.
 */
const URL_RULE_CASES: [InAppUrlRule['op'], string, string, boolean][] = [
  // A campaign's query or an in-page anchor does not break an address rule.
  ['equals', 'https://shop.example/pricing', 'https://shop.example/pricing?utm_source=mail', true],
  ['equals', 'https://shop.example/pricing', 'https://shop.example/pricing#faq', true],
  ['equals', 'https://shop.example/pricing/', 'https://shop.example/pricing?x=1', true],
  ['equals', 'https://shop.example', 'https://shop.example/?ref=ad', true],
  ['equals', 'https://shop.example/pricing', 'https://shop.example/pricing/team', false],
  ['not_equals', 'https://shop.example/pricing', 'https://shop.example/pricing?utm_source=mail', false],
  ['not_equals', 'https://shop.example/pricing', 'https://shop.example/about', true],
  ['ends_with', '/pricing', 'https://shop.example/pricing?q=1#faq', true],
  ['ends_with', '/pricing', 'https://shop.example/pricing/team', false],
  ['starts_with', 'https://shop.example/sale', 'https://shop.example/sale/shoes?utm_source=mail', true],
  ['starts_with', 'https://shop.example/sale', 'https://shop.example/?next=https://shop.example/sale', false],
  // A value that names a query or a fragment is asking about it, and gets the whole address.
  ['equals', 'https://shop.example/pricing?plan=pro', 'https://shop.example/pricing?plan=pro', true],
  ['equals', 'https://shop.example/pricing?plan=pro', 'https://shop.example/pricing?plan=free', false],
  ['equals', 'https://shop.example/pricing?plan=pro', 'https://shop.example/pricing', false],
  ['ends_with', '#faq', 'https://shop.example/pricing#faq', true],
  ['ends_with', '?plan=pro', 'https://shop.example/pricing?plan=pro', true],
  ['starts_with', 'https://shop.example/pricing?plan=', 'https://shop.example/pricing?plan=pro', true],
  // Contains and regex keep the whole address: a query value is often the point.
  ['contains', 'utm_campaign=spring', 'https://shop.example/?utm_campaign=spring', true],
  ['not_contains', 'utm_campaign=spring', 'https://shop.example/?utm_campaign=spring', false],
  ['contains', '/sale/', 'https://shop.example/sale/shoes?utm_source=mail', true],
  ['regex', 'utm_source=(mail|sms)$', 'https://shop.example/sale?utm_source=mail', true],
  ['not_regex', 'utm_source', 'https://shop.example/sale?utm_source=mail', false],
  ['path_equals', '/pricing/', 'https://shop.example/pricing?x=1#y', true],
  ['has_query', 'utm_source', 'https://shop.example/?utm_source=mail', true],
  ['equals', 'https://shop.example/', 'not a url', false],
];

describe('page rules', () => {
  it.each(URL_RULE_CASES)('%s %s on %s is %s', (op, value, href, expected) => {
    expect(urlRuleMatches({ op, value }, href)).toBe(expected);
  });
});

describe('on-site rules', () => {
  it('reads each page rule against the address, and path_equals against the path', () => {
    expect(urlRuleMatches({ op: 'contains', value: '/sale/' }, facts.href)).toBe(true);
    expect(urlRuleMatches({ op: 'path_equals', value: '/sale/shoes/' }, facts.href)).toBe(true);
    expect(urlRuleMatches({ op: 'has_query', value: 'utm_source' }, facts.href)).toBe(true);
    expect(urlRuleMatches({ op: 'not_regex', value: 'checkout' }, facts.href)).toBe(true);
    // A broken expression matches nothing, either way round.
    expect(urlRuleMatches({ op: 'regex', value: '(' }, facts.href)).toBe(false);
    expect(urlRuleMatches({ op: 'not_regex', value: '(' }, facts.href)).toBe(false);
  });

  it('joins page rules by all or any, and no rule is every page', () => {
    const rules = [
      { op: 'contains' as const, value: 'sale' },
      { op: 'contains' as const, value: 'checkout' },
    ];
    expect(pageRulesMatch({ url_rules: rules }, facts.href)).toBe(false);
    expect(pageRulesMatch({ url_rules: rules, url_match: 'any' }, facts.href)).toBe(true);
    expect(pageRulesMatch(undefined, facts.href)).toBe(true);
  });

  it('holds every session rule, and reads a time window across midnight as one', () => {
    expect(sessionRulesMatch([{ kind: 'time', from: '22:00', to: '02:00' }], facts)).toBe(true);
    expect(sessionRulesMatch([{ kind: 'time', from: '09:00', to: '17:00' }], facts)).toBe(false);
    expect(sessionRulesMatch([{ kind: 'query_param', key: 'utm_source', value: 'mail' }, { kind: 'visitor', value: 'new' }], facts)).toBe(true);
    expect(sessionRulesMatch([{ kind: 'country', countries: ['US'] }], facts)).toBe(false);
    // No country from the edge fails a country rule rather than passing it.
    expect(sessionRulesMatch([{ kind: 'country', countries: ['IN'] }], { ...facts, country: undefined })).toBe(false);
    expect(sessionRulesMatch([{ kind: 'day', days: [facts.now.getDay()] }, { kind: 'device', devices: ['desktop'] }], facts)).toBe(true);
  });

  it('asks for one of the contexts a message names, and none named is anywhere', () => {
    expect(contextsMatch(['checkout', 'cart'], new Set(['cart']))).toBe(true);
    expect(contextsMatch(['checkout'], new Set())).toBe(false);
    expect(contextsMatch(undefined, new Set())).toBe(true);
  });

  it('orders by priority, keeping newest first among equals', () => {
    const message = (id: string, priority?: number) =>
      ({ delivery_id: id, campaign_id: null, created_at: '', expires_at: null, content: { in_app: { surface: 'overlay', layout: 'modal', trigger: { kind: 'immediate' }, ...(priority ? { display: { priority } } : {}) } } }) as InAppMessage;
    expect(byPriority([message('a'), message('b', 9), message('c'), message('d', 2)]).map((m) => m.delivery_id)).toEqual(['b', 'a', 'c', 'd']);
  });

  it('matches a push_click trigger to the page a push opened', () => {
    expect(triggerMatches({ kind: 'push_click' }, 'notification_opened', {})).toBe(true);
    expect(triggerMatches({ kind: 'push_click', campaign_id: 'c1' }, 'notification_opened', { treebars_campaign_id: 'c2' })).toBe(false);
    expect(triggerMatches({ kind: 'push_click', campaign_id: 'c1' }, 'page_view', {})).toBe(false);
  });

  it('names why the store holds a message back', () => {
    const store = new InAppStore(false);
    const message = { delivery_id: 'd1', campaign_id: 'c1', created_at: '', expires_at: new Date(Date.now() - 1000).toISOString(), content: { in_app: { surface: 'overlay', layout: 'modal', trigger: { kind: 'immediate' } } } } as InAppMessage;
    expect(store.blockedBy(message)).toBe('expired');
    store.markDone('d1');
    expect(store.blockedBy(message)).toBe('done');
  });

  it('counts down in days and a clock, and says nothing once it is over', () => {
    const now = Date.parse('2026-09-23T00:00:00Z');
    expect(countdownText('2026-09-25T01:02:03Z', now)).toBe('2d 01:02:03');
    expect(countdownText('2026-09-22T00:00:00Z', now)).toBe('');
  });
});
