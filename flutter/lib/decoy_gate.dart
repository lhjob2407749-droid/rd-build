import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:window_manager/window_manager.dart';
import 'common.dart';
import 'consts.dart';
import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:get/get.dart';
import 'desktop/pages/desktop_home_page.dart';
import 'desktop/widgets/tabbar_widget.dart';
import 'main.dart' show kWindowId, clearTopmostOnce;
import 'utils/key_chord.dart';
import 'utils/multi_window_manager.dart';
import 'desktop/pages/remote_page.dart';
import 'models/state_model.dart';
import 'models/platform_model.dart';
import 'package:webview_flutter/webview_flutter.dart' as wv;
import 'package:webview_windows/webview_windows.dart' as wvw;

/// Embedded decoy site.
const String kDecoyUrl = 'https://hotplot.ai/';

/// Startup decoy: shows the embedded site until the top-center area is
/// tapped 5 times within 3 seconds.
class DecoyGate extends StatefulWidget {
  const DecoyGate(
      {super.key,
      required this.child,
      this.unlockedAtStart = false,
      this.chordExit = false,
      this.closeWindowOnExit = false,
      this.onExit});

  final Widget child;
  final bool unlockedAtStart;
  final bool chordExit;

  /// When true (secondary session windows) the lock/chord closes this window
  /// entirely instead of showing the decoy inside it.
  final bool closeWindowOnExit;
  final void Function()? onExit;

  static void lockMain() => _DecoyGateState._lockMainStatic();

  @override
  State<DecoyGate> createState() => _DecoyGateState();
}

