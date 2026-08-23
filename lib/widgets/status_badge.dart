import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/app_radius.dart';

/// Pill-shaped flood-status badge (dot + label), translated from the web
/// app's `.status-badge` component (floodsight-design-reference.css §2):
/// tinted background, colored border ring, fully-rounded pill.
///
/// When [pulse] is true and [status] is `'DANGER'`, the dot pulses —
/// mirroring `.status-badge--danger .status-badge__dot`'s `status-pulse`
/// keyframes (1.6s ease-in-out, opacity 1 → 0.35 → 1) from the web's
/// notification sidebar.
class StatusBadge extends StatefulWidget {
  final String status; // 'DANGER' | 'ALERT' | 'NORMAL'
  final bool pulse;
  final String? label;

  const StatusBadge({
    super.key,
    required this.status,
    this.pulse = false,
    this.label,
  });

  Color get _color {
    switch (status) {
      case 'DANGER':
        return AppColors.danger;
      case 'ALERT':
        return AppColors.alert;
      default:
        return AppColors.normal;
    }
  }

  @override
  State<StatusBadge> createState() => _StatusBadgeState();
}

class _StatusBadgeState extends State<StatusBadge>
    with SingleTickerProviderStateMixin {
  AnimationController? _controller;

  bool get _shouldPulse => widget.pulse && widget.status == 'DANGER';

  @override
  void initState() {
    super.initState();
    if (_shouldPulse) _startPulse();
  }

  @override
  void didUpdateWidget(covariant StatusBadge old) {
    super.didUpdateWidget(old);
    if (_shouldPulse && _controller == null) {
      _startPulse();
    } else if (!_shouldPulse && _controller != null) {
      _controller!.dispose();
      _controller = null;
      setState(() {});
    }
  }

  void _startPulse() {
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget._color;
    final dot = Container(
      width: 6,
      height: 6,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(AppRadius.full),
        border: Border.all(color: color.withValues(alpha: 0.3), width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _controller == null
              ? dot
              : FadeTransition(
                  opacity: Tween(begin: 1.0, end: 0.35).animate(
                    CurvedAnimation(
                        parent: _controller!, curve: Curves.easeInOut),
                  ),
                  child: dot,
                ),
          const SizedBox(width: 6),
          Text(
            widget.label ?? widget.status,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.3,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}
