// ----- lib/helpers/location_permission_helper.dart -----
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

class LocationPermissionHelper {
  static Future<bool> requestLocationPermissions(BuildContext context) async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      final shouldEnableService = await _showEnableLocationServiceDialog(context);
      if (shouldEnableService) {
        await Geolocator.openLocationSettings();
        // Give the user a moment to enable location services
        await Future.delayed(const Duration(seconds: 2));
        serviceEnabled = await Geolocator.isLocationServiceEnabled();
        if (!serviceEnabled) {
          return false;
        }
      } else {
        return false;
      }
    }
    
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      final shouldRequestPermission = await _showForegroundPermissionExplanationDialog(context);
      if (shouldRequestPermission) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          return false;
        }
      } else {
        return false;
      }
    }
    
    if (permission == LocationPermission.deniedForever) {
      final shouldOpenSettings = await _showPermissionsDeniedDialog(context);
      if (shouldOpenSettings) {
        await Geolocator.openAppSettings();
        return false; // User needs to manually grant it
      }
      return false;
    }
    
    // Specific handling for Android background permission
    if (Platform.isAndroid && permission == LocationPermission.whileInUse) {
      // Check if background permission is already granted
      LocationPermission backgroundPermission = await Geolocator.checkPermission();
      if (backgroundPermission != LocationPermission.always) {
        final shouldRequestBackground = await _showBackgroundPermissionExplanationDialog(context);
        if (shouldRequestBackground) {
          // Opening app settings is the way to prompt for "Allow all the time" on Android 10+
          await Geolocator.openAppSettings();
          await _showBackgroundInstructionsDialog(context);
          // We can't directly check if 'always' was granted after opening settings,
          // so we assume the user will follow instructions.
          // For a more robust solution, you might re-check permission after app resumes.
          return true;
        } else {
          await _showForegroundOnlyLimitationsDialog(context);
          return true; // User chose not to grant background, but foreground is still available
        }
      }
    }
    
    return true;
  }
  
  static Future<bool> _showEnableLocationServiceDialog(BuildContext context) async {
    return await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Location Services Disabled'),
          content: const Text(
            'VRE Watch needs location services to alert you about '
            'your proximity to stations. Please enable location services '
            'to continue.'
          ),
          actions: <Widget>[
            TextButton(
              child: const Text('CANCEL'),
              onPressed: () => Navigator.of(context).pop(false),
            ),
            TextButton(
              child: const Text('ENABLE'),
              onPressed: () => Navigator.of(context).pop(true),
            ),
          ],
        );
      },
    ) ?? false;
  }

  static Future<bool> requestOverlayPermission(BuildContext context) async {
    if (Platform.isAndroid) {
      final bool canDrawOverlays = await FlutterForegroundTask.canDrawOverlays;
      if (!canDrawOverlays) {
        final bool? shouldRequest = await showDialog<bool>(
          context: context,
          builder: (BuildContext context) {
            return AlertDialog(
              title: const Text('Overlay Permission'),
              content: const Text(
                  'VRE Watch can show alerts over other apps when you\'re '
                      'approaching stations. This is optional but recommended.'
              ),
              actions: <Widget>[
                TextButton(
                  child: const Text('NOT NOW'),
                  onPressed: () => Navigator.of(context).pop(false),
                ),
                TextButton(
                  child: const Text('GRANT'),
                  onPressed: () => Navigator.of(context).pop(true),
                ),
              ],
            );
          },
        );

        if (shouldRequest == true) {
          // Try to open app-specific settings first
          try {
            await Geolocator.openAppSettings();
          } catch (e) {
            // If that fails, try the system alert window settings
            await FlutterForegroundTask.openSystemAlertWindowSettings();
          }
        }
      }
    }
    return true;
  }
  static Future<bool> _showForegroundPermissionExplanationDialog(BuildContext context) async {
    return await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Location Permission Required'),
          content: const Text(
            'VRE Watch needs location permission to calculate your '
            'distance from train stations and provide timely alerts. '
            'Please grant location permission to continue.'
          ),
          actions: <Widget>[
            TextButton(
              child: const Text('CANCEL'),
              onPressed: () => Navigator.of(context).pop(false),
            ),
            TextButton(
              child: const Text('CONTINUE'),
              onPressed: () => Navigator.of(context).pop(true),
            ),
          ],
        );
      },
    ) ?? false;
  }
  
  static Future<bool> _showBackgroundPermissionExplanationDialog(BuildContext context) async {
    return await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Background Location Required'),
          content: const Text(
            'For VRE Watch to provide proximity alerts even when the app '
            'is not open, "Allow all the time" location permission '
            'is required.\n\n'
            'This permission is essential for getting alerts when '
            'approaching Rolling Road station.'
          ),
          actions: <Widget>[
            TextButton(
              child: const Text('NOT NOW'),
              onPressed: () => Navigator.of(context).pop(false),
            ),
            TextButton(
              child: const Text('CONTINUE'),
              onPressed: () => Navigator.of(context).pop(true),
            ),
          ],
        );
      },
    ) ?? false;
  }
  
  static Future<void> _showBackgroundInstructionsDialog(BuildContext context) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Grant "Allow all the time"'),
          content: const Text(
            'On the next screen, select VRE Watch from the list, '
            'then select "Allow all the time" option.\n\n'
            'This is necessary for alerting you when approaching '
            'stations even when the app is not actively open.'
          ),
          actions: <Widget>[
            TextButton(
              child: const Text('OK'),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
        );
      },
    );
  }
  
  static Future<void> _showForegroundOnlyLimitationsDialog(BuildContext context) async {
    await showDialog<void>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Limited Functionality'),
          content: const Text(
            'Without background location permission, VRE Watch can only '
            'track your location and provide alerts when the app is open '
            'and visible on your screen.\n\n'
            'You can change this later in your device settings if needed.'
          ),
          actions: <Widget>[
            TextButton(
              child: const Text('UNDERSTAND'),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
        );
      },
    );
  }
  
  static Future<bool> _showPermissionsDeniedDialog(BuildContext context) async {
    return await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Location Permission Denied'),
          content: const Text(
            'VRE Watch requires location permission to function properly. '
            'Please open Settings and enable location permission for this app.'
          ),
          actions: <Widget>[
            TextButton(
              child: const Text('CANCEL'),
              onPressed: () => Navigator.of(context).pop(false),
            ),
            TextButton(
              child: const Text('OPEN SETTINGS'),
              onPressed: () => Navigator.of(context).pop(true),
            ),
          ],
        );
      },
    ) ?? false;
  }
}
