// Generated from the values every Treebars SDK shares. Do not edit.
//
// Treebars' build regenerates this file and fails when it and its source disagree,
// so a hand-edit here is caught rather than shipped.
//
// Only the values the bridge itself needs. Endpoints, headers, retry and session policy belong to
// the native SDKs this package wraps, and a copy of them in Dart would be a policy nothing reads.
//
// `sdkVersion` is this package's version, which is also the version of the native SDKs it pins
// (android/build.gradle and the podspec): a wrapper and its cores that disagree about which SDK
// they are cannot be told apart in any report.

/// Stamped on every event this app sends, so a Flutter install is told apart from a native one.
const String sdkName = 'treebars-flutter';

/// The version of this package and of the native SDKs it pins.
const String sdkVersion = '0.12.3';

/// The names `Treebars.on` accepts, as the native SDKs deliver them.
const List<String> eventNames = <String>[
  'pushClicked',
  'pushOpened',
  'inAppCampaignShown',
  'inAppCampaignClicked',
  'inAppCampaignDismissed',
  'inAppCampaignCustomAction',
  'inAppCampaignSelfHandled',
];

/// How long `configReady` waits when the app names no timeout.
const int configReadyTimeoutMs = 2000;
