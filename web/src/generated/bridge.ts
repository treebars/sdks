// Generated from the in-app bridge every Treebars SDK hosts. Do not edit.
//
// Treebars' build regenerates this file and fails when it and its source disagree.

/** The bridge this SDK hosts; `getContext().bridgeVersion`. */
export const BRIDGE_VERSION = 1;

/** Every method this SDK answers, the public ones and the shim's own. The handler table is typed against it. */
export const BRIDGE_HOST_METHODS = [
  "dismissMessage",
  "trackDismiss",
  "trackClick",
  "trackRating",
  "trackEvent",
  "identifyUser",
  "setUniqueId",
  "setAlias",
  "setEmailId",
  "setMobileNumber",
  "setUserName",
  "setFirstName",
  "setLastName",
  "setGender",
  "setBirthDate",
  "setUserLocation",
  "setUserAttribute",
  "setUserAttributeDate",
  "setUserAttributeLocation",
  "navigateToScreen",
  "openDeepLink",
  "openRichLanding",
  "openWebURL",
  "copyText",
  "call",
  "sms",
  "share",
  "customAction",
  "requestNotificationPermission",
  "showPushOptIn",
  "handleNotificationPopUp",
  "getContext",
  "claimReward",
  "resize",
  "getStoredValue",
  "setStoredValue",
  "_ready",
  "_screen",
  "_complete",
  "_quiz",
  "_submit",
  "_link",
  "_key",
  "_alert"
] as const;

export type BridgeHostMethod = (typeof BRIDGE_HOST_METHODS)[number];

/** The page-side shim, one expression: call it with `{ host, nonce }` inside the message's frame, before its own scripts. */
export const BRIDGE_SHIM = "(function(f){\"use strict\";if(window.treebars)return;var a=f.host;var s=f.nonce;var v=[\"dismissMessage\",\"trackDismiss\",\"trackClick\",\"trackRating\",\"trackEvent\",\"identifyUser\",\"setUniqueId\",\"setAlias\",\"setEmailId\",\"setMobileNumber\",\"setUserName\",\"setFirstName\",\"setLastName\",\"setGender\",\"setBirthDate\",\"setUserLocation\",\"setUserAttribute\",\"setUserAttributeDate\",\"setUserAttributeLocation\",\"navigateToScreen\",\"openDeepLink\",\"openRichLanding\",\"openWebURL\",\"copyText\",\"call\",\"sms\",\"share\",\"customAction\",\"requestNotificationPermission\",\"showPushOptIn\",\"handleNotificationPopUp\",\"navigateToNotificationSettings\",\"navigateToSettings\",\"getContext\",\"claimReward\",\"requestStoreReview\",\"resize\",\"getStoredValue\",\"setStoredValue\",\"_ready\",\"_screen\",\"_complete\",\"_quiz\",\"_submit\",\"_link\",\"_key\",\"_alert\"];var w=[\"showScreen\",\"nextScreen\",\"previousScreen\",\"setState\",\"getState\",\"submitForm\"];var h=0;var u={};var i=null;function S(e){var t=JSON.stringify(e);if(a===\"android\")window.TreebarsBridge.postMessage(t);else if(a===\"ios\")window.webkit.messageHandlers.treebars.postMessage(t);else window.parent.postMessage(t,\"*\")}function o(e,t){return new Promise(function(n){var d=++h;u[d]=n;try{S({tb:s,id:d,method:e,args:t})}catch(E){delete u[d];n({ok:false,reason:\"no_host\"})}})}function l(e){if(!e||e.tb!==s||typeof e.reply!==\"number\")return;var t=u[e.reply];if(!t)return;delete u[e.reply];t(e.result)}window.addEventListener(\"message\",function(e){if(a!==\"web\"||e.source!==window.parent)return;var t=e.data;try{if(typeof t===\"string\")t=JSON.parse(t)}catch(n){return}if(t&&t.tb===s&&t.focus===true){_();return}if(t&&t.tb===s&&typeof t.orientation===\"string\"){m(t.orientation);return}l(t)});function m(e){if(e!==\"portrait\"&&e!==\"landscape\")return;var t=document.getElementById(\"tb-orientation\");if(!t){t=document.createElement(\"style\");t.id=\"tb-orientation\";(document.head||document.documentElement).appendChild(t)}t.textContent='[data-tb-orientation]:not([data-tb-orientation~=\"'+e+'\"]){display:none!important}'}function _(){var e=document.querySelectorAll('[autofocus], button:not([disabled]), [href], input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex=\"-1\"])');for(var t=0;t<e.length;t+=1){if(e[t].getClientRects().length>0){e[t].focus();return}}}if(a===\"web\"){document.addEventListener(\"keydown\",function(e){if(e.key===\"Escape\"&&!e.defaultPrevented)o(\"_key\",[\"Escape\"])})}Object.defineProperty(window,\"__treebarsOrientation\",{value:m});Object.defineProperty(window,\"__treebarsReply\",{value:function(e){try{l(typeof e===\"string\"?JSON.parse(e):e)}catch(t){}}});var r={};v.forEach(function(e){r[e]=function(){return o(e,Array.prototype.slice.call(arguments))}});w.forEach(function(e){r[e]=function(){if(!i||typeof i[e]!==\"function\")return Promise.resolve({ok:false,reason:\"no_runtime\"});try{return Promise.resolve(i[e].apply(i,arguments))}catch(t){return Promise.resolve({ok:false,reason:\"error\"})}}});function p(){return Math.ceil(document.documentElement.getBoundingClientRect().height)}var b=r.resize;r.resize=function(e){return b(typeof e===\"number\"&&isFinite(e)?e:p())};Object.defineProperty(r,\"_registerRuntime\",{value:function(e){if(!i&&e&&typeof e===\"object\")i=e}});Object.freeze(r);Object.defineProperty(window,\"treebars\",{value:r,enumerable:true});try{Object.defineProperty(navigator,\"clipboard\",{configurable:true,value:{writeText:function(e){return r.copyText(String(e)).then(function(){})}}})}catch(e){}var k=document.execCommand;document.execCommand=function(e){if(String(e).toLowerCase()===\"copy\"){r.copyText(String(window.getSelection?window.getSelection():\"\"));return true}return k.apply(document,arguments)};window.alert=function(e){o(\"_alert\",[e===void 0?\"\":String(e)])};document.addEventListener(\"click\",function(e){if(e.defaultPrevented)return;var t=e.target;while(t&&t.nodeName!==\"A\")t=t.parentNode;if(!t||!t.getAttribute)return;var n=(t.getAttribute(\"href\")||\"\").trim();if(!n||n.charAt(0)===\"#\")return;e.preventDefault();o(\"_link\",[n,t.getAttribute(\"target\")===\"_blank\"])});o(\"_ready\",[]);var g=-1;function c(){var e=p();if(e===g)return;g=e;b(e)}function y(){c();if(typeof ResizeObserver===\"function\")new ResizeObserver(c).observe(document.documentElement);else setInterval(c,500)}if(document.readyState===\"loading\")document.addEventListener(\"DOMContentLoaded\",y);else y()})";

