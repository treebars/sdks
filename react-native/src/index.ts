import treebars from './Treebars';

export default treebars;
export * from './types';
export { TreebarsSDK } from './Treebars';

export type {
  InAppBodyMode,
  InAppButton,
  InAppContent,
  InAppHtmlAction,
  InAppMessage,
  InAppShape,
  InAppTokens,
  InAppTrigger,
} from './InApp';
/*
 * Exported because a host app draws the message and therefore has to read it the same way
 * this SDK does. `layout` alone stopped answering "where does this go" when custom HTML
 * became a body rather than a shape, and `treebars://` is the only channel sandboxed
 * markup has back into the SDK — an app parsing either by hand gets it subtly wrong.
 */
export { inAppBodyMode, inAppHtmlDocument, inAppShape, readInAppHtmlAction } from './InApp';
export type { InAppRenderer } from './Treebars';

/*
 * The notification centre's row types live in `types.ts`, which `export * from './types'` above
 * already covers. Public for the same reason as the in-app types: this SDK draws no list, so
 * every field a FlatList reads has to be nameable from outside it.
 */
