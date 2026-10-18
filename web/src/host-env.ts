import { IN_APP_CONTAINER } from './generated/bridge';

/*
 * What the host tells an HTML message about the screen it is on, and where a strip goes.
 *
 * The host paints nothing. A stage message — a modal, a sheet, a full screen, a canvas — is a transparent frame over the
 * whole window, and the page draws its own scrim, card and shadow; a strip — a banner, a nudge — is a transparent frame
 * fitted at an edge. Either way the page can only place itself right if it is told the truth about the screen: the
 * insets, which way the device is held, the theme. It is told when the document is built and again on every change.
 *
 * The Android and iOS SDKs compute the same answers in their own languages, and the shared cases in
 * `test/fixtures/in-app-host.json` hold all three to them — the box to the point, and the text a page reads byte for
 * byte.
 */

export interface HostWindow {
  width: number;
  height: number;
}

export interface HostInsets {
  top: number;
  right: number;
  bottom: number;
  left: number;
}

/** A box in the window, in CSS pixels. */
export interface HostRect {
  x: number;
  y: number;
  w: number;
  h: number;
}

/** What the page is told: CSS pixels, rounded up, and the text scale to the hundredth. */
export interface InAppEnv {
  host: 'ios' | 'android' | 'web';
  device: 'phone' | 'tablet' | 'desktop';
  orientation: 'portrait' | 'landscape';
  theme: 'light' | 'dark';
  safe: { top: number; right: number; bottom: number; left: number };
  keyboard: { height: number; ms: number };
  textScale: number;
  shown: boolean;
}

export interface StripBoxInput {
  window: HostWindow;
  /** The window's safe-area insets. */
  safe: HostInsets;
  edge: 'top' | 'bottom';
  /** A nudge floats inside the safe area; a banner is flush with its edge and pads by the inset itself. */
  floating: boolean;
  /** What the page reported, its shadow room included; null before it has. */
  contentHeight: number | null;
  /** How much of this edge the nudges drawn before this one already take. */
  offset?: number;
}

/**
 * Where a strip goes. Its height is what the page reported up to a share of the window — 30% for a banner, 20% for a
 * nudge — and the cap before it has. A banner spans the window at its edge; a nudge sits inside the safe area.
 */
export function inAppStripBox(input: StripBoxInput): HostRect {
  const { window, safe, edge, floating } = input;
  const cap = window.height * (floating ? IN_APP_CONTAINER.nudge.maxHeightShare : IN_APP_CONTAINER.banner.maxHeightShare);
  const h = Math.max(0, Math.min(input.contentHeight ?? cap, cap));
  if (!floating) return { x: 0, y: edge === 'top' ? 0 : window.height - h, w: window.width, h };
  const offset = input.offset ?? 0;
  const w = Math.max(0, window.width - safe.left - safe.right);
  return { x: safe.left, y: edge === 'top' ? safe.top + offset : window.height - safe.bottom - offset - h, w, h };
}

export interface HostEnvInput {
  host: InAppEnv['host'];
  device: InAppEnv['device'];
  theme: InAppEnv['theme'];
  textScale: number;
  shown: boolean;
  window: HostWindow;
  /** The window's safe-area insets. */
  safe: HostInsets;
  /** The frame in the window. Absent for a stage, which is the window. */
  frame?: HostRect | null;
  /** How far a keyboard reaches up from the window's bottom edge, and how long its move takes. */
  keyboard: { height: number; ms: number };
}

/** Up to the next whole pixel, forgiving the noise a division leaves (59.0000001 is 59). */
function up(value: number): number {
  return Math.max(0, Math.ceil(value - 0.001));
}

const clamp = (value: number, low: number, high: number) => Math.min(Math.max(value, low), high);

/** The text scale to the hundredth, and 1 for anything that is not a positive number. */
export function envTextScale(value: number): number {
  return Number.isFinite(value) && value > 0 ? Math.round(value * 100) / 100 : 1;
}

/** The environment for a frame at `frame` in `window`: the part of the unsafe area and of a keyboard that lies over it. */
export function inAppHostEnv(input: HostEnvInput): InAppEnv {
  const { window, safe } = input;
  const frame = input.frame ?? { x: 0, y: 0, w: window.width, h: window.height };
  const keyboardTop = window.height - clamp(input.keyboard.height, 0, window.height);
  return {
    host: input.host,
    device: input.device,
    orientation: window.width > window.height ? 'landscape' : 'portrait',
    theme: input.theme,
    safe: {
      top: up(clamp(safe.top - frame.y, 0, frame.h)),
      right: up(clamp(frame.x + frame.w - (window.width - safe.right), 0, frame.w)),
      bottom: up(clamp(frame.y + frame.h - (window.height - safe.bottom), 0, frame.h)),
      left: up(clamp(safe.left - frame.x, 0, frame.w)),
    },
    keyboard: { height: up(clamp(frame.y + frame.h - keyboardTop, 0, frame.h)), ms: Math.max(0, Math.round(input.keyboard.ms)) },
    textScale: envTextScale(input.textScale),
    shown: input.shown,
  };
}

/** `1`, `1.3`, `1.15`: the shortest text of a scale to the hundredth. */
export function envScaleText(value: number): string {
  const hundredths = Math.round(envTextScale(value) * 100);
  const whole = Math.floor(hundredths / 100);
  const rest = hundredths % 100;
  if (rest === 0) return String(whole);
  return rest % 10 === 0 ? `${whole}.${rest / 10}` : `${whole}.${String(rest).padStart(2, '0')}`;
}

/** The environment as a host sends it: one key order and one way to write each number, on every platform. */
export function inAppEnvJson(env: InAppEnv): string {
  const { safe, keyboard } = env;
  return (
    `{"host":"${env.host}","device":"${env.device}","orientation":"${env.orientation}","theme":"${env.theme}",` +
    `"safe":{"top":${safe.top},"right":${safe.right},"bottom":${safe.bottom},"left":${safe.left}},` +
    `"keyboard":{"height":${keyboard.height},"ms":${keyboard.ms}},"textScale":${envScaleText(env.textScale)},"shown":${env.shown}}`
  );
}

/**
 * The `<style id="tb-env">` the page reads its environment from. `color-scheme: normal`, as the frame's element says
 * too, because a browser paints an opaque backdrop behind a frame whose colour scheme differs from the page around it.
 */
export function inAppEnvStyle(env: InAppEnv): string {
  const { safe, keyboard } = env;
  return (
    `:root{color-scheme:normal;--tb-safe-top:${safe.top}px;--tb-safe-right:${safe.right}px;--tb-safe-bottom:${safe.bottom}px;` +
    `--tb-safe-left:${safe.left}px;--tb-keyboard:${keyboard.height}px;--tb-keyboard-ms:${keyboard.ms}ms;--tb-text-scale:${envScaleText(env.textScale)}}`
  );
}

/** `<html>`'s attributes, with a leading space: the keyboard and shown states present or absent. */
export function inAppEnvAttributes(env: InAppEnv): string {
  return (
    ` data-tb-host="${env.host}" data-tb-device="${env.device}" data-tb-orientation="${env.orientation}" data-tb-theme="${env.theme}"` +
    `${env.keyboard.height > 0 ? ' data-tb-keyboard' : ''}${env.shown ? ' data-tb-shown' : ''}`
  );
}