/** The policy on every message's frame. */
export const IN_APP_FRAME_CSP = "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline' https:; img-src https: data: blob:; font-src https: data:; media-src https: data:; base-uri 'none'; form-action 'none'";

/** The web frame's sandbox. */
export const IN_APP_FRAME_SANDBOX = "allow-scripts";

/** The base styles a fragment is framed with, the same in the dashboard's preview and in every app. */
export const IN_APP_FRAME_RULES = "\n    html,body{margin:0;padding:0;background:transparent}\n    body{font:14px/1.5 -apple-system,BlinkMacSystemFont,\"Segoe UI\",Roboto,sans-serif;color:#111827}\n    img{max-width:100%;display:block}\n    a{color:inherit}\n  ";

/** How an HTML body is sized in each shape. */
export const IN_APP_CONTAINER = {"modal":{"maxWidth":420,"gutter":16},"banner":{"maxHeightShare":0.3},"fullscreen":{},"nudge":{"maxHeightShare":0.2,"stackShare":0.3,"maxOnScreen":3},"placement":{"minWidth":240,"maxWidth":960,"cornerWidth":360}} as const;

/** What one display may ask of `trackEvent`. */
export const BRIDGE_LIMITS = {"eventsPerDisplay":20,"repeatWindowMs":250} as const;

/** The events a bridge host records, and the properties it puts on them. */
export const BRIDGE_EVENTS = {"screenViewed":"in_app_screen_viewed","completed":"in_app_completed","rated":"in_app_rated","optedIn":"in_app_opted_in","valueStored":"in_app_value_stored","rewardClaimed":"in_app_reward_claimed","quizCompleted":"in_app_quiz_completed"} as const;
export const BRIDGE_EVENT_KEYS = {"element":"element","screen":"screen","destination":"destination"} as const;

/** Traits `setUserAttribute` never sets. */
export const BRIDGE_RESERVED_TRAITS: readonly string[] = ["id","user_id","identity_id","email","phone","first_seen_at","last_seen_at","created_at"];

/** The methods a preview display refuses, because they write. */
export const BRIDGE_PREVIEW_WRITES: readonly string[] = ["trackDismiss","trackClick","trackRating","trackEvent","identifyUser","setUniqueId","setAlias","setEmailId","setMobileNumber","setUserName","setFirstName","setLastName","setGender","setBirthDate","setUserLocation","setUserAttribute","setUserAttributeDate","setUserAttributeLocation","requestNotificationPermission","showPushOptIn","handleNotificationPopUp","claimReward","requestStoreReview","setStoredValue","_screen","_complete","_quiz","_submit"];
