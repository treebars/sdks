// Generated from the values every Treebars SDK shares. Do not edit.
//
// Treebars' build regenerates this file and fails when it and its source disagree,
// so a hand-edit here is caught rather than shipped.

import Foundation

enum TreebarsConstants {
    static let eventsPath = "/v1/events"
    static let identifyPath = "/v1/identify"
    static let inAppPath = "/v1/in-app"
    static let inAppBodyPath = "/v1/in-app/body"
    static let inAppRewardPath = "/v1/in-app/reward"
    static let contextTokenPath = "/v1/context-token"
    static let notificationsPath = "/v1/notifications"
    static let notificationStatePath = "/v1/notifications/state"
    static let handoffPath = "/v1/handoff"

    static let writeKeyHeader = "X-Treebars-Key"
    static let deviceAuthHeader = "X-Treebars-Device-Auth"
    static let triggersVersionHeader = "X-Treebars-Triggers-Version"
    static let flushSpacingHeader = "X-Treebars-Flush-Ms"
    static let linkResolveHeader = "X-Treebars-Resolve"
    static let userSignatureHeader = "X-Treebars-User-Signature"
    static let userIdHeader = "X-Treebars-User-Id"

    static let batchSize = 50
    static let drainMaxBatches = 10
    /// Seconds. A retry waits random(0, min(cap, base * 2^attempt)).
    static let backoffBase: TimeInterval = 2
    static let backoffCap: TimeInterval = 60
    static let retryAfterStatuses: Set<Int> = [429, 503]
    static let retryAfterMax: TimeInterval = 3600
    static let authStatuses: Set<Int> = [401, 403]
    static let authCooldown: TimeInterval = 3600
    static let queueCap = 1000
    /// Seconds on iOS, where the other three hold milliseconds. Self-consistent, and frozen.
    static let sessionTimeout: TimeInterval = 1800
    static let contextReportTtl: TimeInterval = 7 * 24 * 60 * 60
    /// How long a device's description has stood before it is reported again: what the app sets beside its start is in it by then.
    static let contextSettle: TimeInterval = 2
    static let defaultFlushInterval: TimeInterval = 30
    /// How soon after a listed event its flush goes out. Armed by the first, not moved by later ones.
    static let triggerFlushDebounce: TimeInterval = 1
    /// How soon after any event its flush goes out, when nothing was uploaded within the spacing.
    static let flushDebounce: TimeInterval = 1
    /// The least time between two uploads while busy: the default, on a metered network, and under a test key.
    static let flushSpacing: TimeInterval = 5
    static let flushSpacingMetered: TimeInterval = 15
    static let flushSpacingTest: TimeInterval = 1
    /// The bounds on the spacing a response may name.
    static let flushSpacingMin: TimeInterval = 1
    static let flushSpacingMax: TimeInterval = 60
    static let defaultInAppPollInterval: TimeInterval = 900
    static let inAppPresentationHold: TimeInterval = 30
    /// Attempts at Apple's AdServices endpoint, each wait drawn by `jitterMs`. iOS only: nothing
    /// else has an AdServices token to spend them on.
    static let adServicesRetryAttempts = 5
    /// A reward claim refused with a 429 or 503, or unanswered, is asked again this many times, all within the budget.
    static let rewardClaimRetries = 2
    static let rewardClaimBudget: TimeInterval = 8

    static let fnvOffsetBasis: UInt32 = 0x811c9dc5
    static let fnvPrime: UInt32 = 0x01000193

    static let deliveryIdKey = "treebars_delivery_id"
    static let campaignIdKey = "treebars_campaign_id"
    static let inAppButtonIndexKey = "button_index"
    static let inAppButtonLabelKey = "button_label"
    static let pushPermissionLink = "treebars://push-permission"

    /* A push the SDK draws: its data keys, as Treebars sends them. */
    static let richPushRenderKey = "treebars_render"
    static let richPushTitleKey = "treebars_title"
    static let richPushBodyKey = "treebars_body"
    static let richPushImageKey = "treebars_image"
    static let richPushDeepLinkKey = "deep_link"
    static let richPushButtonsKey = "treebars_buttons"
    static let richPushCarouselKey = "treebars_carousel"
    static let richPushMediaKey = "treebars_media"
    static let richPushOptionsKey = "treebars_options"
    static let richPushButtonIdKey = "treebars_button_id"
    static let richPushTemplateKey = "treebars_template"
    static let richPushBackgroundKey = "treebars_background"

