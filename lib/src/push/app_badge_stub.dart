import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/services.dart';

const _channel = MethodChannel('mdsu/notifications');

/// Phone and desktop apps. On Android the number on the icon follows the notifications in the
/// pull-down list, so when everything has been read we clear that list (MainActivity.kt,
/// written by tool/setup_platforms.sh). Elsewhere nothing to do.
void setAppBadge(int count) {
  if (count > 0 || defaultTargetPlatform != TargetPlatform.android) return;
  _channel.invokeMethod<void>('clearAll').catchError((_) {});
}
