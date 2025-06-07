import 'package:flutter/material.dart';


// [cite: 211] This line can remain if LocationConstants is still used, otherwise remove if not. Assuming it might be for battery icons or future use.

class TopInfoDisplayWidget extends StatelessWidget { // Renamed class
  final String displayDateTimeString; // Added
  final double currentLatitude;
  final double currentLongitude;
  // final String locationStatus; // Removed
  final String currentTrain;
  final String trackingMode;
  // final bool isServiceRunning; // Removed
  final double currentVolume;
  final String dayOffStatusText; // Added
  final int? batteryLevel; // [cite: 213]
  final String? batteryState;

  const TopInfoDisplayWidget({ // Renamed constructor
    super.key,
    required this.displayDateTimeString, // Added
    required this.currentLatitude,
    required this.currentLongitude,
    // required this.locationStatus, // Removed
    required this.currentTrain,
    required this.trackingMode,
    // required this.isServiceRunning, // Removed
    required this.currentVolume,
    required this.dayOffStatusText, // Added
    this.batteryLevel,
    this.batteryState,
  });

  IconData _getBatteryIcon(int? level, String? state) {
    if (state == 'charging') {
      return Icons.battery_charging_full;
    }
    if (level == null) return Icons.battery_unknown;
    if (level > 90) return Icons.battery_full;
    if (level > 70) return Icons.battery_5_bar;
    if (level > 50) return Icons.battery_4_bar;
    if (level > 30) return Icons.battery_3_bar;
    if (level > 10) return Icons.battery_2_bar;
    return Icons.battery_alert;
  }
  Color _getTrackingModeColor(String mode) {
    switch (mode) {
      case 'Morning':
      case 'Afternoon':
        return Colors.green; // Active tracking modes
      case 'Workday':
        return Colors.blue; // Work hours but no tracking
      case 'Day Off':
        return Colors.orange; // Day off
      case 'Inactive':
        return Colors.grey; // Inactive periods
      default:
        return Colors.black; // Default color
    }
  }
  @override
  Widget build(BuildContext context) {



    return Card(
      elevation: 5,
      margin: const EdgeInsets.symmetric(vertical: 10),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,

    children: [
    Text(
    displayDateTimeString, // Added
    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
    textAlign: TextAlign.center, // Consistent with how it was in main.dart
    ),
    const SizedBox(height: 8), // Added some spacing
    Text(
    'Location: ${currentLatitude.toStringAsFixed(4)}, ${currentLongitude.toStringAsFixed(4)}',
    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
    // Removed Status Message: $locationStatus
    Text(
    'Current Train: $currentTrain',
    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
    Text(
    'Tracking Mode: $trackingMode',
    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
      Text(
          'Status: $trackingMode',
          style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: _getTrackingModeColor(trackingMode)
          )),
    Text(
    'Current Volume: ${(currentVolume * 100).toStringAsFixed(0)}%',
    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
    // Added some spacing
    Text(
    dayOffStatusText, // Added
    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold), // Consistent with how it was in main.dart
    textAlign: TextAlign.center, // Consistent
    ),
    if (batteryLevel != null) ...[
    const SizedBox(height: 10),
    Row(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
    Icon(_getBatteryIcon(batteryLevel, batteryState)), // [cite: 222]
    const SizedBox(width: 8),
    Text(
    'Battery: $batteryLevel% ${batteryState != null ? '($batteryState)' : ''}', // [cite: 223]
    style: Theme.of(context).textTheme.titleMedium,
    ),
    ],
    ),
    ],
    ],

        )
      ),
    );
  }
}