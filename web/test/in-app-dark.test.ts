import { describe, expect, it } from 'vitest';

import { InAppStore, type InAppMessage, type InAppTokens } from '../src/in-app';

/**
 * A message's dark variant: the sync ships `style_dark` beside `style` when it has one, and the store hands the
 * renderer the dark tokens on a page read in dark mode — the light ones otherwise, and always for a message with no
 * dark variant. The same cases as Kotlin's `InAppDarkTokensTest` and Swift's.
 */
const tokens = (surface: string): InAppTokens => ({
  accent: '#5B4DF5',
  on_accent: '#FFFFFF',
  surface,
  on_surface: '#111827',
  on_surface_muted: '#6B7280',
  backdrop: '#0F172A99',
  radius: 8,
  font_family: '',
  button_shape: 'rounded',
});

const message = (id: string, dark: boolean): InAppMessage => ({
  delivery_id: id,
  campaign_id: 'c1',
  content: { title: 'Hi', in_app: { surface: 'overlay', layout: 'modal', trigger: { kind: 'immediate' } } },
  created_at: '2026-09-28T12:00:00.000Z',
  expires_at: null,
  style: tokens('#FFFFFF'),
  ...(dark ? { style_dark: tokens('#16161D') } : {}),
});

describe('a dark variant on the web', () => {
  it('is handed on a dark page, and the light tokens everywhere else', () => {
    const store = new InAppStore(false);
    expect(store.styleTokensFor(message('both', true))?.surface).toBe('#FFFFFF');
    expect(store.styleTokensFor(message('both', true), true)?.surface).toBe('#16161D');
    expect(store.styleTokensFor(message('light', false), true)?.surface).toBe('#FFFFFF');
  });
});