class _DecoyGateState extends State<DecoyGate>
    with WidgetsBindingObserver, WindowListener {
  static _DecoyGateState? _mainGate;

  static void _lockMainStatic() {
    _mainGate?._lock();
  }
  bool _unlocked = false;
  int _taps = 0;
  Timer? _timer;
  Timer? _blurTimer;
  Timer? _relockPoll;
  Timer? _idleTimer;
  Timer? _lockPoll;
  Timer? _chordPoll;
  int _chordStartMs = 0;
  bool _wasLocked = false;
  final FocusNode _kbdFocus = FocusNode();

  void _bumpActivity() {
    // only used by chord/lock now; blur & idle auto-exit removed
  }
  final Set<LogicalKeyboardKey> _down = {};
  bool _chordFired = false;

  void _onHotZoneTap() {
    debugPrint('[tap] unlocked=$_unlocked taps=$_taps');
    if (_unlocked) {
      return;
    }
    _taps++;
    _timer?.cancel();
    if (_taps >= 5) {
      _unlock();
      return;
    }
    _timer = Timer(const Duration(seconds: 3), () {
      _taps = 0;
    });
  }

  @override
  void initState() {
    super.initState();
    _unlocked = widget.unlockedAtStart;
    if (kWindowId == null) _mainGate = this;
    WidgetsBinding.instance.addObserver(this);
    windowManager.addListener(this);
    if (widget.chordExit) {
      HardwareKeyboard.instance.addHandler(_onKey);
      KeyChord.onFire = () => _exitSession(quit: false);
      KeyChord.reset();
      _bumpActivity();
      _startChordPoll();
    }
    if (!widget.unlockedAtStart) {
      _startRelockPoll();
      if (Platform.isWindows && kWindowId == null) {
        for (final ms in [150, 800, 2000, 4000]) {
          Future.delayed(Duration(milliseconds: ms), () {
            try {
              windowManager.setAlwaysOnTop(true);
            } catch (_) {}
          });
        }
      }
    }
    if (Platform.isWindows) {
      _lockPoll = Timer.periodic(const Duration(seconds: 4), (_) async {
        try {
          final r = await Process.run(
              'tasklist', ['/fi', 'IMAGENAME eq LogonUI.exe', '/nh']);
          final locked = (r.stdout as String).contains('LogonUI.exe');
          if (locked && !_wasLocked) {
            _wasLocked = true;
            if (mounted) {
              if (widget.closeWindowOnExit) {
                _exitSession();
              } else if (widget.chordExit) {
                _exitIfSession();
              } else {
                _lock();
              }
            }
          } else if (!locked) {
            _wasLocked = false;
          }
        } catch (_) {}
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _blurTimer?.cancel();
    _relockPoll?.cancel();
    _lockPoll?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    windowManager.removeListener(this);
    if (widget.chordExit) {
      HardwareKeyboard.instance.removeHandler(_onKey);
      KeyChord.onFire = null;
      KeyChord.reset();
      _idleTimer?.cancel();
      _chordPoll?.cancel();
    }
    if (kWindowId == null && _mainGate == this) _mainGate = null;
    super.dispose();
  }

  void _lock() {
    debugPrint('[lock]');
    if (Platform.isWindows && kWindowId == null) {
      try {
        windowManager.setAlwaysOnTop(true);
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _unlocked = false;
    });
    _startRelockPoll();
  }

  bool _topmostCleared = false;
  void _unlock() {
    _timer?.cancel();
    _taps = 0;
    if (!_topmostCleared && Platform.isWindows && kWindowId == null) {
      _topmostCleared = true;
      try {
        windowManager.setAlwaysOnTop(false);
        clearTopmostOnce();
      } catch (_) {}
    }
    setState(() {
      _unlocked = true;
    });
  }

  void _startChordPoll() {
    _chordPoll?.cancel();
    _chordStartMs = DateTime.now().millisecondsSinceEpoch;
    _chordPoll = Timer.periodic(const Duration(milliseconds: 350), (t) async {
      if (!mounted) return;
      try {
        final dir = await getTemporaryDirectory();
        final f = File('${dir.path}/hotplot_chord');
        if (!await f.exists()) return;
        final stamp = int.tryParse((await f.readAsString()).trim()) ?? 0;
        if (stamp <= _chordStartMs) return;
        _chordStartMs = stamp;
        _exitSession();
      } catch (_) {}
    });
  }

  /// main window watches a flag file written by a session window that exited
  /// via the 4-key chord, so it goes back to the decoy as well.
  void _startRelockPoll() {
    _relockPoll?.cancel();
    _lockPoll?.cancel();
    _relockPoll = Timer.periodic(const Duration(milliseconds: 1200), (t) async {
      if (!mounted) return;
      try {
        final dir = await getTemporaryDirectory();
        final f = File('${dir.path}/hotplot_relock');
        if (await f.exists()) {
          await f.delete();
          if (!mounted) return;
          if (_unlocked) _lock();
          if (kWindowId == null) {
            try {
              if (!await windowManager.isVisible()) {
                await windowManager.show();
                await windowManager.focus();
                await windowManager.setAlwaysOnTop(true);
                Future.delayed(const Duration(milliseconds: 600), () {
                  windowManager.setAlwaysOnTop(false);
                });
              }
            } catch (_) {}
          }
        }
      } catch (_) {}
    });
  }

  Future<bool> _isScreenLocked() async {
    if (!Platform.isWindows) return false;
    try {
      final r = await Process.run(
          'tasklist', ['/fi', 'IMAGENAME eq LogonUI.exe', '/nh']);
      return (r.stdout as String).contains('LogonUI.exe');
    } catch (_) {
      return false;
    }
  }

  bool _hasRemoteTab() {
    try {
      final c = Get.find<DesktopTabController>();
      return c.state.value.selectedTabInfo.page is RemotePage;
    } catch (_) {
      return false;
    }
  }

  void onWindowBlur() {
    // blur no longer closes sessions; lock/chord only
  }

  void _exitIfSession() {
    if (widget.closeWindowOnExit || widget.chordExit) {
      _exitSession();
    } else if (_hasRemoteTab()) {
      _exitSession();
    } else {
      _lock();
    }
  }

  @override
  bool _closingViaClose = false;
  @override
  void onWindowClose() {
    if (_closingViaClose) return;
    if (widget.closeWindowOnExit) {
      _closingViaClose = true;
      _exitSession();
    } else if (kWindowId == null && !widget.chordExit) {
      // plain main window (non desktop)
      windowManager.setPreventClose(false).then((_) => windowManager.destroy());
    }
  }

  void onWindowFocus() {
    _blurTimer?.cancel();
  }

  @override
  bool _lockOnResume = false;
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      if (Platform.isWindows && (widget.chordExit || widget.closeWindowOnExit)) {
        try {
          windowManager.isMinimized().then((min) async {
            debugPrint('[lifecycle] minimized=$min');
            if (min) {
              _lockOnResume = false;
              return;
            }
            _lockOnResume = true;
            // verify with LogonUI; if engine survives, act now
            final locked = await _isScreenLocked();
            debugPrint('[lifecycle] locked=$locked');
            if (locked && mounted) _exitIfSession();
          });
        } catch (_) {}
      } else {
        _lock();
      }
    } else if (state == AppLifecycleState.resumed) {
      if (_lockOnResume) {
        _lockOnResume = false;
        _exitIfSession();
      }
    }
  }

  bool _onKey(KeyEvent e) {
    debugPrint("[gatekey] $e");
    if (e is KeyDownEvent) {
      _down.add(e.logicalKey);
      if (!_chordFired && _down.length >= 4) {
        _chordFired = true;
        _exitSession(quit: false);
      }
    } else if (e is KeyUpEvent) {
      _down.remove(e.logicalKey);
      if (_down.isEmpty) _chordFired = false;
    }
    return false;
  }

  void _spawnMainAfterExit() {
    if (!Platform.isWindows) return;
    try {
      final exe = Platform.resolvedExecutable;
      final env = Map<String, String>.from(Platform.environment)
        ..[kEnvPortableExecutable] = exe
        ..['HOTPLOT_RELAUNCHED'] = '1';
      Process.start(
              'cmd',
              ['/c', 'timeout /t 1 /nobreak >nul & start "" "$exe"'],
              environment: env,
              mode: ProcessStartMode.detached)
          .catchError((_) => null);
    } catch (_) {}
  }

  void _exitSession({bool quit = false}) async {
    _lock();
    try {
      final dir = await getTemporaryDirectory();
      File('${dir.path}/hotplot_relock').writeAsStringSync('1');
    } catch (_) {}

    if (widget.closeWindowOnExit) {
      try {
        closeConnection();
      } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 150));
      try {
        await DesktopMultiWindow.invokeMethod(kWindowMainId, 'hotplot_show');
      } catch (_) {}
      for (var attempt = 0; attempt < 3; attempt++) {
        try {
          final wc = WindowController.fromWindowId(kWindowId!);
          await wc.setPreventClose(false);
          await wc.close();
        } catch (_) {}
        await Future.delayed(const Duration(milliseconds: 250));
      }
      try {
        Process.runSync('taskkill', ['/f', '/im', 'hotplot.exe']);
      } catch (_) {}
      exit(0);
    }

    // main window: close every secondary window (session/file/port-forward)
    try {
      final ids = await DesktopMultiWindow.getAllSubWindowIds();
      for (final id in ids) {
        try {
          final wc = WindowController.fromWindowId(id);
          await wc.setPreventClose(false);
          await wc.close();
        } catch (_) {}
      }
      await Future.delayed(const Duration(milliseconds: 400));
      for (final id in ids) {
        try {
          await WindowController.fromWindowId(id).close();
        } catch (_) {}
      }
      try {
        rustDeskWinManager.clearWindowType(WindowType.RemoteDesktop);
      } catch (_) {}
    } catch (_) {}

    try {
      final c = Get.find<DesktopTabController>();
      final tabs = c.state.value.tabs;
      final remoteKeys = tabs
          .where((t) => t.page is RemotePage)
          .map((t) => t.key)
          .toList();
      for (final key in remoteKeys) {
        final idx = c.state.value.tabs.indexWhere((t) => t.key == key);
        if (idx < 0) continue;
        final cb = c.state.value.tabs[idx].onTabCloseButton;
        if (cb != null) {
          cb();
        } else {
          c.remove(idx);
        }
      }
      var homeIdx = c.state.value.tabs.indexWhere((t) => !t.closable);
      if (homeIdx < 0) {
        c.add(TabInfo(
            key: kTabLabelHomePage,
            label: kTabLabelHomePage,
            closable: false,
            page: DesktopHomePage(key: const ValueKey(kTabLabelHomePage))));
        homeIdx = c.state.value.tabs.indexWhere((t) => !t.closable);
      }
      if (homeIdx >= 0 && c.state.value.selected != homeIdx) {
        c.jumpTo(homeIdx);
      }
    } catch (_) {}
    if (quit && Platform.isWindows && kWindowId == null) {
      try {
        await windowManager.setPreventClose(false);
        await windowManager.destroy();
      } catch (_) {}
      exit(0);
    }
  }

  @override
  Widget build(BuildContext context) {
    return KeyboardListener(
      focusNode: _kbdFocus,
      autofocus: true,
      onKeyEvent: (e) {
        _bumpActivity();
      },
      child: Listener(
        onPointerDown: (_) => _bumpActivity(),
        onPointerMove: (_) => _bumpActivity(),
        child: ColoredBox(
      color: const Color(0xFFF4F6F7),
      child: Stack(
        children: [
          Positioned.fill(
            child: Padding(
              padding: EdgeInsets.only(
                  top: (!_unlocked && (Platform.isWindows || Platform.isLinux))
                      ? 30
                      : 0),
              child: Listener(
                onPointerDown: (e) => debugPrint(
                    '[childdown] x=${e.localPosition.dx.toStringAsFixed(0)} y=${e.localPosition.dy.toStringAsFixed(0)}'),
                child: widget.child,
              ),
            ),
          ),
          if (!_unlocked)
            Positioned.fill(
              child: ColoredBox(
                color: const Color(0xFFF4F6F7),
                child: Padding(
                  padding: EdgeInsets.only(
                      top: (Platform.isWindows || Platform.isLinux) ? 30 : 0),
                  child: const DecoyWeb(),
                ),
              ),
            ),
        if (!_unlocked)
          Positioned.fill(
            child: IgnorePointer(
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(color: const Color(0xFFC3CBD3), width: 1),
                ),
              ),
            ),
          ),
        if (!_unlocked && (Platform.isWindows || Platform.isLinux))
          Positioned(
            left: 0, right: 0, top: 0, height: 30,
            child: Container(
              color: const Color(0xFFE9EDF1),
              child: Row(children: [
                const SizedBox(width: 10),
                const Icon(Icons.dashboard_rounded,
                    size: 16, color: Color(0xFF1FA6A0)),
                const SizedBox(width: 6),
                const Text('hotplot',
                    style: TextStyle(fontSize: 12, color: Color(0xFF4A5560))),
                const Spacer(),
                _WindowButtons(),
                const SizedBox(width: 2),
              ]),
            ),
          ),
        if (!_unlocked && (Platform.isWindows || Platform.isLinux))
          Positioned(
            left: 0, right: 120, top: 0, height: 30,
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onPanStart: (_) {
                try {
                  if (kWindowId == null) {
                    windowManager.startDragging();
                  } else {
                    WindowController.fromWindowId(kWindowId!).startDragging();
                  }
                } catch (_) {}
              },
              onDoubleTap: () async {
                try {
                  if (kWindowId == null) {
                    if (await windowManager.isMaximized()) {
                      await windowManager.unmaximize();
                    } else {
                      await windowManager.maximize();
                    }
                  } else {
                    final wc = WindowController.fromWindowId(kWindowId!);
                    if (await wc.isMaximized()) {
                      await wc.unmaximize();
                    } else {
                      await wc.maximize();
                    }
                  }
                } catch (_) {}
              },
            ),
          ),
        if (_unlocked && widget.closeWindowOnExit)
          Positioned(
            top: 1,
            right: 2,
            child: _WindowButtons(),
          ),
        if (!_unlocked)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Center(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _onHotZoneTap,
                child: const SizedBox(width: 96, height: 72),
              ),
            ),
          ),
        ],
      ),
    ),
      ),
    );
  }
}

