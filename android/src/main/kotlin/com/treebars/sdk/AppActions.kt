package com.treebars.sdk

import com.treebars.sdk.generated.TreebarsConstants

/*
 * App actions: a named action and a small JSON payload, fired from a tap — an element of an in-app message, a push or
 * one of its buttons — which the app subscribes to by name with [Treebars.onAction].
 *
 * Every Treebars SDK runs this same dispatcher, held to the shared cases in `app-action-scenarios.json`:
 * - an action goes to every handler subscribed to its name and to every catch-all, in the order they subscribed;
 * - one that nothing has subscribed to yet is held for a few seconds, at most a handful at a time, and handed to the
 *   first handler that subscribes for it — so the tap that opened the app reaches the screen that subscribes once it is
 *   built, and a React Native app, whose handlers subscribe from JavaScript, misses nothing;
 * - once its fate is known it is recorded as `app_action` with `handled` true or false, the name and where it came from,
 *   and never the payload, which can carry a person's own ids. A preview's actions are handed over and never recorded.
 */

/** Where an action came from: [kind] is `in_app`, `push` or `card`; the campaign and the message, when there are. */
data class AppActionSource(
    val kind: String,
    val campaignId: String? = null,
    val messageId: String? = null,
)

/**
 * What a handler receives: the action's [name] (`add_to_cart`, `cart.open`, or the built-in `navigate`), its [payload]
 * as JSON values — strings, numbers, booleans, null, lists and maps; `{ screen, props }` for `navigate` — and its
 * [source].
 */
data class AppAction(
    val name: String,
    val payload: Map<String, Any?>,
    val source: AppActionSource,
)

/** An app's answer to an action. Called on the main thread. */
fun interface AppActionHandler {
    fun onAction(action: AppAction)
}

/** What [Treebars.onAction] returns: [cancel] stops the handler being called. Cancelling twice does nothing. */
fun interface AppActionSubscription {
    fun cancel()
}

/**
 * The dispatcher. Main thread only; the scheduler is handed in so a test can run the clock.
 */
internal class AppActions(
    private val track: (String, Map<String, Any?>) -> Unit,
    /** Runs the work after a delay, and returns what [cancel] takes. */
    private val later: (Long, () -> Unit) -> Any,
    private val cancelLater: (Any) -> Unit,
    private val log: (String) -> Unit = {},
) {
    private class Subscription(val name: String?, val handler: AppActionHandler)

    private class Held(val action: AppAction, val record: Boolean) {
        var timer: Any? = null
    }

    private val subscriptions = mutableListOf<Subscription>()
    private val held = mutableListOf<Held>()

    /** Subscribes to one action by name, or every action when [name] is null, and hands over what is held for it. */
    fun on(name: String?, handler: AppActionHandler): AppActionSubscription {
        val subscription = Subscription(name, handler)
        subscriptions.add(subscription)
        for (entry in held.filter { name == null || it.action.name == name }) {
            held.remove(entry)
            entry.timer?.let(cancelLater)
            deliver(entry.action, listOf(subscription), entry.record)
        }
        return AppActionSubscription { subscriptions.remove(subscription) }
    }

    /** Hands an action to the handlers subscribed to it, or holds it until one subscribes. */
    fun fire(action: AppAction, record: Boolean = true) {
        val handlers = subscriptions.filter { it.name == null || it.name == action.name }
        if (handlers.isNotEmpty()) {
            deliver(action, handlers, record)
            return
        }
        val entry = Held(action, record)
        entry.timer = later(TreebarsConstants.APP_ACTION_HOLD_MS) { letGo(entry) }
        held.add(entry)
        // More held than the hold keeps lets the oldest go: a burst of taps nothing listens to is not a queue to replay.
        while (held.size > TreebarsConstants.APP_ACTION_HOLD_MAX) {
            val oldest = held.first()
            oldest.timer?.let(cancelLater)
            letGo(oldest)
        }
    }

    /** Lets go of everything held, unrecorded: the person who tapped has signed out, or in-app is turned off. */
    fun clear() {
        held.forEach { entry -> entry.timer?.let(cancelLater) }
        held.clear()
    }

    private fun deliver(action: AppAction, handlers: List<Subscription>, record: Boolean) {
        for (subscription in handlers.toList()) {
            // A handler that throws still received the action; the next one still runs.
            runCatching { subscription.handler.onAction(action) }
                .onFailure { log("onAction handler for \"${action.name}\" threw: $it") }
        }
        if (record) record(action, true)
    }

    private fun letGo(entry: Held) {
        if (!held.remove(entry)) return
        if (entry.record) record(entry.action, false)
    }

    private fun record(action: AppAction, handled: Boolean) {
        val properties = linkedMapOf<String, Any?>(
            TreebarsConstants.APP_ACTION_NAME_KEY to action.name,
            TreebarsConstants.APP_ACTION_HANDLED_KEY to handled,
            TreebarsConstants.APP_ACTION_SOURCE_KEY to action.source.kind,
        )
        action.source.campaignId?.takeIf { it.isNotEmpty() }?.let { properties[TreebarsConstants.CAMPAIGN_ID_KEY] = it }
        action.source.messageId?.takeIf { it.isNotEmpty() }?.let { properties[TreebarsConstants.DELIVERY_ID_KEY] = it }
        track(TreebarsConstants.APP_ACTION_EVENT, properties)
    }

    companion object {
        /** What an action may be called: lower-case letters, digits, dots and underscores, starting with a letter. */
        val NAME = Regex(TreebarsConstants.APP_ACTION_NAME_PATTERN)
    }
}
