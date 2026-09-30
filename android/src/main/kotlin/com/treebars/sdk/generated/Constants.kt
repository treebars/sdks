// Generated from the values every Treebars SDK shares. Do not edit.
//
// Treebars' build regenerates this file and fails when it and its source disagree,
// so a hand-edit here is caught rather than shipped.

package com.treebars.sdk.generated

internal object TreebarsConstants {
    const val EVENTS_PATH = "/v1/events"
    const val IDENTIFY_PATH = "/v1/identify"
    const val IN_APP_PATH = "/v1/in-app"
    const val IN_APP_BODY_PATH = "/v1/in-app/body"
    const val IN_APP_REWARD_PATH = "/v1/in-app/reward"
    const val CONTEXT_TOKEN_PATH = "/v1/context-token"
    const val NOTIFICATIONS_PATH = "/v1/notifications"
    const val NOTIFICATION_STATE_PATH = "/v1/notifications/state"

    const val WRITE_KEY_HEADER = "X-Treebars-Key"
    const val DEVICE_AUTH_HEADER = "X-Treebars-Device-Auth"
    const val TRIGGERS_VERSION_HEADER = "X-Treebars-Triggers-Version"
    const val LINK_RESOLVE_HEADER = "X-Treebars-Resolve"
    const val USER_SIGNATURE_HEADER = "X-Treebars-User-Signature"
    const val USER_ID_HEADER = "X-Treebars-User-Id"

    const val BATCH_SIZE = 50
    const val DRAIN_MAX_BATCHES = 10
    /** Seconds. A retry waits random(0, min(cap, base * 2^attempt)). */
    const val BACKOFF_BASE_SECONDS = 2L
    const val BACKOFF_CAP_SECONDS = 60L
    val RETRY_AFTER_STATUSES = intArrayOf(429, 503)
    /** Seconds. */
    const val RETRY_AFTER_MAX_SECONDS = 3600L
    val AUTH_STATUSES = intArrayOf(401, 403)
    /** Seconds. */
    const val AUTH_COOLDOWN_SECONDS = 3600L
    const val QUEUE_CAP = 1000
    const val SESSION_TIMEOUT_MS = 1800000L
    const val CONTEXT_REPORT_TTL_MS = 7L * 24 * 60 * 60 * 1000
    const val DEFAULT_FLUSH_INTERVAL_MS = 30000L
    /** How soon after a listed event its flush goes out. Armed by the first, not moved by later ones. */
    const val TRIGGER_FLUSH_DEBOUNCE_MS = 1000L
    const val DEFAULT_IN_APP_POLL_INTERVAL_MS = 900000L
    const val IN_APP_PRESENTATION_HOLD_MS = 30000L
    /** A reward claim refused with a 429 or 503, or unanswered, is asked again this many times, all within the budget. */
    const val REWARD_CLAIM_RETRIES = 2
    const val REWARD_CLAIM_BUDGET_MS = 8000L

    /** 0x811c9dc5 does not fit a signed Int. */
    const val FNV_OFFSET_BASIS = -0x7ee3623b
    const val FNV_PRIME = 0x01000193

    const val DELIVERY_ID_KEY = "treebars_delivery_id"
    const val CAMPAIGN_ID_KEY = "treebars_campaign_id"
    const val IN_APP_BUTTON_INDEX_KEY = "button_index"
    const val IN_APP_BUTTON_LABEL_KEY = "button_label"
    /** How many actions an Android notification draws; the SDK stops there. */
    const val PUSH_ANDROID_ACTION_SLOTS = 3
    const val PUSH_PERMISSION_LINK = "treebars://push-permission"

    /* A push the SDK draws: its data keys, as Treebars sends them. */
    const val RICH_PUSH_RENDER_KEY = "treebars_render"
    const val RICH_PUSH_TITLE_KEY = "treebars_title"
    const val RICH_PUSH_BODY_KEY = "treebars_body"
    const val RICH_PUSH_IMAGE_KEY = "treebars_image"
    const val RICH_PUSH_DEEP_LINK_KEY = "deep_link"
    const val RICH_PUSH_BUTTONS_KEY = "treebars_buttons"
    const val RICH_PUSH_CAROUSEL_KEY = "treebars_carousel"
    const val RICH_PUSH_MEDIA_KEY = "treebars_media"
    const val RICH_PUSH_OPTIONS_KEY = "treebars_options"
    const val RICH_PUSH_BUTTON_ID_KEY = "treebars_button_id"
    const val RICH_PUSH_TEMPLATE_KEY = "treebars_template"
    const val RICH_PUSH_BACKGROUND_KEY = "treebars_background"

