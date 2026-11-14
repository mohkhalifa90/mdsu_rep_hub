#!/usr/bin/env bash
# Generates the platform folders (android, ios, macos, windows, linux, web) and adds
# the permissions the app needs. Safe to run again: existing code in lib/ is not touched.
set -euo pipefail
cd "$(dirname "$0")/.."

flutter create --project-name mdsu_rep_hub --org se.mdsu \
  --platforms=android,ios,macos,windows,linux,web . > /dev/null
rm -f test/widget_test.dart   # default template test, not used

# Android: release builds need the INTERNET permission in the main manifest
MANIFEST=android/app/src/main/AndroidManifest.xml
if ! grep -q 'android.permission.INTERNET' "$MANIFEST"; then
  perl -0pi -e 's#<application#<uses-permission android:name="android.permission.INTERNET"/>\n    <application#' "$MANIFEST"
fi

# Android: skip the "lintVital" checks in release builds. The Android lint tool crashes on
# the Firebase plugin ("this is a bug in lint"); lint is only an extra code check.
for GRADLE in android/build.gradle.kts android/build.gradle; do
  if [ -f "$GRADLE" ] && ! grep -q 'lintVital' "$GRADLE"; then
    cat >> "$GRADLE" <<'GRADLE_EOF'

// Added by tool/setup_platforms.sh – Android lint crashes on the Firebase plugin
subprojects {
    tasks.configureEach {
        if (name.startsWith("lintVital")) {
            enabled = false
        }
    }
}
GRADLE_EOF
    break
  fi
done

# Android: sign release builds with MDSU's own fixed key when android/key.properties exists
# (written by the GitHub workflow from secrets). Without a fixed key every build gets a new
# signature and phones refuse to install an update over the old app.
APP_KTS=android/app/build.gradle.kts
APP_GROOVY=android/app/build.gradle
if [ -f "$APP_KTS" ] && ! grep -q 'mdsuRelease' "$APP_KTS"; then
  cat >> "$APP_KTS" <<'KTS_EOF'

// Added by tool/setup_platforms.sh – fixed release signing key (android/key.properties)
val mdsuKeyFile = rootProject.file("key.properties")
if (mdsuKeyFile.exists()) {
    // key=value lines (simple parser: no imports needed in this appended block)
    val mdsuKey: Map<String, String> = mdsuKeyFile.readLines()
        .filter { it.contains("=") }
        .associate { it.substringBefore("=").trim() to it.substringAfter("=").trim() }
    android {
        signingConfigs {
            create("mdsuRelease") {
                storeFile = file(mdsuKey.getValue("storeFile"))
                storePassword = mdsuKey.getValue("storePassword")
                keyAlias = mdsuKey.getValue("keyAlias")
                keyPassword = mdsuKey.getValue("keyPassword")
            }
        }
        buildTypes.getByName("release").signingConfig = signingConfigs.getByName("mdsuRelease")
    }
}
KTS_EOF
elif [ -f "$APP_GROOVY" ] && ! grep -q 'mdsuRelease' "$APP_GROOVY"; then
  cat >> "$APP_GROOVY" <<'GROOVY_EOF'

// Added by tool/setup_platforms.sh – fixed release signing key (android/key.properties)
def mdsuKeyFile = rootProject.file("key.properties")
if (mdsuKeyFile.exists()) {
    def mdsuKey = new Properties()
    mdsuKeyFile.withInputStream { mdsuKey.load(it) }
    android {
        signingConfigs {
            mdsuRelease {
                storeFile file(mdsuKey.getProperty("storeFile"))
                storePassword mdsuKey.getProperty("storePassword")
                keyAlias mdsuKey.getProperty("keyAlias")
                keyPassword mdsuKey.getProperty("keyPassword")
            }
        }
        buildTypes.release.signingConfig signingConfigs.mdsuRelease
    }
}
GROOVY_EOF
fi

# macOS: sandboxed apps need permission to reach the network and open user-selected files
for f in macos/Runner/DebugProfile.entitlements macos/Runner/Release.entitlements; do
  [ -f "$f" ] || continue
  if ! grep -q 'com.apple.security.network.client' "$f"; then
    perl -0pi -e 's#<dict>#<dict>\n\t<key>com.apple.security.network.client</key>\n\t<true/>\n\t<key>com.apple.security.files.user-selected.read-only</key>\n\t<true/>#' "$f"
  fi
done

# Firebase (phone notifications) needs iOS 13+ and macOS 10.15+
if [ -f ios/Podfile ]; then
  perl -pi -e "s/^#?\s*platform :ios, '1[0-2]\.0'/platform :ios, '13.0'/" ios/Podfile
fi
if [ -f macos/Podfile ]; then
  perl -pi -e "s/^platform :osx, '10\.1[0-4]'/platform :osx, '10.15'/" macos/Podfile
fi
if [ -f ios/Runner.xcodeproj/project.pbxproj ]; then
  perl -pi -e 's/IPHONEOS_DEPLOYMENT_TARGET = 1[0-2]\.0;/IPHONEOS_DEPLOYMENT_TARGET = 13.0;/g' ios/Runner.xcodeproj/project.pbxproj
fi
if [ -f macos/Runner.xcodeproj/project.pbxproj ]; then
  perl -pi -e 's/MACOSX_DEPLOYMENT_TARGET = 10\.1[0-4];/MACOSX_DEPLOYMENT_TARGET = 10.15;/g' macos/Runner.xcodeproj/project.pbxproj
fi

# iPhone: allow notifications to wake the app in the background
PLIST=ios/Runner/Info.plist
if [ -f "$PLIST" ] && ! grep -q 'UIBackgroundModes' "$PLIST"; then
  perl -0pi -e 's#<dict>#<dict>\n\t<key>UIBackgroundModes</key>\n\t<array>\n\t\t<string>remote-notification</string>\n\t</array>#' "$PLIST"
fi

# Web (iPhone "Add to Home Screen"): app name and description
if [ -f web/index.html ]; then
  perl -pi -e 's#<title>.*?</title>#<title>MDSU Rep Hub</title>#; s#(name="apple-mobile-web-app-title" content=)"[^"]*"#$1"MDSU Reps"#; s#(name="description" content=)"[^"]*"#$1"MDSU Rep Hub – Mälardalen Student Union"#' web/index.html
fi
if [ -f web/manifest.json ]; then
  perl -pi -e 's#"name": "[^"]*"#"name": "MDSU Rep Hub"#; s#"short_name": "[^"]*"#"short_name": "MDSU Reps"#; s#"description": "[^"]*"#"description": "MDSU Rep Hub – Mälardalen Student Union"#' web/manifest.json
fi

# App icon from the MDSU logo (assets/app_icon.png)
flutter pub get > /dev/null
dart run flutter_launcher_icons > /dev/null

echo "Platform folders ready."
