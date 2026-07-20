import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'map_screen.dart';
import 'routing_screen.dart';
import 'notification_screen.dart';
import 'profile_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _currentIndex = 0;

  // Shared destination state passed from MapScreen → RoutingScreen
  LatLng? _pendingDestination;
  String? _pendingDestinationName;

  // Called by MapScreen when user searches a place and taps "Get Directions"
  void _goToRoutingWithDestination({LatLng? dest, String? destName}) {
    setState(() {
      _pendingDestination = dest;
      _pendingDestinationName = destName;
      _currentIndex = 1;
    });
  }

  @override
  Widget build(BuildContext context) {
    final List<Widget> screens = [
      MapScreen(onGoToRouteWithDestination: _goToRoutingWithDestination),
      RoutingScreen(
        initialDestination: _pendingDestination,
        initialDestinationName: _pendingDestinationName,
      ),
      const NotificationScreen(),
      const ProfileScreen(),
    ];

    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: screens,
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (i) => setState(() => _currentIndex = i),
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.map_outlined),
            activeIcon: Icon(Icons.map),
            label: 'Map',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.route_outlined),
            activeIcon: Icon(Icons.route),
            label: 'Routing',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.notifications_outlined),
            activeIcon: Icon(Icons.notifications),
            label: 'Notification',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.person_outline),
            activeIcon: Icon(Icons.person),
            label: 'Profile',
          ),
        ],
      ),
    );
  }
}