    /*
     * Deferred deep linking. The referrer is where a destination survives an install on Android;
     * the iPhone's arrives through the handoff instead, and Swift's block carries the click id's
     * parameter too because that core reads the URL itself.
     */
    const val DEEP_LINK_PARAM = "tbrs_deep_link"
    const val MAX_DEEP_LINK_PATH_LENGTH = 512
    const val DEFERRED_DEEP_LINK_WINDOW_MS = 24L * 60 * 60 * 1000

    /** The evidence event a link opening an already-installed app sends. */
    const val LINK_OPENED_EVENT = "link_opened"
    /** Our click id's parameter, read out of the URL that opened the app. */
    const val ACQUISITION_CLICK_ID_PARAM = "tbrs_click_id"

    const val SDK_VERSION = "0.3.0"
    const val SDK_NAME = "treebars-android"
    const val DEVICE_ID_PREFIX = "dev_"

    val RESERVED_EVENT_NAMES = arrayOf(
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
        "experience_viewed",
        "experience_clicked",
        "experience_converted",
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
    )

    // The condition operator codes, and only the codes: what each one means is the evaluator's.
    val FILTER_OPERATOR_CODES = arrayOf(
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
    )

    // The one number grammar every engine reads typed-number text with; match the WHOLE input.
    const val NUMBER_GRAMMAR = "^[+-]?([0-9]+\\.?[0-9]*|\\.[0-9]+)([eE][+-]?[0-9]+)?\$"
    // The most items a stored condition list holds.
    const val LIST_MAX = 50
    // Ingest's caps, in UTF-16 code units: a trimmed device field, and a screen name.
    const val DEVICE_FIELD_LENGTH = 128
    const val STRING_VALUE_LENGTH = 1024

    // The dimension names an in-app trigger may read: an allowlist of keys, and nothing about what a row answers.
    val IN_APP_DIMENSIONS = arrayOf(
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
    )

    // The push-permission states the app can still ask from: a message shown only then is held back from every other.
    val PUSH_ASKABLE_STATUSES = setOf("not_determined", "provisional", "denied_askable")

    // Storage keys are per platform and are NOT shared values. Agreement across platforms is the
    // failure mode: a changed key does not migrate anything, it points this SDK at an empty address
    // and every install in the field silently becomes a new anonymous device.
    const val PREFS_FILE = "treebars.prefs"
    const val QUEUE_FILE = "treebars-queue.json"
    const val UPLOADER_FILE = "treebars-uploader.json"
    const val TRIGGERS_FILE = "treebars-triggers.json"
    const val KEY_FIRST_SEEN_AT = "first_seen_at"
    const val KEY_DEVICE_ID = "device_id"
    const val KEY_FETCH_SECRET = "fetch_secret"
    const val KEY_IDENTIFIED_USER = "identified_user"
    const val KEY_SIGNED_IN_USER = "signed_in_user"
    const val KEY_SIGNED_IN_USER_SIGNATURE = "signed_in_user_signature"
    const val KEY_DEVICE_CONTEXT_HASH = "device_context_hash"
    const val KEY_SESSION_ID = "session_id"
    const val KEY_SESSION_STARTED_AT = "session_started_at"
    const val KEY_SESSION_LAST_ACTIVITY_AT = "session_last_activity_at"
    const val KEY_SESSION_EVENT_COUNT = "session_event_count"
    const val KEY_SESSION_EVER_STARTED = "session_ever_started"
    const val KEY_IN_APP_QUEUE = "in_app_queue"
    const val KEY_IN_APP_LEDGER = "in_app_ledger"
    const val KEY_NOTIFICATIONS = "notifications"
    const val KEY_NOTIFICATION_LEDGER = "notification_ledger"
    const val KEY_NOTIFICATION_PERMISSION = "notification_permission"
    const val KEY_ACQUISITION_PENDING = "acquisition_pending"
    const val KEY_DEFERRED_DEEP_LINK = "deferred_deep_link"
}
