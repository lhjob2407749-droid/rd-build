import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:window_manager/window_manager.dart';
import 'common.dart';
import 'package:get/get.dart';
import 'desktop/widgets/tabbar_widget.dart';
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
      this.chordExit = false});

  final Widget child;
  final bool unlockedAtStart;
  final bool chordExit;

  @override
  State<DecoyGate> createState() => _DecoyGateState();
}

class _DecoyGateState extends State<DecoyGate>
    with WidgetsBindingObserver, WindowListener {
  bool _unlocked = false;
  int _taps = 0;
  Timer? _timer;
  Timer? _blurTimer;
  Timer? _relockPoll;
  Timer? _idleTimer;
  final FocusNode _kbdFocus = FocusNode();

  void _bumpActivity() {
    if (!widget.chordExit) return;
    _idleTimer?.cancel();
    _idleTimer = Timer(const Duration(minutes: 3), () {
      if (mounted) _exitIfSession();
    });
  }
  final Set<LogicalKeyboardKey> _down = {};
  bool _chordFired = false;

  void _onHotZoneTap() {
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
    WidgetsBinding.instance.addObserver(this);
    windowManager.addListener(this);
    if (widget.chordExit) {
      HardwareKeyboard.instance.addHandler(_onKey);
      _bumpActivity();
    }
    if (!widget.unlockedAtStart) {
      _startRelockPoll();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _blurTimer?.cancel();
    _relockPoll?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    windowManager.removeListener(this);
    if (widget.chordExit) {
      HardwareKeyboard.instance.removeHandler(_onKey);
      _idleTimer?.cancel();
    }
    super.dispose();
  }

  void _lock() {
    if (!mounted) return;
    setState(() {
      _unlocked = false;
    });
    _startRelockPoll();
  }

  void _unlock() {
    setState(() {
      _unlocked = true;
    });
  }

  /// main window watches a flag file written by a session window that exited
  /// via the 4-key chord, so it goes back to the decoy as well.
  void _startRelockPoll() {
    _relockPoll?.cancel();
    _relockPoll = Timer.periodic(const Duration(milliseconds: 1200), (t) async {
      if (!mounted) return;
      try {
        final dir = await getTemporaryDirectory();
        final f = File('${dir.path}/hotplot_relock');
        if (await f.exists()) {
          await f.delete();
          if (mounted && _unlocked) {
            _lock();
          }
        }
      } catch (_) {}
    });
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
    _blurTimer?.cancel();
    _blurTimer = Timer(const Duration(seconds: 45), () {
      if (!mounted) return;
      if (widget.chordExit) {
        _exitIfSession();
      } else {
        _lock();
      }
    });
  }

  void _exitIfSession() {
    if (_hasRemoteTab()) {
      _exitSession();
    } else {
      _lock();
    }
  }

  @override
  void onWindowFocus() {
    _blurTimer?.cancel();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _lock();
    }
  }

  bool _onKey(KeyEvent e) {
    if (e is KeyDownEvent) {
      _down.add(e.logicalKey);
      if (!_chordFired && _down.length >= 4) {
        _chordFired = true;
        _exitSession();
      }
    } else if (e is KeyUpEvent) {
      _down.remove(e.logicalKey);
      if (_down.isEmpty) _chordFired = false;
    }
    return false;
  }

  void _exitSession() async {
    _lock();
    try {
      final dir = await getTemporaryDirectory();
      File('${dir.path}/hotplot_relock').writeAsStringSync('1');
    } catch (_) {}
    await Future.delayed(const Duration(milliseconds: 200));
    try {
      closeConnection();
    } catch (_) {}
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
            child: _unlocked ? widget.child : const DecoyWeb(),
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
