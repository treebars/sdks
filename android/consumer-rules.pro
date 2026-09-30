# The SDK's public surface is called reflectively from Java integrations and must
# survive minification in the consuming app.
-keep public class com.treebars.sdk.Treebars { public *; }
-keep public enum com.treebars.sdk.TreebarsEnv { *; }
-keep public enum com.treebars.sdk.PushProvider { *; }

# The HTML in-app bridge: the page reaches Java through this one method, by name, from JavaScript.
# R8 cannot see that call, so without this a release build strips it and every HTML message's bridge is dead — while a
# debug build works.
-keepclassmembers class com.treebars.sdk.InAppHtmlHost$Bridge {
    @android.webkit.JavascriptInterface <methods>;
}

# Play's in-app review is reached by name, so an app that carries the library keeps the classes the
# SDK asks for even when nothing of its own calls them; an app that does not carry it gets the store listing instead.
-keep class com.google.android.play.core.review.ReviewManagerFactory { public static *; }
-keep class com.google.android.play.core.review.ReviewManager { public *; }
-keep class * implements com.google.android.play.core.review.ReviewManager { public *; }
-dontwarn com.google.android.play.core.review.**