    /*
     * The handoff and the destination it carries. Android reads its pair out of the Play referrer;
     * the iPhone reads a URL the person carried across the App Store, so it needs the click id's
     * parameter name as well — the one value Android never parses for itself.
     */
    static let clickIdParam = "tbrs_click_id"
    /** The evidence event a link opening an already-installed app sends. */
    static let linkOpenedEvent = "link_opened"
    static let handoffProperty = "tbrs_handoff"
    static let deepLinkParam = "tbrs_deep_link"
    static let maxDeepLinkPathLength = 512
    static let deferredDeepLinkWindowMs: Int64 = 24 * 60 * 60 * 1000

    static let sdkVersion = "0.5.0"
    static let sdkName = "treebars-ios"
    static let deviceIdPrefix = "dev_"

    static let reservedEventNames = [
        "session_start",
        "session_end",
        "app_open",
        "app_background",
        "app_foreground",
        "screen_view",
        "page_view",
        "notification_received",
        "notification_opened",
        "push_dismissed",
        "user_identified",
        "user_signed_out",
        "traits_set",
        "device_context",
        "app_uninstall",
        "flow_exited",
        "flow_entered",
        "in_app_displayed",
        "in_app_clicked",
        "in_app_dismissed",
        "in_app_form_submitted",
        "in_app_failed",
        "sms_received",
        "whatsapp_received",
        "notification_read",
        "notification_dismissed",
        "notification_permission_changed",
        "whatsapp_opt_in",
        "install_referrer",
        "apple_ads_attribution",
        "install_attributed",
        "link_opened",
        "reengagement_attributed",
    ]

    // The condition operator codes, and only the codes: what each one means is the evaluator's.
    static let filterOperatorCodes = [
        "eq",
        "neq",
        "contains",
        "not_contains",
        "starts_with",
        "ends_with",
        "in",
        "not_in",
        "gt",
        "gte",
        "lt",
        "lte",
        "exists",
        "not_exists",
    ]

    // The one number grammar every engine reads typed-number text with; match the WHOLE input. A raw string,
    // so the pattern's backslashes reach NSRegularExpression as written.
    static let numberGrammar = #"^[+-]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][+-]?[0-9]+)?$"#
    // The most items a stored condition list holds.
    static let listMax = 50
    // Ingest's caps, in UTF-16 code units: a trimmed device field, and a screen name.
    static let deviceFieldLength = 128
    static let stringValueLength = 1024

    // The dimension names an in-app trigger may read: an allowlist of keys, and nothing about what a row answers.
    static let inAppDimensions = [
        "platform_type",
        "os_name",
        "os_version",
        "device_manufacturer",
        "device_model",
        "device_type",
        "app_version",
        "app_build",
        "sdk_name",
        "sdk_version",
        "locale",
        "timezone",
        "network_type",
        "screen_name",
    ]

    // The push-permission states the app can still ask from: a message shown only then is held back from every other.
    static let pushAskableStatuses: Set<String> = ["not_determined", "provisional", "denied_askable"]

    // Storage keys are per platform and are NOT shared values. Agreement across platforms is the
    // failure mode: a changed key does not migrate anything, it points this SDK at an empty address
    // and every install in the field silently becomes a new anonymous device.
    static let queueFile = "treebars-queue.json"
    static let uploaderFile = "treebars-uploader.json"
    static let triggersFile = "treebars-triggers.json"
    static let keyDeviceId = "treebars.device_id"
    static let keyDeviceContextHash = "treebars.device_context_hash"
    static let keyFetchSecret = "treebars.fetch_secret"
    static let keyFirstSeenAt = "treebars.first_seen_at"
    static let keyIdentifiedUser = "treebars.identified_user"
    static let keySignedInUser = "treebars.signed_in_user"
    static let keySignedInUserSignature = "treebars.signed_in_user_signature"
    static let keySessionId = "treebars.session.id"
    static let keySessionStartedAt = "treebars.session.started_at"
    static let keySessionLastActivity = "treebars.session.last_activity"
    static let keySessionEventCount = "treebars.session.event_count"
    static let keySessionEverStarted = "treebars.session.ever_started"
    static let keyInAppQueue = "treebars.in_app_queue"
    static let keyInAppLedger = "treebars.in_app_ledger"
    static let keyNotifications = "treebars.notifications"
    static let keyNotificationLedger = "treebars.notification_ledger"
    static let keyNotificationPermission = "treebars.notification_permission"
    static let keyAcquisitionPending = "treebars.acquisition_pending"
    static let keyDeferredDeepLink = "treebars.deferred_deep_link"
}
