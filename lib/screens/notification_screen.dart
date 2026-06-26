import 'package:flutter/material.dart';
import '../theme/app_colors.dart';

// ── Data model ────────────────────────────────────────────────────────────────

class NotificationItem {
  final String title;
  final String location;
  final String status; // 'NORMAL' | 'ALERT' | 'DANGER'
  final double floodHeight;
  final String timeAgo;
  final String transition; // e.g. 'ALERT → DANGER'
  final bool isRead;

  const NotificationItem({
    required this.title,
    required this.location,
    required this.status,
    required this.floodHeight,
    required this.timeAgo,
    required this.transition,
    this.isRead = false,
  });

  Color get statusColor {
    switch (status) {
      case 'DANGER': return AppColors.danger;
      case 'ALERT':  return AppColors.alert;
      default:       return AppColors.normal;
    }
  }

  Color get statusLightColor {
    switch (status) {
      case 'DANGER': return AppColors.dangerLight;
      case 'ALERT':  return AppColors.alertLight;
      default:       return AppColors.normalLight;
    }
  }

  Color get statusTextColor {
    switch (status) {
      case 'DANGER': return AppColors.dangerText;
      case 'ALERT':  return AppColors.alertText;
      default:       return AppColors.normalText;
    }
  }
}

// ── Sample notifications ──────────────────────────────────────────────────────

const _sampleNotifications = [
  NotificationItem(
    title: 'Flood DANGER detected',
    location: 'Lapasan Highway, CDO',
    status: 'DANGER',
    floodHeight: 87,
    timeAgo: '2 min ago',
    transition: 'ALERT → DANGER',
    isRead: false,
  ),
  NotificationItem(
    title: 'Flood ALERT detected',
    location: 'Macabalan, CDO',
    status: 'ALERT',
    floodHeight: 52,
    timeAgo: '15 min ago',
    transition: 'NORMAL → ALERT',
    isRead: false,
  ),
  NotificationItem(
    title: 'Area back to normal',
    location: 'Kauswagan, CDO',
    status: 'NORMAL',
    floodHeight: 18,
    timeAgo: '1 hr ago',
    transition: 'ALERT → NORMAL',
    isRead: true,
  ),
];

// ── Screen ────────────────────────────────────────────────────────────────────

class NotificationScreen extends StatefulWidget {
  const NotificationScreen({super.key});

  @override
  State<NotificationScreen> createState() => _NotificationScreenState();
}

class _NotificationScreenState extends State<NotificationScreen> {
  int _filterIndex = 0; // 0 = All, 1 = Unread

  List<NotificationItem> get _filtered => _filterIndex == 0
      ? _sampleNotifications
      : _sampleNotifications.where((n) => !n.isRead).toList();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Notification+'),
        automaticallyImplyLeading: false,
        actions: [
          IconButton(
            icon: const Icon(Icons.close, color: Colors.white),
            onPressed: () {},
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Filter tabs ─────────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
            child: Row(
              children: [
                _FilterTab(
                  label: 'All',
                  selected: _filterIndex == 0,
                  onTap: () => setState(() => _filterIndex = 0),
                ),
                const SizedBox(width: 8),
                _FilterTab(
                  label: 'Unread',
                  selected: _filterIndex == 1,
                  onTap: () => setState(() => _filterIndex = 1),
                ),
                const SizedBox(width: 8),
                _FilterTab(
                  label: 'Danger',
                  selected: _filterIndex == 2,
                  onTap: () => setState(() => _filterIndex = 2),
                  activeColor: AppColors.danger,
                ),
              ],
            ),
          ),

          // ── Notification list ───────────────────────────────────────────────
          Expanded(
            child: _filtered.isEmpty
                ? const Center(
                    child: Text('No notifications',
                      style: TextStyle(color: AppColors.textMuted, fontSize: 13)),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
                    itemCount: _filtered.length,
                    itemBuilder: (_, i) => Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: _NotificationCard(item: _filtered[i]),
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
  final Color? activeColor;

  const _FilterTab({
    required this.label,
    required this.selected,
    required this.onTap,
    this.activeColor,
  });

  @override
  Widget build(BuildContext context) {
    final bg = selected ? (activeColor ?? AppColors.primary) : Colors.white;
    final fg = selected ? Colors.white : AppColors.textMuted;

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected
                ? (activeColor ?? AppColors.primary)
                : const Color(0xFFDDDDDD)),
        ),
        child: Text(label,
          style: TextStyle(
            fontSize: 12, fontWeight: FontWeight.w500, color: fg)),
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
    return Opacity(
      opacity: item.isRead ? 0.72 : 1.0,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border(
            left:   BorderSide(color: item.statusColor, width: 4),
            top:    const BorderSide(color: Color(0xFFF0F0F0)),
            right:  const BorderSide(color: Color(0xFFF0F0F0)),
            bottom: const BorderSide(color: Color(0xFFF0F0F0)),
          ),
        ),
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Title + time
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Container(
                      width: 8, height: 8,
                      decoration: BoxDecoration(
                        color: item.isRead
                            ? const Color(0xFFCCCCCC)
                            : item.statusColor,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      item.title,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight:
                            item.isRead ? FontWeight.w500 : FontWeight.w700,
                        color: item.isRead
                            ? AppColors.textMuted
                            : AppColors.textPrimary,
                      ),
                    ),
                  ],
                ),
                Text(
                  item.timeAgo,
                  style: TextStyle(
                    fontSize: 10,
                    color: item.isRead
                        ? const Color(0xFFBBBBBB)
                        : AppColors.textMuted,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 5),

            // Location
            Row(
              children: [
                const Icon(Icons.location_on_outlined,
                  size: 12, color: AppColors.textMuted),
                const SizedBox(width: 3),
                Text(item.location,
                  style: const TextStyle(
                    fontSize: 12, color: AppColors.textSecondary)),
              ],
            ),
            const SizedBox(height: 8),

            // Pill badges
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                _Badge(
                  text: 'Status: ${item.status}',
                  bgColor: item.statusLightColor,
                  textColor: item.statusTextColor,
                ),
                _Badge(
                  text: 'Flood Height: ${item.floodHeight.toInt()} cm',
                  bgColor: AppColors.infoLight,
                  textColor: AppColors.infoText,
                ),
                _Badge(
                  text: item.transition,
                  bgColor: AppColors.backgroundSecondary,
                  textColor: AppColors.textSecondary,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ── Badge ─────────────────────────────────────────────────────────────────────

class _Badge extends StatelessWidget {
  final String text;
  final Color bgColor, textColor;

  const _Badge({required this.text, required this.bgColor, required this.textColor});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: bgColor, borderRadius: BorderRadius.circular(6)),
      child: Text(text,
        style: TextStyle(
          fontSize: 10, fontWeight: FontWeight.w500, color: textColor)),
    );
  }
}