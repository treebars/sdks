import type { InAppCard, InAppTokens } from './in-app';
import type { NotificationPage, TreebarsNotification } from './notifications';

/*
 * A ready-made notification centre — for a site that wants the list without writing one. The data API stays the
 * product (`treebars.notifications`); this is one page drawn on it, in a shadow root so the site's styles and the
 * centre's cannot touch, and a site with its own design keeps drawing its own.
 *
 * What it draws: every notification and card the person was sent, pinned cards first among what is loaded, an unread
 * dot, a tab per card category when there is more than one, a way to dismiss each and to mark all read, and "Show
 * more" while the server has more. A tap marks the row opened — the campaign report's Opened — then goes where the
 * card or the push said, unless `onOpen` handles it.
 */

export interface NotificationCenterOptions {
  title?: string;
  emptyText?: string;
  /** Called before a tap goes anywhere; return `false` to go nowhere, having handled it yourself. */
  onOpen?: (notification: TreebarsNotification) => boolean | void;
  /** The centre's colours and radius; the in-app tokens a message carries otherwise. */
  tokens?: Partial<InAppTokens>;
}

export interface NotificationCenterHost {
  list: (options: { cursor?: string | null }) => Promise<NotificationPage>;
  markOpened: (groupId: string) => Promise<void>;
  markAllRead: () => Promise<void>;
  dismiss: (groupId: string) => Promise<void>;
  onChange: (callback: (page: NotificationPage) => void) => () => void;
}

const TOKENS: InAppTokens = {
  accent: '#1c1c1a',
  on_accent: '#ffffff',
  surface: '#ffffff',
  on_surface: '#1c1c1a',
  on_surface_muted: '#6b6b66',
  backdrop: 'rgba(0,0,0,.45)',
  radius: 12,
  font_family: '-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif',
  button_shape: 'rounded',
};

function cardOf(notification: TreebarsNotification): InAppCard | undefined {
  return notification.content.in_app?.card;
}

/** Where a tap goes: the card's own action, else the push's deep link. */
export function destinationOf(notification: TreebarsNotification): string | undefined {
  return cardOf(notification)?.action?.value || notification.content.deep_link || undefined;
}

/** A card's own button, when it has words and somewhere to go. */
export function ctaOf(notification: TreebarsNotification): { label: string; action: { value: string } } | undefined {
  const cta = cardOf(notification)?.cta;
  return cta?.label && cta.action?.value ? cta : undefined;
}

/** Pinned cards first, the rest in the order the server sent them (newest first). */
export function orderForCenter(rows: TreebarsNotification[]): TreebarsNotification[] {
  return rows.filter((row) => cardOf(row)?.pinned).concat(rows.filter((row) => !cardOf(row)?.pinned));
}

/** The categories the loaded cards name, in first-seen order. */
export function categoriesOf(rows: TreebarsNotification[]): string[] {
  return [...new Set(rows.map((row) => cardOf(row)?.category).filter((name): name is string => Boolean(name)))];
}

function el<K extends keyof HTMLElementTagNameMap>(tag: K, css: string, text?: string): HTMLElementTagNameMap[K] {
  const node = document.createElement(tag);
  node.style.cssText = css;
  if (text !== undefined) node.textContent = text;
  return node;
}

/**
 * Draws the notification centre inside `target`, loads the first page and keeps it current as the list changes.
 * Returns a function that takes it down again; `target` can be mounted into again afterwards.
 */