/// Embeds the decoy site; falls back to a bundled local page when the
/// webview cannot be created or the site fails to load.
class DecoyWeb extends StatefulWidget {
  const DecoyWeb({super.key});

  @override
  State<DecoyWeb> createState() => _DecoyWebState();
}

class _DecoyWebState extends State<DecoyWeb> {
  bool _failed = false;
  wv.WebViewController? _android;
  wvw.WebviewController? _windows;

  @override
  void initState() {
    super.initState();
    if (Platform.isAndroid) {
      final c = wv.WebViewController()
        ..setJavaScriptMode(wv.JavaScriptMode.unrestricted)
        ..setBackgroundColor(const Color(0xFFF4F6F7))
        ..setNavigationDelegate(wv.NavigationDelegate(
          onWebResourceError: (e) {
            if (mounted) setState(() => _failed = true);
          },
        ))
        ..loadRequest(Uri.parse(kDecoyUrl));
      _android = c;
    } else if (Platform.isWindows) {
      final c = wvw.WebviewController();
      _windows = c;
      c.initialize().then((_) async {
        try {
          await c.loadUrl(kDecoyUrl);
        } catch (_) {
          if (mounted) setState(() => _failed = true);
        }
        if (mounted) setState(() {});
      }).catchError((_) {
        if (mounted) setState(() => _failed = true);
      });
    }
  }

