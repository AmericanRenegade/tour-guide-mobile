part of 'map_screen.dart';

/// Auto-scrolling marquee text: pause → scroll to end → pause → reset → repeat.
class _MarqueeText extends StatefulWidget {
  final String text;
  final TextStyle? style;
  const _MarqueeText({required this.text, this.style});

  @override
  State<_MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<_MarqueeText> {
  final ScrollController _sc = ScrollController();
  Timer? _timer;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _startCycle());
  }

  @override
  void didUpdateWidget(_MarqueeText old) {
    super.didUpdateWidget(old);
    if (old.text != widget.text) {
      _timer?.cancel();
      _sc.jumpTo(0);
      WidgetsBinding.instance.addPostFrameCallback((_) => _startCycle());
    }
  }

  void _startCycle() {
    if (_disposed || !_sc.hasClients) return;
    final maxScroll = _sc.position.maxScrollExtent;
    if (maxScroll <= 0) return; // text fits, no scrolling needed

    _timer?.cancel();
    // Initial pause, then scroll
    _timer = Timer(const Duration(seconds: 2), () {
      if (_disposed || !_sc.hasClients) return;
      // Scroll speed: ~40px/s
      final durationMs = (maxScroll / 40 * 1000).toInt();
      _sc.animateTo(maxScroll,
          duration: Duration(milliseconds: durationMs),
          curve: Curves.linear);
      // After scroll completes, pause then reset
      _timer = Timer(Duration(milliseconds: durationMs + 2000), () {
        if (_disposed || !_sc.hasClients) return;
        _sc.jumpTo(0);
        // Restart the cycle
        _startCycle();
      });
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _sc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      controller: _sc,
      scrollDirection: Axis.horizontal,
      physics: const NeverScrollableScrollPhysics(),
      child: Text(widget.text, style: widget.style, maxLines: 1),
    );
  }
}

// ── Expandable PageView ─────────────────────────────────────────────────────
// A PageView whose height adapts to the current page's content.

class _ExpandablePageView extends StatefulWidget {
  final PageController controller;
  final int itemCount;
  final Widget Function(BuildContext, int) itemBuilder;
  final ValueChanged<int>? onPageChanged;
  final ScrollPhysics? physics;
  final double fallbackHeight;

  const _ExpandablePageView({
    required this.controller,
    required this.itemCount,
    required this.itemBuilder,
    this.onPageChanged,
    this.physics,
    this.fallbackHeight = 200.0,
  });

  @override
  State<_ExpandablePageView> createState() => _ExpandablePageViewState();
}

class _ExpandablePageViewState extends State<_ExpandablePageView> {
  final Map<int, double> _heights = {};
  double _currentHeight = 0;

  @override
  void initState() {
    super.initState();
    _currentHeight = widget.fallbackHeight;
    widget.controller.addListener(_onScroll);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onScroll);
    super.dispose();
  }

  void _onScroll() {
    if (!widget.controller.hasClients) return;
    final page = widget.controller.page ?? 0;
    final lower = page.floor().clamp(0, widget.itemCount - 1);
    final upper = page.ceil().clamp(0, widget.itemCount - 1);
    final t = page - page.floor();
    final lowerH = _heights[lower] ?? widget.fallbackHeight;
    final upperH = _heights[upper] ?? widget.fallbackHeight;
    final interpolated = lowerH + (upperH - lowerH) * t;
    if ((interpolated - _currentHeight).abs() > 0.5) {
      setState(() => _currentHeight = interpolated);
    }
  }

  void _onChildSized(int index, double height) {
    if ((_heights[index] ?? 0) == height) return;
    _heights[index] = height;
    final currentPage = widget.controller.hasClients
        ? (widget.controller.page?.round() ?? 0)
        : 0;
    if (index == currentPage) {
      setState(() => _currentHeight = height);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
      height: _currentHeight,
      child: PageView.builder(
        controller: widget.controller,
        physics: widget.physics,
        onPageChanged: widget.onPageChanged,
        itemCount: widget.itemCount,
        itemBuilder: (context, index) {
          return OverflowBox(
            minHeight: 0,
            maxHeight: double.infinity,
            alignment: Alignment.bottomCenter,
            child: _SizeReporter(
              onSized: (size) => _onChildSized(index, size.height),
              child: widget.itemBuilder(context, index),
            ),
          );
        },
      ),
    );
  }
}

/// Reports its child's rendered size after every layout.
class _SizeReporter extends StatefulWidget {
  final Widget child;
  final ValueChanged<Size> onSized;
  const _SizeReporter({required this.child, required this.onSized});

  @override
  State<_SizeReporter> createState() => _SizeReporterState();
}

class _SizeReporterState extends State<_SizeReporter> {
  final _key = GlobalKey();
  Size _lastSize = Size.zero;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
  }

  void _measure() {
    final rb = _key.currentContext?.findRenderObject() as RenderBox?;
    if (rb != null && rb.hasSize) {
      final size = rb.size;
      if (size != _lastSize) {
        _lastSize = size;
        widget.onSized(size);
      }
    }
  }

  @override
  void didUpdateWidget(covariant _SizeReporter oldWidget) {
    super.didUpdateWidget(oldWidget);
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(key: _key, child: widget.child);
  }
}
