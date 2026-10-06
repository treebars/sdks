import { expireSharedCookie, readCookieValues, writeSharedCookie } from './cookies';
import {
  DEVICE_ID_SHAPE,
  FETCH_SECRET_SHAPE,
  adoptStoredDevice,
  getDeviceId,
  getFetchSecret,
  readStoredDevice,
  type StoredDevice,
} from './storage';

/**
 * One device across a site's subdomains (`shareAcrossSubdomains`).
 *
 * The device id and its secret live in `localStorage`, which belongs to one origin — so `example.com` and
 * `app.example.com` would each mint their own, and one visitor in one browser would be two anonymous people. A device
 * is whatever presents the same id and proves it with the same secret, so two origins that hold the same pair are one
 * device, and the person behind it is one person.
 *
 * The pair is therefore also kept in a first-party cookie on the domain the subdomains share, and that cookie is the
 * device: an origin that finds one adopts it, and an origin that finds none offers its own. `localStorage` stays the
 * working copy, so a page whose cookie has gone still knows its device and puts the cookie back.
 *
 * **Two names, one per kind of write key.** `tbrs_dv_live` for a `pk_live_` key and `tbrs_dv_test` for a `pk_test_`
 * one, so a staging site and the production site it sits beside on one parent domain never become one device.
 *
 * **The cookie carries the secret.** It has to: the secret is what makes the id this browser's, and an origin holding
 * the id alone could not read its own in-app messages. A cookie a page sets can be read, and replaced, by scripts on
 * every subdomain of the domain it is set on, and is sent to those subdomains' servers — a wider audience than one
 * origin's storage has. Where every subdomain belongs to one owner, that audience is the owner, which is why sharing
 * is the default. A site on a parent domain it shares with sites it does not control turns it off.
 *
 * Unrelated domains are never joined: a browser sets no cookie across registrable domains, and nothing here tries to.
 */

/** The cookie's two names. */
export const SHARED_DEVICE_COOKIES = { live: 'tbrs_dv_live', test: 'tbrs_dv_test' } as const;

/** 400 days: the longest a browser keeps a cookie. Renewed at every `init`, so it runs from the last visit. */
const SHARED_DEVICE_SECONDS = 400 * 24 * 60 * 60;

/** The cookie a write key's device is shared in, or null for a key of neither kind, which is shared nowhere. */
function sharedDeviceCookie(writeKey: string): string | null {
  if (writeKey.startsWith('pk_live_')) return SHARED_DEVICE_COOKIES.live;
  if (writeKey.startsWith('pk_test_')) return SHARED_DEVICE_COOKIES.test;
  return null;
}

const encode = (device: StoredDevice): string => `${device.id}.${device.secret}`;

/**
 * `<device id>.<secret>`, each half in exactly the shape this SDK mints, or null.
 *
 * Strict because a cookie is somewhere every script on every subdomain can write: a value of any other shape — cut
 * short, edited, or put there by something else — is treated as no cookie at all and replaced, never adopted in part.
 * Neither shape contains a dot, so the first one is the separator.
 */
function decode(value: string): StoredDevice | null {
  const dot = value.indexOf('.');
  if (dot === -1) return null;
  const id = value.slice(0, dot);
  const secret = value.slice(dot + 1);
  return DEVICE_ID_SHAPE.test(id) && FETCH_SECRET_SHAPE.test(secret) ? { id, secret } : null;
}

/** The device the cookie holds: the first value under `name` that is one. */
function readSharedDevice(name: string): StoredDevice | null {
  for (const value of readCookieValues(name)) {
    const device = decode(value);
    if (device) return device;
  }
  return null;
}

/** The device `init` should report as, and whether this origin held a different one until now. */
export interface ClaimedDevice extends StoredDevice {
  changed: boolean;
}

/**
 * Settles which device this origin is, and leaves the cookie holding it for the next 400 days.
 *
 * - **A valid cookie is the device.** Where this origin held none, or another, it adopts the cookie's: the pair goes
 *   into `localStorage` and what the previous device left here is dropped (`adoptStoredDevice`).
 * - **No valid cookie:** this origin's own pair — the one it had, or one minted now — is offered as the cookie. Then
 *   the cookie is read back, because a page on another subdomain may have written between the look and the write; if
 *   theirs is what is there, theirs is adopted, so two pages starting together still end as one device.
 *
 * Call before any store is constructed, and only where the page may keep anything at all: `init` does not call it with
 * storage off or for a visitor who opted out.
 *
 * The answer is the pair to use, rather than a signal to read storage again: where `localStorage` will not hold
 * anything, the cookie alone still carries one device from page to page.
 */
export function claimSharedDevice(writeKey: string): ClaimedDevice {
  // Read before `own` below can mint one: a device minted in this call is not one this origin held.
  const before = readStoredDevice().id;
  const own = (): ClaimedDevice => ({ id: getDeviceId(true), secret: getFetchSecret(true), changed: false });
  const name = sharedDeviceCookie(writeKey);
  if (!name) return own();

  let shared = readSharedDevice(name);
  if (!shared) {
    const mine = own();
    /*
     * A pair in another shape — one stored by a much earlier version — is not offered: the cookie holds only what
     * would be accepted back from it. That origin keeps its device, and adopts a shared one when another origin
     * offers it.
     */
    if (!decode(encode(mine))) return mine;
    writeSharedCookie(name, encode(mine), SHARED_DEVICE_SECONDS);
    /*
     * Read back, whatever the write answered: nothing there is a browser that keeps no cookie, and this origin
     * carries on with its own device; this pair is the usual case; another pair is a page that wrote after the look
     * above, and is adopted below.
     */
    shared = readSharedDevice(name);
    // Compared as the one value the cookie holds, both halves at once.
    if (!shared || encode(shared) === encode(mine)) return mine;
  } else {
    // The same value again: what renews the cookie's lifetime, so it is counted from this visit.
    writeSharedCookie(name, encode(shared), SHARED_DEVICE_SECONDS);
  }

  adoptStoredDevice(shared);
  // An origin that held no device has not changed devices: this is its first.
  return { ...shared, changed: before !== null && before !== shared.id };
}

/**
 * Puts `device` in the cookie, replacing whatever it held: after a wipe, so every subdomain moves to the new device
 * at its next load instead of one of them offering the forgotten one again.
 */
export function shareDevice(writeKey: string, device: StoredDevice): void {
  const name = sharedDeviceCookie(writeKey);
  if (name && decode(encode(device))) writeSharedCookie(name, encode(device), SHARED_DEVICE_SECONDS);
}

/**
 * Expires the device cookie everywhere it could have been set. With a write key, that key's cookie; with none — a
 * wipe asked for before `init`, when no key is known — both.
 */
export function forgetSharedDevice(writeKey?: string): void {
  const names = writeKey === undefined ? Object.values(SHARED_DEVICE_COOKIES) : [sharedDeviceCookie(writeKey)];
  for (const name of names) if (name) expireSharedCookie(name);
}
