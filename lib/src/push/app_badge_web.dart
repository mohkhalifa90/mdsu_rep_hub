import 'dart:js_interop';
import 'dart:js_interop_unsafe';

/// Web version: red number on the app icon (iPhone Home Screen app, installed browser apps).
/// Only shown when notifications are allowed. Does nothing where the browser has no Badging API.
void setAppBadge(int count) {
  try {
    final nav = globalContext['navigator'];
    if (nav == null || !nav.isA<JSObject>()) return;
    final navigator = nav as JSObject;
    if (count > 0) {
      if (navigator.has('setAppBadge')) navigator.callMethod<JSAny?>('setAppBadge'.toJS, count.toJS);
    } else {
      if (navigator.has('clearAppBadge')) navigator.callMethod<JSAny?>('clearAppBadge'.toJS);
    }
  } catch (_) {
    // Not supported here
  }
}
