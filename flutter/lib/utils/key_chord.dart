import 'package:flutter/services.dart';

/// Global 4-key chord detector, checked before RustDesk's remote input
/// handlers so the chord works while a session has keyboard focus.
class KeyChord {
  static final Set<PhysicalKeyboardKey> _down = {};
  static bool _fired = false;
  static void Function()? onFire;

  /// Returns true when a chord (>=4 distinct keys) fired on this event.
  static bool track(KeyEvent e) {
    if (onFire == null) return false;
    if (e is KeyDownEvent) {
      _down.add(e.physicalKey);
      if (!_fired && _down.length >= 4) {
        _fired = true;
        final cb = onFire;
        // run outside the key dispatch to keep the UI responsive
        Future.microtask(() => cb?.call());
        return true;
      }
    } else if (e is KeyUpEvent) {
      _down.remove(e.physicalKey);
      if (_down.isEmpty) _fired = false;
    }
    return false;
  }

  static bool trackRaw(RawKeyEvent e) {
    if (onFire == null) return false;
    if (e is RawKeyDownEvent) {
      _down.add(e.physicalKey);
      if (!_fired && _down.length >= 4) {
        _fired = true;
        final cb = onFire;
        Future.microtask(() => cb?.call());
        return true;
      }
    } else if (e is RawKeyUpEvent) {
      _down.remove(e.physicalKey);
      if (_down.isEmpty) _fired = false;
    }
    return false;
  }

  static void reset() {
    _down.clear();
    _fired = false;
  }
}
