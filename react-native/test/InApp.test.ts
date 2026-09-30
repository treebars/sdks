import { describe, expect, it } from 'vitest';

import { inAppBodyMode, inAppHtmlDocument, inAppShape, readInAppHtmlAction } from '../src/InApp';

/**
 * The in-app helpers this package holds itself.
 *
 * The trigger matcher, the frequency rules and the rest of the in-app store are tested in the
 * Kotlin and Swift SDKs, where they run.
 *
 * These blocks stay here, and the reason is the WebView. `inAppShape` and
 * `inAppBodyMode` answer "where does this go" and "who writes the body" — two questions since
 * custom HTML became a body rather than a shape — and the host app needs both to pick a
 * renderer. `readInAppHtmlAction` parses `treebars://`, the only channel sandboxed markup has
 * back into the SDK, and its rejections are the interesting half: `about:blank`, `data:` and a
 * bare `#` are loads a WebView issues by itself, and a parser that treated them as actions
 * would fire a click on every render.
 */

/*
 * Shape, body mode, and the scheme that gets a sandbox back into the SDK.
 *
 * These are what a renderer reads, and all three fail the same silent way: the message is
 * drawn, so nothing errors, and it is drawn wrong — a custom-HTML body rendered as an empty
 * themed card, or a dismiss link that navigates instead of closing.
 */
describe('shape and body mode', () => {
  it('reads the two axes apart', () => {
    expect(inAppShape({ layout: 'banner' })).toBe('banner');
    expect(inAppBodyMode({ layout: 'banner', body_mode: 'html' })).toBe('html');
    expect(inAppBodyMode({ layout: 'modal' })).toBe('standard');
  });

  // The spelling every message written before `body_mode` existed uses. A renderer reading
  // `layout` directly draws it as a modal with no body at all.
  it('reads the legacy layout: html as a fullscreen markup body', () => {
    expect(inAppShape({ layout: 'html' })).toBe('fullscreen');
    expect(inAppBodyMode({ layout: 'html' })).toBe('html');
  });

  it('lets an explicit body_mode overrule the legacy spelling', () => {
    expect(inAppBodyMode({ layout: 'html', body_mode: 'standard' })).toBe('standard');
  });

  it('answers for a message with no in_app block at all', () => {
    expect(inAppShape(undefined)).toBe('modal');
    expect(inAppBodyMode(undefined)).toBe('standard');
  });
});

describe('the custom-HTML URL scheme', () => {
  it('reads the two verbs the SDK owns', () => {
    expect(readInAppHtmlAction('treebars://dismiss')).toEqual({ kind: 'dismiss' });
    expect(readInAppHtmlAction('treebars://click/2')).toEqual({ kind: 'click', index: 2 });
  });

  /*
   * Only the two verbs are the SDK's. A campaign's own destinations under `treebars://` belong
   * to the app, and claiming the whole scheme would swallow them.
   */
  it('leaves the rest of the scheme to the host app', () => {
    expect(readInAppHtmlAction('treebars://product/ABC-1')).toEqual({
      kind: 'link',
      url: 'treebars://product/ABC-1',
    });
    expect(readInAppHtmlAction('https://example.com/x')).toEqual({
      kind: 'link',
      url: 'https://example.com/x',
    });
  });

  /*
   * The loads a WebView makes on its own. Treating one as a click would report an
   * interaction for every message merely shown.
   */
  it('ignores the document it was handed', () => {
    expect(readInAppHtmlAction('about:blank')).toBeNull();
    expect(readInAppHtmlAction('data:text/html,<b>hi</b>')).toBeNull();
    expect(readInAppHtmlAction('#')).toBeNull();
    expect(readInAppHtmlAction('  ')).toBeNull();
  });

  /*
   * A host opens a link, so a link that runs is the markup's way out of its sandbox.
   */
  it('never hands the host a URL that would run where it is opened', () => {
    expect(readInAppHtmlAction('javascript:alert(1)')).toBeNull();
    expect(readInAppHtmlAction('java\tscript:alert(1)')).toBeNull();
    expect(readInAppHtmlAction('file:///etc/passwd')).toBeNull();
  });
});

/*
 * A markup body's direction. A WebView's document inherits nothing from the view around it, so the
 * `writingDirection` the typed layouts use does not reach custom HTML: the document has to say it.
 */
describe('a markup body’s direction', () => {
  it('puts right-to-left on the document, straight after the doctype', () => {
    const page = inAppHtmlDocument('<p>Special offer</p>', 'rtl');
    expect(page.startsWith('<!doctype html><html dir="rtl"><meta charset="utf-8">')).toBe(true);
    expect(page.endsWith('<p>Special offer</p>')).toBe(true);
  });

  it('leaves markup that sets its own direction alone', () => {
    for (const html of ['<html dir="ltr"><p>x</p></html>', '<body DIR=rtl><p>x</p></body>']) {
      expect(inAppHtmlDocument(html, 'rtl')).toBe(inAppHtmlDocument(html));
    }
  });

  it('wraps a message with no direction, or a left-to-right one, exactly as before', () => {
    expect(inAppHtmlDocument('<p>x</p>', 'ltr')).toBe(inAppHtmlDocument('<p>x</p>'));
    expect(inAppHtmlDocument('<p>x</p>', undefined)).toBe(inAppHtmlDocument('<p>x</p>'));
    expect(inAppHtmlDocument('<p>x</p>')).not.toContain('dir=');
  });
});
