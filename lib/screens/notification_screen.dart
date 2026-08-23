import 'dart:async';
import 'package:flutter/material.dart';
import '../services/cctv_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_radius.dart';
import '../theme/app_shadows.dart';
import '../widgets/status_badge.dart';

// ── Data model ────────────────────────────────────────────────────────────────

class NotificationItem {
  final String title;       // "Flood DANGER", "Flood ALERT", "Flood NORMAL"
  final String location;    // "Lapasan Highway, CDO"
  final String status;      // 'DANGER' | 'ALERT' | 'NORMAL'
  final double floodHeight; // in meters
  final String timeAgo;     // "2 min ago"
  final bool isRead;

  const NotificationItem({
    required this.title,
    required this.location,
    required this.status,
    required this.floodHeight,
    required this.timeAgo,
    this.isRead = false,
  });

  /// Left border + dot color
  Color get statusColor {
    switch (status) {
      case 'DANGER': return const Color(0xFFE53935);
      case 'ALERT':  return const Color(0xFFFF9800);
      default:       return const Color(0xFF43A047);
    }
  }

}

// ── Screen ────────────────────────────────────────────────────────────────────

class NotificationScreen extends StatefulWidget {
  const NotificationScreen({super.key});

  @override
  State<NotificationScreen> createState() => _NotificationScreenState();
}

class _NotificationScreenState extends State<NotificationScreen> {
  int _filterIndex = 0; // 0 = All, 1 = Alert, 2 = Danger
  List<NotificationItem> _notifications = [];
  bool _isLoading = true;
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _loadNotifications();
    // Auto-refresh every 60 seconds
    _refreshTimer = Timer.periodic(const Duration(seconds: 60), (_) => _loadNotifications());
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadNotifications() async {
    final docs = await CctvService.fetchAllNotifications();
    if (!mounted) return;

    setState(() {
      // Filter out normal/safe notifications — only keep danger and alert
      final filtered = docs.where((doc) {
        final rawStatus = (doc['status'] as String? ?? 'safe').toLowerCase();
        return rawStatus == 'danger' || rawStatus == 'alert';
      }).toList();
      _notifications = filtered.asMap().entries.map((entry) {
        return _convertDocToNotification(entry.key, entry.value);
      }).toList();
      _isLoading = false;
    });
  }

  /// Converts a MongoDB CCTV document into a NotificationItem.
  NotificationItem _convertDocToNotification(int index, Map<String, dynamic> doc) {
    final rawStatus = (doc['status'] as String? ?? 'safe').toLowerCase();
    String status;
    String title;
    switch (rawStatus) {
      case 'danger':
        status = 'DANGER';
        title = 'Flood DANGER';
        break;
      case 'alert':
        status = 'ALERT';
        title = 'Flood ALERT';
        break;
      default:
        status = 'NORMAL';
        title = 'Flood NORMAL';
    }

    final floodHeight = (doc['water_level'] as num?)?.toDouble() ?? 0;

    final timestamp = doc['timestamp'] as String?;
    final timeAgo = _formatTimestamp(timestamp);

    // Use location_name from database if available, otherwise fall back to coordinates
    String location = doc['location_name'] as String? ?? 'Cagayan de Oro';
    if (location.isEmpty) {
      try {
        final coordinates = doc['location']['coordinates'] as List<dynamic>;
        if (coordinates.length >= 2) {
          final lat = (coordinates[1] as num).toDouble();
          final lng = (coordinates[0] as num).toDouble();
          location = 'Lat ${lat.toStringAsFixed(4)}, Lng ${lng.toStringAsFixed(4)}';
        }
      } catch (_) {}
    }

    return NotificationItem(
      title: title,
      location: location,
      status: status,
      floodHeight: floodHeight,
      timeAgo: timeAgo,
      isRead: false,
    );
  }

