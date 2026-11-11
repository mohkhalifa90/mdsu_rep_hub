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

echo "Platform folders ready."
