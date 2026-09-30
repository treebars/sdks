/*
 * The Treebars web push service worker.
 *
 * It receives the web pushes Treebars sends to this browser, draws them as notifications, and, when one is clicked,
 * opens its page so the Treebars SDK there can report the open.
 *
 * INSTALLING IT — do one of these:
 *
 *   1. You have no service worker yet. Copy this file, unchanged, to your site's root, so that it is served at
 *      https://yoursite.com/treebars-sw.js. At the root it can receive pushes for every page of your site. This is the
 *      path the SDK registers by default.
 *
 *   2. You already have a service worker. Serve this file at /treebars-sw.js and add this line to your worker:
 *
 *        importScripts('/treebars-sw.js');
 *
 *      Then tell the SDK where your own worker is, so it registers that one: pass `serviceWorkerPath: '/your-sw.js'`
 *      to `treebars.push.subscribe()` or `treebars.push.prompt()`.
 *
 *   Either way, serve it from your own origin. A browser fetches a service worker by itself, from the site it runs on,
 *   so this is a plain script with no build step and no imports. Keep it that way if you change it.
 *
 * SUBSCRIBING A BROWSER — from your pages, not from this file:
 *
 *   treebars.push.subscribe({ vapidPublicKey })   // call it from a click: browsers refuse an unprompted request
 *   treebars.push.prompt({ vapidPublicKey })      // or show a soft prompt in your own words first
 *
 *   The VAPID public key is on your web push channel in the Treebars dashboard.
 *
 * WHAT IT HANDLES, AND WHAT IT LEAVES ALONE:
 *
 *   - It draws a notification only for a push whose payload carries a `treebars` object. Any other push your site sends
 *     is left to your own code.
 *   - On a click it opens the notification's page, or the page of the button that was pressed. For a page on your own
 *     site it adds `treebars_delivery_id` (with `treebars_campaign_id` and `treebars_button_id` when there are any) to
 *     the address; the SDK on that page reports `notification_opened` and removes them from the address bar. A page on
 *     another site is opened but the click is not counted there.
 *   - When the browser replaces a subscription, it subscribes again with the same key; the SDK on the next page that
 *     loads registers the new one with Treebars.
 */
(function () {
  var DELIVERY = 'treebars_delivery_id';
  var CAMPAIGN = 'treebars_campaign_id';
  var BUTTON = 'treebars_button_id';
  var AUTO_DISMISS_MS = 8000;

  self.addEventListener('push', function (event) {
    var payload = null;
    try {
      payload = event.data ? event.data.json() : null;
    } catch (error) {
      payload = null;
    }
    var push = payload && payload.treebars;
    if (!push) return;
    var options = {
      body: push.body || '',
      data: push,
      requireInteraction: push.sticky === true,
    };
    if (push.icon) options.icon = push.icon;
    // The small monochrome icon Chrome on Android puts in the status bar.
    if (push.badge) options.badge = push.badge;
    if (push.image) options.image = push.image;
    if (push.tag) {
      options.tag = push.tag;
      options.renotify = true;
    }
    if (push.actions) options.actions = push.actions.map(function (action) {
      var drawn = { action: action.id, title: action.title };
      // A button's own icon: Chrome draws it beside the label, other browsers ignore it.
      if (action.icon) drawn.icon = action.icon;
      return drawn;
    });
    var shown = self.registration.showNotification(push.title || '', options);
    /*
     * Auto-dismiss: the notification is closed after 8 seconds. The wait is held inside `waitUntil`, which is what keeps
     * a worker alive — a browser may end an idle worker well before a longer timer fires, so 8 seconds is the wait this
     * can keep, whatever duration the message sets for Android. Only this notification is closed: the ones sharing its
     * tag are checked for its delivery id.
     */
    if (push.auto_dismiss) {
      shown = shown.then(function () {
        return new Promise(function (resolve) {
          setTimeout(resolve, AUTO_DISMISS_MS);
        });
      }).then(function () {
        return self.registration.getNotifications(push.tag ? { tag: push.tag } : undefined);
      }).then(function (notifications) {
        for (var i = 0; i < notifications.length; i += 1) {
          var data = notifications[i].data || {};
          var mine = data.data && push.data && data.data[DELIVERY] === push.data[DELIVERY];
          if (mine) notifications[i].close();
        }
      });
    }
    event.waitUntil(shown);
  });

  /*
   * The browser retired this subscription: an expired endpoint, or a push service rotating its keys. It is subscribed
   * afresh with the same key, so the browser stays reachable, and the SDK on the next page of this site notices the new
   * endpoint and registers it — a worker holds no write key and no device id, so the page is where registration happens.
   * `oldSubscription` may be absent; then there is no key to reuse, and the site's own `subscribe()` is the way back.
   */
  self.addEventListener('pushsubscriptionchange', function (event) {
    var previous = event.oldSubscription;
    if (!previous || !previous.options || !previous.options.applicationServerKey) return;
    event.waitUntil(
      self.registration.pushManager.subscribe({
        userVisibleOnly: true,
        applicationServerKey: previous.options.applicationServerKey,
      }),
    );
  });

  self.addEventListener('notificationclick', function (event) {
    var push = event.notification.data || {};
    event.notification.close();
    var target = push.url || '/';
    var button = null;
    if (event.action && push.actions) {
      for (var i = 0; i < push.actions.length; i += 1) {
        if (push.actions[i].id === event.action) {
          button = push.actions[i];
          target = button.url || target;
        }
      }
    }
    var url = new URL(target, self.location.origin);
    var data = push.data || {};
    // Only a page of this site can report the click: another site does not run this site's Treebars SDK.
    if (url.origin === self.location.origin && data[DELIVERY]) {
      url.searchParams.set(DELIVERY, data[DELIVERY]);
      if (data[CAMPAIGN]) url.searchParams.set(CAMPAIGN, data[CAMPAIGN]);
      if (button) url.searchParams.set(BUTTON, button.id);
    }
    event.waitUntil(self.clients.openWindow(url.href));
  });
})();