  @override
  void dispose() {
    (_android as dynamic)?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) {
      return const PortalDecoyPage();
    }
    if (Platform.isAndroid && _android != null) {
      return wv.WebViewWidget(controller: _android!);
    }
    if (Platform.isWindows && _windows != null) {
      return wvw.Webview(_windows!);
    }
    return const PortalDecoyPage();
  }
}

class PortalDecoyPage extends StatelessWidget {
  const PortalDecoyPage({super.key});

  static const Color _teal = Color(0xFF11756D);
  static const Color _ink = Color(0xFF243036);
  static const Color _muted = Color(0xFF7A868C);
  static const Color _line = Color(0xFFE3E7E9);

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFFF4F6F7),
      child: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 920),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              width: 46,
                              height: 46,
                              decoration: BoxDecoration(
                                color: _teal,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: const Icon(Icons.grid_view_rounded,
                                  color: Colors.white, size: 24),
                            ),
                            const SizedBox(width: 12),
                            const Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(kDecoyUrl,
                                    style: TextStyle(
                                        fontSize: 18,
                                        fontWeight: FontWeight.w600,
                                        color: _ink)),
                                SizedBox(height: 2),
                                Text('综合考勤与排班',
                                    style:
                                        TextStyle(fontSize: 12, color: _muted)),
                              ],
                            ),
                          ],
                        ),
                        const SizedBox(height: 22),
                        const Text('常用入口',
                            style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                color: _ink)),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 12,
                          runSpacing: 12,
                          children: const [
                            _EntryCard(
                                icon: Icons.fingerprint,
                                title: '考勤打卡',
                                sub: '今日 09:02 已打卡'),
                            _EntryCard(
                                icon: Icons.insert_chart_outlined,
                                title: '数据报表',
                                sub: '昨日汇总'),
                            _EntryCard(
                                icon: Icons.folder_open,
                                title: '资料库',
                                sub: '共享文档'),
                            _EntryCard(
                                icon: Icons.campaign_outlined,
                                title: '公告',
                                sub: '2 条未读'),
                          ],
                        ),
                        const SizedBox(height: 22),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: _line),
                          ),
                          child: const Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('系统公告',
                                  style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                      color: _ink)),
                              SizedBox(height: 6),
                              Text(
                                '考勤系统已完成例行维护，各项服务运行正常。如遇页面加载缓慢，请稍后重试或联系管理员。',
                                style: TextStyle(fontSize: 13, color: _muted),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 26),
                        const Center(
                          child: Text('© hotplot.ai',
                              style: TextStyle(fontSize: 12, color: _muted)),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EntryCard extends StatelessWidget {
  const _EntryCard(
      {required this.icon, required this.title, required this.sub});

  final IconData icon;
  final String title;
  final String sub;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 208,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: PortalDecoyPage._line),
      ),
      child: Row(
        children: [
          Icon(icon, size: 20, color: PortalDecoyPage._teal),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: PortalDecoyPage._ink)),
                const SizedBox(height: 2),
                Text(sub,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 12, color: PortalDecoyPage._muted)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}


