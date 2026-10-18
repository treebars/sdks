import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';

import { inAppEnvAttributes, inAppEnvJson, inAppEnvStyle, inAppHostEnv, inAppStripBox, type HostEnvInput, type InAppEnv, type StripBoxInput } from '../src/host-env';

/**
 * The cases every SDK runs (`fixtures/in-app-host.json`): where a strip goes, and what a page is told about its screen —
 * on first draw, after a turn, with a keyboard up and down — as the text the page actually reads. The Android and iOS
 * SDKs compute their own answers and are held to the same ones.
 */

const fixture = JSON.parse(readFileSync(fileURLToPath(new URL('./fixtures/in-app-host.json', import.meta.url)), 'utf8')) as {
  strips: { name: string; input: StripBoxInput; box: { x: number; y: number; w: number; h: number } }[];
  envs: { name: string; input: HostEnvInput; env: InAppEnv; json: string; style: string; attributes: string }[];
};

describe('the host cases every SDK runs', () => {
  it('puts every strip where the reference puts it', () => {
    expect(fixture.strips.length).toBeGreaterThan(0);
    for (const { name, input, box } of fixture.strips) {
      const got = inAppStripBox(input);
      for (const key of ['x', 'y', 'w', 'h'] as const) expect(got[key], `${name}: ${key}`).toBeCloseTo(box[key], 3);
    }
  });

  it('tells every page its screen byte for byte as the reference writes it', () => {
    expect(fixture.envs.length).toBeGreaterThan(0);
    for (const { name, input, env, json, style, attributes } of fixture.envs) {
      const got = inAppHostEnv(input);
      expect(got, name).toEqual(env);
      expect(inAppEnvJson(got), name).toBe(json);
      expect(inAppEnvStyle(got), name).toBe(style);
      expect(inAppEnvAttributes(got), name).toBe(attributes);
    }
  });
});
