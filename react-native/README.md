# @treebars/react-native-sdk

The React Native SDK for [Treebars](https://treebars.com): events, identity, sessions, in-app messages, push and the
notification centre. A TurboModule over the Treebars iOS and Android SDKs, for React Native 0.76 and later with the
New Architecture.

```bash
npm install @treebars/react-native-sdk
cd ios && pod install
```

```ts
import treebars from '@treebars/react-native-sdk';

await treebars.init({ write_key: 'pk_live_…' });

await treebars.track('signup_completed', { plan: 'pro' });
await treebars.user({ id: 'user_123', email: 'ada@example.com' });
```

Your write key is on the dashboard's Data → Setup page, which shows this snippet with the key filled in.

## Documentation

[treebars.com/docs](https://treebars.com/docs)

## License

MIT