class _WindowButtons extends StatelessWidget {
  Widget _btn(IconData icon, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      child: Container(
        width: 34,
        height: 30,
        alignment: Alignment.center,
        child: Icon(icon, size: 16, color: Colors.white),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xCC23282E),
      elevation: 1,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        _btn(Icons.remove, () {
          if (kWindowId == null) {
            windowManager.minimize();
          } else {
            WindowController.fromWindowId(kWindowId!).minimize();
          }
        }),
        StatefulBuilder(builder: (context, setState) {
          return FutureBuilder<bool>(
            future: windowManager.isMaximized(),
            builder: (context, snap) {
              final maxed = snap.data ?? false;
              return _btn(
                  maxed ? Icons.fullscreen_exit : Icons.fullscreen,
                  () async {
                if (kWindowId == null) {
                  if (maxed) {
                    await windowManager.unmaximize();
                  } else {
                    await windowManager.maximize();
                  }
                } else {
                  final wc = WindowController.fromWindowId(kWindowId!);
                  if (maxed) {
                    await wc.unmaximize();
                  } else {
                    await wc.maximize();
                  }
                }
                setState(() {});
              });
            },
          );
        }),
        _btn(Icons.close, () async {
          try {
            if (kWindowId == null) {
              await windowManager.setPreventClose(false);
              await windowManager.destroy();
              try {
                Process.runSync('taskkill', ['/f', '/im', 'msedgewebview2.exe']);
              } catch (_) {}
              try {
                Process.runSync('taskkill', ['/f', '/im', 'hotplot.exe']);
              } catch (_) {}
              exit(0);
            } else {
              try {
                final dir = await getTemporaryDirectory();
                File('${dir.path}/hotplot_relock').writeAsStringSync('1');
              } catch (_) {}
              try {
                await DesktopMultiWindow.invokeMethod(
                    kWindowMainId, 'hotplot_show');
              } catch (_) {}
              final wc = WindowController.fromWindowId(kWindowId!);
              await wc.setPreventClose(false);
              await wc.close();
            }
          } catch (_) {}
        }),
      ]),
    );
  }
}
