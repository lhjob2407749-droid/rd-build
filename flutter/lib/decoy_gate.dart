import 'dart:async';

import 'package:flutter/material.dart';

/// Address shown in the decoy browser bar.
const String kDecoyUrl = 'https://attendance.officetool.cn/';

/// Startup decoy: shows a harmless portal page until the bottom-right
/// corner is tapped 5 times within 3 seconds.
class DecoyGate extends StatefulWidget {
  const DecoyGate({super.key, required this.child});

  final Widget child;

  @override
  State<DecoyGate> createState() => _DecoyGateState();
}

class _DecoyGateState extends State<DecoyGate> {
  bool _unlocked = false;
  int _taps = 0;
  Timer? _timer;

  void _onHotZoneTap() {
    if (_unlocked) {
      return;
    }
    _taps++;
    _timer?.cancel();
    if (_taps >= 5) {
      setState(() {
        _unlocked = true;
      });
      return;
    }
    _timer = Timer(const Duration(seconds: 3), () {
      _taps = 0;
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 120),
            child: _unlocked ? widget.child : const PortalDecoyPage(),
          ),
        ),
        if (!_unlocked)
          Positioned(
            right: 0,
            bottom: 0,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _onHotZoneTap,
              child: const SizedBox(width: 64, height: 64),
            ),
          ),
      ],
    );
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
                                Text('考勤',
                                    style: TextStyle(
                                        fontSize: 20,
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
                          child: Text('© 2026 考勤系统',
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
