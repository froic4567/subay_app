import 'package:flutter/material.dart';
import '../theme/app_colors.dart';

class RoutingScreen extends StatefulWidget {
  const RoutingScreen({super.key});

  @override
  State<RoutingScreen> createState() => _RoutingScreenState();
}

class _RoutingScreenState extends State<RoutingScreen> {
  final _destController = TextEditingController();
  bool _routeFound = false;

  @override
  void dispose() {
    _destController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final topPad = MediaQuery.of(context).padding.top;

    return Scaffold(
      body: Stack(
        children: [
          // ── MAP PLACEHOLDER ─────────────────────────────────────────────────
          // TODO: Replace with your actual map widget + route polyline overlay
          Container(
            color: const Color(0xFFE8E4D9),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: const [
                  Icon(Icons.map, size: 48, color: Color(0xFFBBBBBB)),
                  SizedBox(height: 8),
                  Text(
                    'Map with route line goes here',
                    style: TextStyle(color: Color(0xFF999999), fontSize: 12),
                  ),
                ],
              ),
            ),
          ),

          // ── SEARCH PANEL (top) ───────────────────────────────────────────────
          Positioned(
            top: topPad,
            left: 0,
            right: 0,
            child: Container(
              color: Colors.white,
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Origin
                  _SearchField(
                    hint: 'Your location',
                    readOnly: true,
                    prefixChild: Container(
                      margin: const EdgeInsets.all(12),
                      width: 12,
                      height: 12,
                      decoration: const BoxDecoration(
                        color: AppColors.normal,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                  // Dotted connector
                  Padding(
                    padding: const EdgeInsets.only(left: 21),
                    child: Column(
                      children: List.generate(3, (_) => Container(
                        width: 2, height: 3, margin: const EdgeInsets.symmetric(vertical: 1),
                        color: const Color(0xFFDDDDDD),
                      )),
                    ),
                  ),
                  // Destination
                  _SearchField(
                    hint: 'Where to?',
                    controller: _destController,
                    prefixIcon: Icons.location_on,
                    prefixIconColor: AppColors.danger,
                    onSubmitted: (_) => setState(() => _routeFound = true),
                    suffixIcon: _routeFound ? Icons.keyboard_arrow_down : null,
                  ),
                ],
              ),
            ),
          ),

          // ── ROUTE RESULT BOTTOM SHEET ────────────────────────────────────────
          if (_routeFound)
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: _RouteBottomSheet(
                onClose: () => setState(() => _routeFound = false),
              ),
            ),
        ],
      ),
    );
  }
}

// ── Search Field ──────────────────────────────────────────────────────────────

class _SearchField extends StatelessWidget {
  final String hint;
  final bool readOnly;
  final TextEditingController? controller;
  final IconData? prefixIcon;
  final Color? prefixIconColor;
  final Widget? prefixChild;
  final IconData? suffixIcon;
  final ValueChanged<String>? onSubmitted;

  const _SearchField({
    required this.hint,
    this.readOnly = false,
    this.controller,
    this.prefixIcon,
    this.prefixIconColor,
    this.prefixChild,
    this.suffixIcon,
    this.onSubmitted,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.backgroundSecondary,
        borderRadius: BorderRadius.circular(10),
      ),
      child: TextField(
        controller: controller,
        readOnly: readOnly,
        onSubmitted: onSubmitted,
        style: const TextStyle(fontSize: 13, color: AppColors.textPrimary),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: const TextStyle(color: AppColors.textMuted, fontSize: 13),
          prefixIcon: prefixChild != null
              ? prefixChild
              : (prefixIcon != null
                  ? Icon(prefixIcon, color: prefixIconColor, size: 18)
                  : null),
          prefixIconConstraints: const BoxConstraints(minWidth: 40),
          suffixIcon: suffixIcon != null
              ? Icon(suffixIcon!, color: AppColors.textMuted, size: 18)
              : null,
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
        ),
      ),
    );
  }
}

// ── Route Bottom Sheet ────────────────────────────────────────────────────────