  /// Converts an ISO timestamp to a relative time string.
  String _formatTimestamp(String? timestamp) {
    if (timestamp == null || timestamp.isEmpty) return 'unknown';
    try {
      final dt = DateTime.parse(timestamp);
      final diff = DateTime.now().difference(dt);
      if (diff.inMinutes < 1) return 'just now';
      if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
      if (diff.inHours < 24) return '${diff.inHours} hr ago';
      return '${diff.inDays} day${diff.inDays > 1 ? 's' : ''} ago';
    } catch (_) {
      return 'unknown';
    }
  }

  List<NotificationItem> get _filtered {
    switch (_filterIndex) {
      case 1:
        return _notifications.where((n) => n.status == 'ALERT').toList();
      case 2:
        return _notifications.where((n) => n.status == 'DANGER').toList();
      default:
        return _notifications;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Notification+'),
        automaticallyImplyLeading: false,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.white),
            onPressed: () {
              setState(() => _isLoading = true);
              _loadNotifications();
            },
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Filter tabs (All / Unread) ──────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Row(
              children: [
                _FilterTab(
                  label: 'All',
                  selected: _filterIndex == 0,
                  onTap: () => setState(() => _filterIndex = 0),
                ),
                const SizedBox(width: 8),
                _FilterTab(
                  label: 'Alert',
                  selected: _filterIndex == 1,
                  onTap: () => setState(() => _filterIndex = 1),
                ),
                const SizedBox(width: 8),
                _FilterTab(
                  label: 'Danger',
                  selected: _filterIndex == 2,
                  onTap: () => setState(() => _filterIndex = 2),
                ),
              ],
            ),
          ),

          // ── Notification list ───────────────────────────────────────────────
          Expanded(
            child: _isLoading
                ? const Center(
                    child: CircularProgressIndicator(color: AppColors.primary),
                  )
                : _filtered.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.notifications_none,
                                size: 48, color: AppColors.textMuted),
                            const SizedBox(height: 12),
                            const Text('No notifications',
                              style: TextStyle(color: AppColors.textMuted, fontSize: 14)),
                          ],
                        ),
                      )
                    : RefreshIndicator(
                        onRefresh: _loadNotifications,
                        color: AppColors.primary,
                        child: ListView.builder(
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                          itemCount: _filtered.length,
                          itemBuilder: (_, i) => Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: _NotificationCard(item: _filtered[i]),
                          ),
                        ),
                      ),
          ),
        ],
      ),
    );
  }
}

// ── Filter Tab ────────────────────────────────────────────────────────────────

class _FilterTab extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _FilterTab({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? AppColors.primary : Colors.white,
          borderRadius: BorderRadius.circular(AppRadius.full),
          border: Border.all(
            color: selected ? AppColors.primary : const Color(0xFFE0E0E0),
            width: 1.2,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: selected ? Colors.white : AppColors.textMuted,
          ),
        ),
      ),
    );
  }
}

// ── Notification Card ─────────────────────────────────────────────────────────

class _NotificationCard extends StatelessWidget {
  final NotificationItem item;
  const _NotificationCard({required this.item});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(AppRadius.xl),
        border: Border.all(color: const Color(0xFFE8E8E8), width: 1),
        boxShadow: AppShadows.sm,
      ),
      clipBehavior: Clip.antiAlias,
      child: Row(
        children: [
          // Colored left border strip
          Container(
            width: 5,
            decoration: BoxDecoration(color: item.statusColor),
          ),
          const SizedBox(width: 12),

          // Content
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Title row with time
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        item.title,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF1A1A1A),
                        ),
                      ),
                      Text(
                        item.timeAgo,
                        style: const TextStyle(
                          fontSize: 11,
                          color: Color(0xFF999999),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),

                  // Location
                  Row(
                    children: [
                      const Icon(Icons.location_on_outlined,
                          size: 14, color: Color(0xFF999999)),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          item.location,
                          style: const TextStyle(
                            fontSize: 12,
                            color: Color(0xFF666666),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),

                  // Badges row
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      StatusBadge(status: item.status, pulse: true),
                      // Flood height badge
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(
                          color: const Color(0xFFE3F2FD),
                          borderRadius: BorderRadius.circular(AppRadius.sm),
                        ),
                        child: Text(
                          'Flood Height: ${item.floodHeight.toStringAsFixed(2)} m',
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF1565C0),
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