export function mountNotificationCenter(target: HTMLElement, host: NotificationCenterHost, options: NotificationCenterOptions = {}): () => void {
  const tokens = { ...TOKENS, ...(options.tokens ?? {}) };
  // A host of our own inside the target, so the target can be mounted into again after an unmount.
  const holder = document.createElement('div');
  target.appendChild(holder);
  const root = holder.attachShadow ? holder.attachShadow({ mode: 'open' }) : holder;
  const frame = el('div', `font:14px/1.45 ${tokens.font_family};color:${tokens.on_surface};background:${tokens.surface};border-radius:${tokens.radius}px;overflow:hidden`);
  frame.setAttribute('role', 'region');
  frame.setAttribute('aria-label', options.title ?? 'Notifications');
  root.appendChild(frame);

  /** The first page as last emitted, and the pages loaded after it; `rows` is the two together. */
  let firstPage: TreebarsNotification[] = [];
  let deeper: TreebarsNotification[] = [];
  let rows: TreebarsNotification[] = [];
  const join = () => {
    const first = new Set(firstPage.map((row) => row.group_id));
    rows = [...firstPage, ...deeper.filter((row) => !first.has(row.group_id))];
  };
  let cursor: string | null = null;
  let tab: string | null = null;
  let loading = false;

  const header = el('div', `display:flex;align-items:center;gap:8px;padding:12px 14px;border-bottom:1px solid rgba(0,0,0,.08)`);
  const title = el('strong', 'flex:1;font-size:15px', options.title ?? 'Notifications');
  const readAll = el('button', `font:inherit;font-size:13px;border:0;background:none;color:${tokens.accent};cursor:pointer;padding:4px`, 'Mark all read');
  readAll.type = 'button';
  readAll.addEventListener('click', () => void host.markAllRead());
  header.append(title, readAll);
  const tabs = el('div', 'display:flex;gap:6px;padding:8px 14px 0;flex-wrap:wrap');
  tabs.setAttribute('role', 'tablist');
  const list = el('ul', 'list-style:none;margin:0;padding:0');
  const more = el('button', `font:inherit;display:block;width:100%;border:0;background:none;padding:12px;color:${tokens.accent};cursor:pointer`, 'Show more');
  more.type = 'button';
  frame.append(header, tabs, list, more);

  const draw = () => {
    const categories = categoriesOf(rows);
    tabs.replaceChildren();
    if (categories.length > 1) {
      for (const name of [null, ...categories]) {
        const button = el(
          'button',
          `font:inherit;font-size:13px;padding:4px 10px;border-radius:999px;cursor:pointer;border:1px solid ${tokens.on_surface_muted};background:${tab === name ? tokens.accent : 'transparent'};color:${tab === name ? tokens.on_accent : tokens.on_surface}`,
          name ?? 'All',
        );
        button.type = 'button';
        button.setAttribute('role', 'tab');
        button.setAttribute('aria-selected', String(tab === name));
        button.addEventListener('click', () => {
          tab = name;
          draw();
        });
        tabs.appendChild(button);
      }
    } else tab = null;

    const shown = orderForCenter(rows).filter((row) => tab === null || cardOf(row)?.category === tab);
    list.replaceChildren();
    if (shown.length === 0) list.appendChild(el('li', `padding:24px 14px;color:${tokens.on_surface_muted};text-align:center`, options.emptyText ?? 'Nothing here yet.'));
    for (const row of shown) list.appendChild(item(row));
    more.style.display = cursor ? 'block' : 'none';
  };

  const item = (row: TreebarsNotification): HTMLLIElement => {
    const card = cardOf(row);
    const unread = !row.read_at;
    const li = el('li', `position:relative;border-bottom:1px solid rgba(0,0,0,.06);${unread ? 'background:rgba(0,0,0,.025)' : ''}`);
    const open = el('button', `all:unset;box-sizing:border-box;display:flex;gap:12px;width:100%;padding:12px 40px 12px 14px;cursor:pointer;${card?.template === 'illustration' ? 'flex-direction:column' : ''}`);
    open.type = 'button';
    const image = card?.template === 'illustration' ? row.content.image_url : card?.icon_url || (card ? undefined : row.content.image_url);
    if (image) {
      const img = el('img', card?.template === 'illustration' ? `width:100%;border-radius:${Math.max(0, tokens.radius - 4)}px` : 'width:40px;height:40px;border-radius:8px;object-fit:cover;flex:none');
      img.src = image;
      img.alt = card?.image_alt ?? '';
      open.appendChild(img);
    }
    const words = el('div', 'min-width:0;flex:1');
    const head = el('div', 'display:flex;align-items:center;gap:6px');
    if (unread) {
      const dot = el('span', `width:8px;height:8px;border-radius:50%;background:${tokens.accent};flex:none`);
      dot.setAttribute('aria-label', 'Unread');
      head.appendChild(dot);
    }
    if (card?.pinned) head.appendChild(el('span', `font-size:11px;color:${tokens.on_surface_muted}`, 'Pinned'));
    if (row.content.title) head.appendChild(el('strong', 'font-weight:600', row.content.title));
    words.appendChild(head);
    if (row.content.body) words.appendChild(el('div', `color:${tokens.on_surface_muted};margin-top:2px`, row.content.body));
    words.appendChild(el('div', `font-size:12px;color:${tokens.on_surface_muted};margin-top:4px`, new Date(row.created_at).toLocaleString()));
    open.appendChild(words);
    open.addEventListener('click', () => {
      void host.markOpened(row.group_id);
      if (options.onOpen?.(row) === false) return;
      const to = destinationOf(row);
      if (to && typeof location !== 'undefined') location.assign(to);
    });
    /*
     * The card's own button, apart from a tap on the card: under the words, and a sibling of the
     * card's own control rather than inside it — a button inside a button is two taps on one press. It marks the card
     * opened as a tap does, and goes where the button says.
     */
    const cta = ctaOf(row);
    const button = cta
      ? el('button', `font:inherit;font-size:13px;font-weight:600;margin:0 14px 12px ${card?.template === 'illustration' ? '14px' : '66px'};padding:6px 12px;border:0;border-radius:${tokens.button_shape === 'pill' ? '999px' : `${Math.max(0, tokens.radius - 4)}px`};background:${tokens.accent};color:${tokens.on_accent};cursor:pointer`, cta.label)
      : null;
    if (button && cta) {
      button.type = 'button';
      button.addEventListener('click', () => {
        void host.markOpened(row.group_id);
        if (options.onOpen?.(row) === false) return;
        if (typeof location !== 'undefined') location.assign(cta.action.value);
      });
    }
    const remove = el('button', `position:absolute;top:8px;right:8px;border:0;background:none;font:18px/1 ${tokens.font_family};color:${tokens.on_surface_muted};cursor:pointer;padding:6px`, '×');
    remove.type = 'button';
    remove.setAttribute('aria-label', 'Remove');
    remove.addEventListener('click', () => {
      // A deeper page is not re-emitted, so a row dismissed from one is taken out here.
      deeper = deeper.filter((one) => one.group_id !== row.group_id);
      join();
      draw();
      void host.dismiss(row.group_id);
    });
    li.append(open, ...(button ? [button] : []), remove);
    return li;
  };

  const load = async (next: string | null) => {
    if (loading) return;
    loading = true;
    try {
      const page = await host.list({ cursor: next });
      if (next) deeper = [...deeper, ...page.notifications];
      else firstPage = page.notifications;
      join();
      cursor = page.nextCursor;
      draw();
    } finally {
      loading = false;
    }
  };
  more.addEventListener('click', () => void load(cursor));

  // A change to the first page (a mark, a dismissal, a refresh) replaces it; deeper pages are kept.
  const stop = host.onChange((page) => {
    firstPage = page.notifications;
    join();
    draw();
  });
  void load(null);

  return () => {
    stop();
    holder.remove();
  };
}