class _RouteBottomSheet extends StatelessWidget {
  final VoidCallback onClose;
  const _RouteBottomSheet({required this.onClose});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 14)],
      ),
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Drag handle
          Center(
            child: Container(
              width: 32, height: 3,
              decoration: BoxDecoration(
                color: const Color(0xFFDDDDDD),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 10),

          // Title + distance pill
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: const [
                  Text('Safest Route Found',
                    style: TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary,
                    )),
                  SizedBox(height: 2),
                  Text('via Sergio Osmeña Ext.',
                    style: TextStyle(fontSize: 11, color: AppColors.textMuted)),
                ],
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: AppColors.normalLight,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  children: const [
                    Text('2.4 km',
                      style: TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w700,
                        color: Color(0xFF0F6E56),
                      )),
                    Text('~8 min',
                      style: TextStyle(fontSize: 10, color: Color(0xFF0F6E56))),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),

          // Stats pills row
          Row(
            children: [
              Expanded(child: _StatCard(
                icon: Icons.location_on_rounded,
                iconColor: AppColors.danger,
                bgColor: AppColors.dangerLight,
                label: 'Roads avoided',
                value: '1 flooded',
                textColor: AppColors.dangerText,
              )),
              const SizedBox(width: 6),
              Expanded(child: _StatCard(
                icon: Icons.water_drop_outlined,
                iconColor: AppColors.infoText,
                bgColor: AppColors.infoLight,
                label: 'Max water level',
                value: '18 cm',
                textColor: AppColors.infoText,
              )),
              const SizedBox(width: 6),
              Expanded(child: _StatCard(
                icon: Icons.check_circle_outline,
                iconColor: AppColors.normalText,
                bgColor: AppColors.normalLight,
                label: 'Route status',
                value: 'SAFE',
                textColor: AppColors.normalText,
              )),
            ],
          ),
          const SizedBox(height: 10),

          // Divider + avoided zones
          const Divider(thickness: 0.5, height: 1),
          const SizedBox(height: 8),
          const Text('Avoided flood zones',
            style: TextStyle(
              fontSize: 11, fontWeight: FontWeight.w600,
              color: AppColors.textSecondary,
            )),
          const SizedBox(height: 6),
          const _AvoidedZoneRow(
            name: 'Lapasan Highway',
            waterLevel: '87 cm',
            status: 'DANGER',
            dotColor: AppColors.danger,
            bgColor: AppColors.dangerLight,
            textColor: AppColors.dangerText,
          ),
          const SizedBox(height: 4),
          const _AvoidedZoneRow(
            name: 'Kauswagan Ave.',
            waterLevel: '52 cm',
            status: 'ALERT',
            dotColor: AppColors.alert,
            bgColor: AppColors.alertLight,
            textColor: AppColors.alertText,
          ),
          const SizedBox(height: 12),

          // Start Navigation button
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: () {},
              icon: const Icon(Icons.play_arrow_rounded, size: 18),
              label: const Text('Start Navigation',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
                padding: const EdgeInsets.symmetric(vertical: 13),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Stat Card ─────────────────────────────────────────────────────────────────

class _StatCard extends StatelessWidget {
  final IconData icon;
  final Color iconColor, bgColor, textColor;
  final String label, value;

  const _StatCard({
    required this.icon,
    required this.iconColor,
    required this.bgColor,
    required this.label,
    required this.value,
    required this.textColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 7),
      decoration: BoxDecoration(
        color: bgColor, borderRadius: BorderRadius.circular(8)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 13, color: iconColor),
          const SizedBox(width: 4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                  style: const TextStyle(fontSize: 9, color: AppColors.textMuted)),
                const SizedBox(height: 1),
                Text(value,
                  style: TextStyle(
                    fontSize: 11, fontWeight: FontWeight.w600, color: textColor)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Avoided Zone Row ──────────────────────────────────────────────────────────

class _AvoidedZoneRow extends StatelessWidget {
  final String name, waterLevel, status;
  final Color dotColor, bgColor, textColor;

  const _AvoidedZoneRow({
    required this.name,
    required this.waterLevel,
    required this.status,
    required this.dotColor,
    required this.bgColor,
    required this.textColor,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 8, height: 8,
          decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
        ),
        const SizedBox(width: 7),
        Expanded(
          child: Text(name,
            style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
          decoration: BoxDecoration(
            color: bgColor, borderRadius: BorderRadius.circular(5)),
          child: Text(
            '$waterLevel · $status',
            style: TextStyle(fontSize: 10, color: textColor),
          ),
        ),
      ],
    );
  }
}