import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mechanix_terminal/features/data/settings.dart';
import 'package:mechanix_terminal/features/screen/settings_screen.dart';
import 'package:mechanix_terminal/features/widgets/terminal_view.dart';
import 'package:mechanix_terminal/src/rust/api/simple.dart';

class TerminalTabs extends StatefulWidget {
  final AppSettings settings;
  final ValueChanged<AppSettings> onSettingsChanged;
  final Stream<int>? terminalStream;

  const TerminalTabs({
    super.key,
    required this.settings,
    required this.onSettingsChanged,
    this.terminalStream,
  });

  @override
  State<TerminalTabs> createState() => _TerminalTabsState();
}

class _TerminalTabsState extends State<TerminalTabs>
    with TickerProviderStateMixin {
  final List<int> _terminalIds = [];
  TabController? _tabController;

  @override
  void initState() {
    super.initState();
    _addTab();
  }

  @override
  void dispose() {
    _tabController?.dispose();
    super.dispose();
  }

  void _addTab() {
    setState(() {
      final id = addTerminal(rows: 24, cols: 80);
      if (id != 0) {
        _terminalIds.add(id);

        _tabController?.dispose();
        _tabController = TabController(
          length: _terminalIds.length,
          vsync: this,
          initialIndex: _terminalIds.length - 1,
        );
      }
    });
  }

  void _removeTab(int id) {
    setState(() {
      final indexToRemove = _terminalIds.indexOf(id);
      if (indexToRemove == -1) return;

      final activeId = _tabController != null &&
              _tabController!.index < _terminalIds.length
          ? _terminalIds[_tabController!.index]
          : null;

      removeTerminal(id: id);
      _terminalIds.remove(id);

      if (_terminalIds.isEmpty) {
        _tabController?.dispose();
        _tabController = null;
        SystemNavigator.pop();
        return;
      }

      // If active tab still exists, find its shifted index;
      // otherwise clamp to stay within valid tab bounds.
      final newIndex = (activeId == id || activeId == null)
          ? indexToRemove.clamp(0, _terminalIds.length - 1)
          : _terminalIds.indexOf(activeId).clamp(0, _terminalIds.length - 1);

      _tabController?.dispose();
      _tabController = TabController(
        length: _terminalIds.length,
        vsync: this,
        initialIndex: newIndex,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_terminalIds.isEmpty) {
      return const Scaffold(body: SizedBox.shrink());
    }

    final buttonStyle = ButtonStyle(
      splashFactory: NoSplash.splashFactory,
      overlayColor: WidgetStateProperty.resolveWith<Color?>((
        Set<WidgetState> states,
      ) {
        if (states.contains(WidgetState.pressed)) {
          return Colors.white.withValues(alpha: 0.2);
        }
        if (states.contains(WidgetState.hovered) ||
            states.contains(WidgetState.focused)) {
          return Colors.white.withValues(alpha: 0.05);
        }
        return null;
      }),
    );

    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 52,
        titleSpacing: 0,
        actionsPadding: const EdgeInsets.symmetric(horizontal: 8.0),
        title: TabBar(
          controller: _tabController,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          labelPadding: const EdgeInsets.symmetric(horizontal: 8.0),
          tabs: _terminalIds
              .asMap()
              .entries
              .map(
                (e) => Tab(
                  key: ValueKey('tab_${e.value}'),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(width: 8),
                      Text("Tab ${e.key + 1}"),
                      IconButton(
                        iconSize: 16,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 48,
                          minHeight: 48,
                        ),
                        icon: const Icon(Icons.close),
                        onPressed: () => _removeTab(e.value),
                        tooltip: 'Close Tab',
                      ),
                    ],
                  ),
                ),
              )
              .toList(),
        ),
        actions: [
          IconButton(
            style: buttonStyle,
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            icon: const Icon(Icons.add),
            onPressed: _addTab,
            tooltip: 'Add Tab',
          ),
          IconButton(
            style: buttonStyle,
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            icon: const Icon(Icons.settings),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  fullscreenDialog: true,
                  builder: (_) => TerminalSettingsPage(
                    settings: widget.settings,
                    onSettingsChanged: widget.onSettingsChanged,
                  ),
                ),
              );
            },
            tooltip: 'Settings',
          ),
        ],
      ),

      body: TabBarView(
        controller: _tabController,
        physics: const NeverScrollableScrollPhysics(),
        children: _terminalIds.asMap().entries.map((entry) {
          return TerminalView(
            key: ValueKey('term_${entry.value}'),
            terminalId: entry.value,
            settings: widget.settings,
            tabController: _tabController!,
            index: entry.key,
            terminalStream: widget.terminalStream,
            onClosed: () => _removeTab(entry.value),
          );
        }).toList(),
      ),
    );
  }
}
