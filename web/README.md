# @treebars/web-sdk

The browser SDK for [Treebars](https://treebars.com): events, identity, in-app messages and web push.

```bash
npm install @treebars/web-sdk
```

```ts
import treebars from '@treebars/web-sdk';

treebars.init({ writeKey: 'pk_live_…' });

treebars.track('signup_completed', { plan: 'pro' });
treebars.identify('user_123', { email: 'ada@example.com' });
```

Your write key is on the dashboard's Data → Setup page, which also shows this snippet with the key filled in.

## Web push

Serve `treebars-sw.js` from this package at your site's root (`https://yoursite.com/treebars-sw.js`), or
`importScripts('/treebars-sw.js')` from a service worker you already have. It only draws pushes that carry a
Treebars payload, so it leaves any other push your site sends alone.

## Documentation

[treebars.com/docs](https://treebars.com/docs)

## License

MIT
