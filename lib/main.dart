import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:volume_controller/volume_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:geolocator/geolocator.dart';
import 'package:url_launcher/url_launcher.dart';
import 'helpers/location_permission_helper.dart';
import 'services/location_service.dart';
import 'widgets/location_status_widget.dart';
import 'constants/location_constants.dart';
import 'package:flutter_foreground_task/models/notification_channel_importance.dart';
import 'package:flutter_foreground_task/models/notification_priority.dart';

// App version
const String appVersion = '1.0.2';

@pragma('vm:entry-point')
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Flutter Foreground Task
  FlutterForegroundTask.initCommunicationPort();
  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: 'vre_watch_channel',
      channelName: 'VRE Watch Service',
      channelDescription:
          'This notification is used for the VRE Watch service.',
      channelImportance: NotificationChannelImportance.DEFAULT,
      priority: NotificationPriority.DEFAULT,
    ),
    iosNotificationOptions: const IOSNotificationOptions(
      showNotification: true,
      playSound: false,
    ),
    foregroundTaskOptions: ForegroundTaskOptions(
      eventAction: ForegroundTaskEventAction.repeat(5000),
      autoRunOnBoot: false,
      allowWakeLock: true,
      allowWifiLock: true,
    ),
  );

  FlutterForegroundTask.setTaskHandler(LocationTaskHandler());
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return const MaterialApp(home: LocationScreen());
  }
}

class LocationScreen extends StatefulWidget {
  const LocationScreen({super.key});
  @override
  State<LocationScreen> createState() => _LocationScreenState();
}

class _LocationScreenState extends State<LocationScreen>
    with WidgetsBindingObserver {
  LocationService locationService = LocationService.instance;

  // Train constants
  static const String _trainMorning1 = "326";
  static const String _trainMorning2 = "328";
  static const String _trainEvening3 = "329";
  static const String _trainEvening1 = "331";
  static const String _trainEvening2 = "333";
  static const String _trainNone = "None";

  final double _currentLatitude = 38.8075; // Near Rolling Road area for testing
  final double _currentLongitude =
      -77.2653; // Near Rolling Road area for testing

  String _locationStatus = "Initializing...";
  String _currentTrain = "None";
  String _trackingMode = "Waiting";
  bool _isServiceRunning = false;
  String _displayTrackingMode = "Initializing...";
  //DateTime? _lastAcknowledgedAlertTime;
  double _currentVolume = 0.0;
  String _displayDateTimeString = "";
  Timer? _dateTimeTimer;
  Timer? _trainDefaultsTimer; // Timer for checking automatic train defaults
  FlutterTts flutterTts = FlutterTts();

  DateTime? simulatedStart;
  DateTime? _dayOffDateTime; // To store the user's selected day off date

  DateTime? _realTimeAtSimulationStart; // Tracks when simulation was activated

  String? _morningDefaultAppliedDate; // Tracks YYYY-MM-DD
  String? _afternoonDefaultAppliedDate; // Tracks YYYY-MM-DD

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initTts();
    _initVolumeController();
    _initForegroundTaskCommunication();
    _checkAndRequestPermissions();
    _loadState();

    _updateDisplayDateTime();
    _dateTimeTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
      if (mounted) {
        _updateDisplayDateTime();
      }
    });
    _startOrRestartTrainDefaultsTimer();
    _startBackgroundTracking();
    // Auto-select default train on app launch if none selected
    if (_currentTrain == "None") {
      _checkAndApplyAutomaticTrainDefaults();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    VolumeController().removeListener();
    flutterTts.stop();
    locationService.dispose();
    _dateTimeTimer?.cancel();
    _trainDefaultsTimer?.cancel(); // Cancel the new timer
    super.dispose();
  }

  Future<void> _initVolumeController() async {
    _currentVolume = await VolumeController().getVolume();
    VolumeController().setVolume(0.7);
    VolumeController().listener((volume) {
      if (mounted) {
        setState(() {
          _currentVolume = volume;
        });
      }
    });
  }

  Future<void> _initTts() async {
    await flutterTts.setLanguage("en-US");
    await flutterTts.setPitch(1.0);
    await flutterTts.setSpeechRate(0.8);
  }

  Future<void> _speak(String text) async {
    if (text.isNotEmpty) {
      VolumeController().setVolume(1.0);
      await flutterTts.speak(text);
    }
  }

  void _initForegroundTaskCommunication() {
    // No-op for v7.0.0; communication is handled via TaskHandler
  }

  Future<void> _checkAndRequestPermissions() async {
    bool hasPermission =
        await LocationPermissionHelper.requestLocationPermissions(context);
    // Also request overlay permission for better alerts
    await LocationPermissionHelper.requestOverlayPermission(context);
    if (mounted) {
      setState(() {
        // Only show status if permission was denied
        if (!hasPermission) {
          _locationStatus = "Location permission denied";
        } else {
          _locationStatus = ""; // Clear status when everything is fine
        }
      });
    }
  }

  Future<void> _loadState() async {
    final prefs = await SharedPreferences.getInstance();
    locationService.trainThreshold =
        prefs.getDouble(LocationConstants.prefTrainThreshold) ??
            LocationConstants.defaultTrainThreshold;
    locationService.stationThreshold =
        prefs.getDouble(LocationConstants.prefStationThreshold) ??
            LocationConstants.defaultStationThreshold;
    locationService.proximityThreshold =
        prefs.getDouble(LocationConstants.prefProximityThreshold) ??
            LocationConstants.defaultProximityThreshold;
    locationService.mondayMorningTime =
        prefs.getString(LocationConstants.prefMondayMorningTime) ??
            LocationConstants.defaultMondayMorningTime;
    locationService.returnHomeTime =
        prefs.getString(LocationConstants.prefReturnHomeTime) ??
            LocationConstants.defaultReturnHomeTime;
    locationService.sleepReminderTime =
        prefs.getString(LocationConstants.prefSleepReminderTime) ??
            LocationConstants.defaultSleepReminderTime;
    locationService.currentTrain =
        prefs.getString(LocationConstants.prefCurrentTrain) ?? _trainNone;
    locationService.trackingMode =
        prefs.getString(LocationConstants.prefTrackingMode) ?? "Waiting";
    await locationService.loadState();

    String? dayOffDateStr = prefs.getString(LocationConstants.prefDayOffDate);

    _morningDefaultAppliedDate = prefs.getString(
      LocationConstants.prefMorningDefaultAppliedDate,
    );
    _afternoonDefaultAppliedDate = prefs.getString(
      LocationConstants.prefAfternoonDefaultAppliedDate,
    );
    if (dayOffDateStr != null && dayOffDateStr.isNotEmpty) {
      try {
        // Assuming YYYY-MM-DD format from SharedPreferences
        List<String> parts = dayOffDateStr.split('-');
        if (parts.length == 3) {
          _dayOffDateTime = DateTime(
            int.parse(parts[0]), // year
            int.parse(parts[1]), // month
            int.parse(parts[2]), // day
          );
        }
      } catch (e) {
        print('Error parsing dayOffDateStr: $e');
        _dayOffDateTime = null; // Reset if parsing fails
      }
    } else {
      _dayOffDateTime = null;
    }
    _displayTrackingMode = _getDisplayTrackingMode(_trackingMode);
  }

  Future<void> _saveState() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(LocationConstants.prefCurrentTrain, _currentTrain);
    await prefs.setString(LocationConstants.prefTrackingMode, _trackingMode);

    await locationService.saveState();
    _showToast("Settings saved.");
  }

  Future<void> _updateAndSaveDayOffState(DateTime? newDayOffDate) async {
    if (!mounted) return;

    setState(() {
      _dayOffDateTime = newDayOffDate;
    });

    final prefs = await SharedPreferences.getInstance();
    String? isoDateString;
    if (newDayOffDate != null) {
      isoDateString =
          "${newDayOffDate.year}-${newDayOffDate.month.toString().padLeft(2, '0')}-${newDayOffDate.day.toString().padLeft(2, '0')}";
      await prefs.setString(LocationConstants.prefDayOffDate, isoDateString);
      _showToast(
        "Day off set to: ${DateFormat('EEE, MMM d').format(newDayOffDate)}",
      );
    } else {
      await prefs.remove(LocationConstants.prefDayOffDate);
      _showToast("Day off cleared.");
    }

    // Notify the background service
    // FlutterForegroundTask.sendDataToTask({
    //   'action': 'updateDayOffDate',
    //   'dayOffDate': isoDateString, // This will be null if newDayOffDate is null
    // });
  } // This closes _updateAndSaveDayOffState correctly

  // Ensure _getCurrentTimeForLogic is defined at the class level

  DateTime _getCurrentTimeForLogic() {
    if (simulatedStart != null && _realTimeAtSimulationStart != null) {
      final Duration elapsedRealTime = DateTime.now().difference(
        _realTimeAtSimulationStart!,
      );
      const double simulationSpeedFactor =
          45.0; // Fixed 45x speed factor (3x faster than previous 15x)
      final int acceleratedMilliseconds =
          (elapsedRealTime.inMilliseconds * simulationSpeedFactor).round();
      return simulatedStart!.add(
        Duration(milliseconds: acceleratedMilliseconds),
      );
    }
    return DateTime.now();
  }

  DateTime _calculateNextBusinessDay(DateTime fromDate) {
    DateTime nextDay = fromDate.add(const Duration(days: 1));
    // Loop until we find a weekday (Monday to Friday)
    while (nextDay.weekday == DateTime.saturday ||
        nextDay.weekday == DateTime.sunday) {
      nextDay = nextDay.add(const Duration(days: 1));
    }
    return nextDay;
  }

  void _setOffToday() {
    final DateTime today = DateTime.now();
    // Ensure we are only using the date part by creating a new DateTime object
    _updateAndSaveDayOffState(DateTime(today.year, today.month, today.day));
  }

  void _setOffTomorrow() {
    final DateTime today = DateTime.now();
    final DateTime nextBusinessDay = _calculateNextBusinessDay(today);
    _updateAndSaveDayOffState(nextBusinessDay);
  }

  void _clearDayOff() {
    _updateAndSaveDayOffState(null); // Pass null to clear the date

    // Determine current time using the helper
    final DateTime timeToConsider = _getCurrentTimeForLogic();
    String newTrain;

    if (timeToConsider.hour < 8) {
      // Before 8 AM
      newTrain = _trainMorning1; // Default morning train "326"
    } else {
      // 8 AM or later
      newTrain = _trainEvening1; // Default afternoon train "331"
    }

    if (mounted) {
      setState(() {
        _currentTrain = newTrain;
      });
      locationService.currentTrain = _currentTrain;
      _showToast("Day off cleared. Train automatically set to: $_currentTrain");
      _saveState(); // Save the new train state

      // Notify the background service of the train change
      // FlutterForegroundTask.sendDataToTask({
      //   'action': 'updateTrain',
      //   'currentTrain': _currentTrain,
      // });
    }
  }

  void _startBackgroundTracking() async {
    if (!_isServiceRunning) {
      await FlutterForegroundTask.startService(
        notificationTitle: 'VRE Watch Active',
        notificationText: 'Tracking location for $_currentTrain',
        callback: startCallback,
      );
      FlutterForegroundTask.sendDataToTask({
        'train': _currentTrain,
        'trackingMode': _trackingMode,
      });
      if (mounted) {
        setState(() {
          _isServiceRunning = true;
        });
      }
    }
  }

  void _stopBackgroundTracking() async {
    if (_isServiceRunning) {
      await FlutterForegroundTask.stopService();
      if (mounted) {
        setState(() {
          _isServiceRunning = false;
        });
      }
    }
  }

  void _showAlert(String title, String message) {
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              locationService.acknowledgeAlert();
            },
            child: const Text('Acknowledge'),
          ),
        ],
      ),
    );
  }

  void _showToast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _checkAndApplyAutomaticTrainDefaults() async {
    if (!mounted) return;

    final DateTime now = _getCurrentTimeForLogic();
    final String currentDateStr = DateFormat('yyyy-MM-dd').format(now);
    final SharedPreferences prefs = await SharedPreferences.getInstance();

    // Don't apply defaults if we're in inactive mode (weekend or day off)
    if (now.weekday == DateTime.saturday || now.weekday == DateTime.sunday) {
      if (_currentTrain != _trainNone) {
        await _switchToTrain(_trainNone, "Weekend mode - no train selected");
      }
      return;
    }

    // Reset applied dates if the day has changed
    if (_morningDefaultAppliedDate != null &&
        _morningDefaultAppliedDate != currentDateStr) {
      if (mounted) {
        setState(() {
          _morningDefaultAppliedDate = null;
        });
      }
      await prefs.remove(LocationConstants.prefMorningDefaultAppliedDate);
      print(
        "UI: Reset morning default applied date for new day: $currentDateStr",
      );
    }
    if (_afternoonDefaultAppliedDate != null &&
        _afternoonDefaultAppliedDate != currentDateStr) {
      if (mounted) {
        setState(() {
          _afternoonDefaultAppliedDate = null;
        });
      }
      await prefs.remove(LocationConstants.prefAfternoonDefaultAppliedDate);
      print(
        "UI: Reset afternoon default applied date for new day: $currentDateStr",
      );
    }

    // Morning default logic:
    // Apply if it's between 5:30 AM (inclusive) and 12:00 PM (exclusive)
    // and morning default has not yet been applied today.
    bool isMorningWindow =
        (now.hour == 5 && now.minute >= 30) || (now.hour > 5 && now.hour < 12);
    if (isMorningWindow) {
      if (_morningDefaultAppliedDate != currentDateStr) {
        print(
          "UI: Processing morning auto train switch check for $currentDateStr (time: ${now.hour}:${now.minute.toString().padLeft(2, '0')}). Current train: $_currentTrain",
        );
        if (_currentTrain == _trainNone ||
            _currentTrain == _trainEvening1 ||
            _currentTrain == _trainEvening2 ||
            _currentTrain == _trainEvening3) {
          await _switchToTrain(
            _trainMorning1,
            "Defaulted to morning train: $_trainMorning1 at ${now.hour}:${now.minute.toString().padLeft(2, '0')}",
          );
        }
        // Mark as applied for today
        if (mounted) {
          setState(() {
            _morningDefaultAppliedDate = currentDateStr;
          });
        }
        await prefs.setString(
          LocationConstants.prefMorningDefaultAppliedDate,
          currentDateStr,
        );
        print(
          "UI: Morning default for $currentDateStr (train $_trainMorning1) processed and marked at ${now.hour}:${now.minute.toString().padLeft(2, '0')}.",
        );
      }
    }

    // Afternoon default logic:
    // Apply if it's 12:00 PM (noon) or later
    // and afternoon default has not yet been applied today.
    if (now.hour >= 12) {
      if (_afternoonDefaultAppliedDate != currentDateStr) {
        print(
          "UI: Processing afternoon auto train switch check for $currentDateStr (time: ${now.hour}:${now.minute.toString().padLeft(2, '0')}). Current train: $_currentTrain",
        );
        if (_currentTrain == _trainNone ||
            _currentTrain == _trainMorning1 ||
            _currentTrain == _trainMorning2) {
          await _switchToTrain(
            _trainEvening1,
            "Defaulted to afternoon train: $_trainEvening1 at ${now.hour}:${now.minute.toString().padLeft(2, '0')}",
          );
        }
        // Mark as applied for today
        if (mounted) {
          setState(() {
            _afternoonDefaultAppliedDate = currentDateStr;
          });
        }
        await prefs.setString(
          LocationConstants.prefAfternoonDefaultAppliedDate,
          currentDateStr,
        );
        print(
          "UI: Afternoon default for $currentDateStr (train $_trainEvening1) processed and marked at ${now.hour}:${now.minute.toString().padLeft(2, '0')}.",
        );
      }
    }
  }

  Future<void> _updateDisplayDateTime() async {
    // Made async
    if (mounted) {
      // Ensure widget is still mounted before async operations
      await _checkAndApplyAutomaticTrainDefaults();
    }
    // Update display tracking mode based on current time
    _updateDisplayTrackingModeFromTime();
    // Proceed with updating the display string only if still mounted after the await
    if (!mounted) return;
    final DateTime currentTimeToDisplay = _getCurrentTimeForLogic();

    // Send current simulated/real time to background service
    // FlutterForegroundTask.sendDataToTask({
    //   'action': 'updateEffectiveTime',
    //   'effectiveTime': currentTimeToDisplay.toIso8601String(),
    // });

    if (mounted) {
      setState(() {
        // Determine if current time is within "Working" hours (8:00 AM to 3:29 PM)
        int currentHour = currentTimeToDisplay.hour;
        int currentMinute = currentTimeToDisplay.minute;
        // True if 8:00 <= time < 15:30 (3:30 PM)
        bool isWorkingHours = (currentHour >= 8 && currentHour < 15) ||
            (currentHour == 15 && currentMinute < 30);

        // Update the display string for time
        if (simulatedStart != null) {
          // Prefix is based on whether simulation mode is active
          _displayDateTimeString =
              "(TEST) Time: ${DateFormat('EEE HH:mm').format(currentTimeToDisplay)}";
        } else {
          _displayDateTimeString =
              "Time: ${DateFormat('EEE HH:mm').format(currentTimeToDisplay)}";
        }
      });
    }
  }

  void _updateDisplayTrackingModeFromTime() {
    final DateTime now = _getCurrentTimeForLogic();
    String newMode;

    // Check if it's weekend
    if (now.weekday == DateTime.saturday || now.weekday == DateTime.sunday) {
      newMode = LocationConstants.trackingModeInactive;
    }
    // Check if it's a day off
    else if (_dayOffDateTime != null) {
      final String currentDateIso =
          "${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}";
      final String dayOffIso =
          "${_dayOffDateTime!.year}-${_dayOffDateTime!.month.toString().padLeft(2, '0')}-${_dayOffDateTime!.day.toString().padLeft(2, '0')}";
      if (dayOffIso == currentDateIso && now.hour < 20) {
        newMode = LocationConstants.trackingModeDayOff;
      } else {
        newMode = _calculateTimeBasedMode(now);
      }
    } else {
      newMode = _calculateTimeBasedMode(now);
    }

    if (mounted) {
      setState(() {
        _displayTrackingMode = _getDisplayTrackingMode(newMode);
      });
    }
  }

  String _calculateTimeBasedMode(DateTime now) {
    bool isMorningTime = (now.hour == LocationConstants.morningModeStartHour &&
            now.minute >= LocationConstants.morningModeStartMinute) ||
        (now.hour > LocationConstants.morningModeStartHour &&
            now.hour < LocationConstants.morningModeEndHour);

    bool isWorkdayTime = now.hour >= LocationConstants.morningModeEndHour &&
        now.hour < LocationConstants.workdayModeEndHour;

    bool isAfternoonTime = now.hour >= LocationConstants.afternoonModeStartHour;

    if (isMorningTime) {
      return LocationConstants.trackingModeMorning;
    } else if (isWorkdayTime) {
      return LocationConstants.trackingModeWorkday;
    } else if (isAfternoonTime) {
      return LocationConstants.trackingModeAfternoon;
    } else {
      return LocationConstants.trackingModeInactive;
    }
  }

  void _toggleTrain() {
    if (mounted) {
      setState(() {
        final DateTime timeToConsider = _getCurrentTimeForLogic();
        final bool isMorning =
            timeToConsider.hour < 13; // Before 1 PM is considered morning

        if (isMorning) {
          // Morning cycle: 326 -> 328 -> 326 ...
          // If current is "None" or an evening train, start with 326.
          if (_currentTrain == _trainMorning1) {
            // Currently 326
            _currentTrain = _trainMorning2; // Switch to 328
          } else if (_currentTrain == _trainMorning2) {
            // Currently 328
            _currentTrain = _trainMorning1; // Loop back to 326
          } else {
            // This covers _trainNone or if an evening train was somehow selected
            _currentTrain =
                _trainMorning1; // Default to first morning train (326)
          }
        } else {
          // Afternoon/Evening
          // Afternoon cycle: 329 -> 331 -> 333 -> 329 ...
          // _trainEvening3 is "329"
          // _trainEvening1 is "331"
          // _trainEvening2 is "333"
          if (_currentTrain == _trainEvening3) {
            // Currently 329
            _currentTrain = _trainEvening1; // Switch to 331
          } else if (_currentTrain == _trainEvening1) {
            // Currently 331
            _currentTrain = _trainEvening2; // Switch to 333
          } else if (_currentTrain == _trainEvening2) {
            // Currently 333
            _currentTrain = _trainEvening3; // Loop back to 329
          } else {
            // This covers _trainNone or if a morning train was somehow selected
            _currentTrain =
                _trainEvening3; // Default to first afternoon train (329)
          }
        }
        locationService.currentTrain = _currentTrain; // Update service instance
        _showToast("Switched to train: $_currentTrain");
      });
      _saveState(); // This will call _showToast("Settings saved.")
      // FlutterForegroundTask.sendDataToTask({
      //   'action': 'updateTrain',
      //   'currentTrain': _currentTrain,
      // });
    }
  }

  void _testTimeToggle() async {
    if (!mounted) return;

    if (simulatedStart == null) {
      // 1. Pick Date
      final DateTime? pickedDate = await showDatePicker(
        context: context,
        initialDate: DateTime.now(),
        firstDate: DateTime(2000), // Or a suitable past date
        lastDate: DateTime(2101), // Or a suitable future date
      );

      if (pickedDate == null) return; // User cancelled date picker

      // 2. Pick Time (Important: ensure context is still valid if you have complex navigation)
      final TimeOfDay? pickedTime = await showTimePicker(
        context: context,
        initialTime: TimeOfDay.fromDateTime(DateTime.now()),
        initialEntryMode: TimePickerEntryMode
            .input, // Ensures 1-minute precision via text input
      );

      if (pickedTime == null) return; // User cancelled time picker

      // 3. Combine Date and Time
      final DateTime newSimulatedStartTime = DateTime(
        pickedDate.year,
        pickedDate.month,
        pickedDate.day,
        pickedTime.hour,
        pickedTime.minute,
      );

      setState(() {
        simulatedStart = newSimulatedStartTime;
        _realTimeAtSimulationStart =
            DateTime.now(); // Store real time when simulation starts
        _updateDisplayDateTime(); // Update display immediately
      });
      // Update toast message to include date and time
      _showToast(
        "Test time set to: ${DateFormat('EEE, MMM d, HH:mm').format(newSimulatedStartTime)} (simulated)",
      );
      _startOrRestartTrainDefaultsTimer();
    } else {
      setState(() {
        simulatedStart = null;
        _realTimeAtSimulationStart = null; // Clear real time tracker
        _updateDisplayDateTime();
      });
      _showToast("Reverted to real time.");
      _startOrRestartTrainDefaultsTimer();
    }
  }

  void _testTimeMondayMorning() async {
    if (!mounted) return;

    // Find the next Monday (or use current date if already Monday)
    DateTime now = DateTime.now();
    DateTime nextMonday = now;

    // If it's not Monday, find the next Monday
    if (now.weekday != DateTime.monday) {
      int daysUntilMonday = DateTime.monday - now.weekday;
      if (daysUntilMonday <= 0) {
        daysUntilMonday += 7; // Next week's Monday
      }
      nextMonday = now.add(Duration(days: daysUntilMonday));
    }

    // Set to 5:28 AM on that Monday
    final DateTime mondayMorningTime = DateTime(
      nextMonday.year,
      nextMonday.month,
      nextMonday.day,
      5, // 5 AM
      28, // 28 minutes
    );

    setState(() {
      simulatedStart = mondayMorningTime;
      _realTimeAtSimulationStart =
          DateTime.now(); // Store real time when simulation starts
      _updateDisplayDateTime(); // Update display immediately
    });

    _showToast(
      "Test time set to: ${DateFormat('EEE, MMM d, HH:mm').format(mondayMorningTime)} (simulated)",
    );
    _startOrRestartTrainDefaultsTimer();
  }

  void _updateAll() {
    if (mounted) {
      _loadState();
      _updateDisplayDateTime();

      _showToast("Data refreshed.");
    }
  }

  void _startOrRestartTrainDefaultsTimer() {
    _trainDefaultsTimer?.cancel(); // Cancel existing timer if any

    final Duration timerDuration = (simulatedStart == null)
        ? const Duration(seconds: 30) // Real time: 30 seconds
        : const Duration(seconds: 5); // Simulated time: 5 seconds

    print(
      "Scheduling automatic train defaults check every ${timerDuration.inSeconds} seconds.",
    );
    _trainDefaultsTimer = Timer.periodic(timerDuration, (timer) {
      if (mounted) {
        // Ensure widget is still mounted
        _checkAndApplyAutomaticTrainDefaults();
      }
    });
  }

  Future<void> _switchToTrain(String newTrain, String toastMessage) async {
    if (!mounted) return;
    bool trainChanged = _currentTrain != newTrain;

    setState(() {
      _currentTrain = newTrain;
      // Don't override _trackingMode here - let the background service manage it
    });
    locationService.currentTrain = _currentTrain;

    if (trainChanged) {
      _showToast(toastMessage);
      await _saveState(); // This will save the updated _currentTrain and the (potentially temporary) _trackingMode
      // FlutterForegroundTask.sendDataToTask({
      //   'action': 'updateTrain',
      //   'currentTrain': _currentTrain,
      // });
    }
  }

  String _getDisplayTrackingMode(String trackingMode) {
    // Map internal tracking modes to user-friendly display names
    switch (trackingMode) {
      case LocationConstants.trackingModeDayOff:
        return "Day Off";
      case LocationConstants.trackingModeMorning:
        return "Morning";
      case LocationConstants.trackingModeWorkday:
        return "Workday";
      case LocationConstants.trackingModeAfternoon:
        return "Afternoon";
      case LocationConstants.trackingModeInactive:
        return "Inactive";
      default:
        return trackingMode; // Fallback for any unknown modes
    }
  }

  String _getFormattedTrainDisplayString() {
    String time24;
    String label;

    switch (_currentTrain) {
      case _trainMorning1: // "326"

        time24 = LocationConstants.departureTimeTrain326; // "06:29"
        label = "Early";
        break;
      case _trainMorning2: // "328"
        time24 = LocationConstants.departureTimeTrain328; // "06:49"
        label = "Later";
        break;
      case _trainEvening1: // "331"
        time24 = LocationConstants.departureTimeTrain331; // "17:10"
        label = "Normal";
        break;
      case _trainEvening2: // "333"
        time24 = LocationConstants.departureTimeTrain333; // "17:30"
        label = "Late";
        break;
      case _trainEvening3: // "329"
        time24 = LocationConstants.departureTimeTrain329; // "16:10"
        label = "Early";
        break;
      case _trainNone: // "None"
        return "None";
      default:
        return _currentTrain; // Fallback for any unknown train numbers
    }

    List<String> parts = time24.split(':');
    int hour = int.parse(parts[0]);
    String minute = parts[1];

    // Convert to 12-hour format for display
    if (hour >= 12) {
      // Handles 12:xx PM and 13:xx to 23:xx
      if (hour > 12) {
        hour -= 12;
      }
    } else if (hour == 0) {
      // Handles 00:xx (midnight)
      hour = 12;
    }
    // Morning hours (1-11 AM) remain as is (e.g., 06:29 becomes 6:29 after int.parse)

    String formattedTime = "$hour:$minute";

    return "$_currentTrain - $label ($formattedTime)";
  }

  void _updateTrainAndTracking(String train, String trackingMode) {
    setState(() {
      _currentTrain = train;
      _trackingMode = trackingMode;
      _displayTrackingMode = _getDisplayTrackingMode(trackingMode);
    });
    _saveState();
    if (_isServiceRunning) {
      FlutterForegroundTask.sendDataToTask({
        'train': train,
        'trackingMode': trackingMode,
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // Variable to hold the display string for day off status
    String dayOffStatusText = _dayOffDateTime == null
        ? 'Day Off: None set'
        : 'Day Off Set For: ${DateFormat('EEE, MMM d').format(_dayOffDateTime!)}';

    return Scaffold(
      appBar: AppBar(title: const Text('VRE Watch')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: AbsorbPointer(
          absorbing: false, // Assuming you want interaction enabled
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _buildTopInfoDisplay(),

              const Divider(), // Separator after the top info block
              // --- Core Action Buttons ---
              ElevatedButton(
                onPressed: _toggleTrain,
                child: const Text('Switch Train'),
              ),
              const SizedBox(height: 10),
              ElevatedButton(
                onPressed: () async {
                  const url = 'https://www.vre.org/train-status/';
                  if (await canLaunchUrl(Uri.parse(url))) {
                    await launchUrl(
                      Uri.parse(url),
                      mode: LaunchMode.externalApplication,
                    );
                  }
                },
                child: const Text('VRE Status'),
              ),
              const SizedBox(height: 10),

              if (_dayOffDateTime != null) ...[
                ElevatedButton(
                  onPressed: _clearDayOff,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.orange,
                  ),
                  child: const Text("Clear Day Off"),
                ),
              ] else ...[
                Row(
                  children: [
                    const Text("Day Off? ", style: TextStyle(fontSize: 16)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: _setOffToday,
                        child: const Text("Today"),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: _setOffTomorrow,
                        child: const Text("Tomorrow"),
                      ),
                    ),
                  ],
                ),
              ],

              const SizedBox(height: 10),
              const Divider(), // Separator before the testing/service controls
              // --- Testing & Service Controls ---
              Text(
                // For the separated "Status Message"
                'Status Message: $_locationStatus',
                style: const TextStyle(fontSize: 16),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                // For the separated "Service Status"
                'Service Status: ${_isServiceRunning ? 'Running' : 'Stopped'}',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: _isServiceRunning ? Colors.green : Colors.red,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 10),
              ElevatedButton(
                onPressed: _testTimeToggle,
                child: Text(
                  simulatedStart == null
                      ? 'Set Test Time'
                      : 'Revert to Real Time',
                ),
              ),
              const SizedBox(height: 10),
              ElevatedButton(
                onPressed: _testTimeMondayMorning,
                child: const Text('Test Time to Monday AM'),
              ),
              const SizedBox(height: 10),
              ElevatedButton(
                onPressed: _isServiceRunning
                    ? _stopBackgroundTracking
                    : _startBackgroundTracking,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _isServiceRunning
                      ? Colors.red
                      : Colors.green, // Using green for "Start"
                ),
                child: Text(
                  _isServiceRunning
                      ? 'Stop Background Tracking'
                      : 'Start Background Tracking',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTopInfoDisplay() {
    String dayOffStatusText = _dayOffDateTime == null
        ? 'Day Off: None set'
        : 'Day Off Set For: ${DateFormat('EEE, MMM d').format(_dayOffDateTime!)}';

    return TopInfoDisplayWidget(
      displayDateTimeString: _displayDateTimeString,
      currentTrain: _getFormattedTrainDisplayString(),
      displayTrackingMode: _displayTrackingMode,
      locationStatus: _locationStatus,
      currentLatitude: _currentLatitude,
      currentLongitude: _currentLongitude,
      dayOffStatusText: dayOffStatusText,
    );
  }
}

class TopInfoDisplayWidget extends StatelessWidget {
  final String displayDateTimeString;
  final String currentTrain;
  final String displayTrackingMode;
  final String locationStatus;
  final double currentLatitude;
  final double currentLongitude;
  final String dayOffStatusText;

  const TopInfoDisplayWidget({
    super.key,
    required this.displayDateTimeString,
    required this.currentTrain,
    required this.displayTrackingMode,
    required this.locationStatus,
    required this.currentLatitude,
    required this.currentLongitude,
    required this.dayOffStatusText,
  });

  String? _getDistanceToStation() {
    // Only show distance in morning or afternoon mode
    if (displayTrackingMode != LocationConstants.trackingModeMorning &&
        displayTrackingMode != LocationConstants.trackingModeAfternoon) {
      return null;
    }

    // Determine which station to use based on tracking mode
    Map<String, double> targetStation;
    if (displayTrackingMode == LocationConstants.trackingModeMorning) {
      targetStation = LocationConstants
          .unionStation; // Fixed: Morning trains go TO Union Station
    } else {
      targetStation = LocationConstants
          .rollingRoadStation; // Fixed: Afternoon trains go TO Rolling Road
    }

    // Calculate distance in meters
    double distanceInMeters = Geolocator.distanceBetween(
      currentLatitude,
      currentLongitude,
      targetStation['latitude']!,
      targetStation['longitude']!,
    );

    // Convert to miles and format to 1 decimal place
    double distanceInMiles = distanceInMeters * LocationConstants.metersToMiles;
    return '${distanceInMiles.toStringAsFixed(1)} miles';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(8.0),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.7),
        borderRadius: BorderRadius.circular(8.0),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            displayDateTimeString,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Train: $currentTrain',
            style: const TextStyle(color: Colors.white, fontSize: 14),
          ),
          const SizedBox(height: 4),
          Text(
            'Mode: $displayTrackingMode',
            style: const TextStyle(color: Colors.white, fontSize: 14),
          ),
          if (_getDistanceToStation() != null) ...[
            const SizedBox(height: 4),
            Text(
              'Distance: ${_getDistanceToStation()}',
              style: const TextStyle(color: Colors.white, fontSize: 14),
            ),
          ],
          const SizedBox(height: 4),
          Text(
            dayOffStatusText,
            style: const TextStyle(color: Colors.white, fontSize: 14),
          ),
          const SizedBox(height: 4),
          Text(
            locationStatus,
            style: const TextStyle(color: Colors.white, fontSize: 14),
          ),
          const SizedBox(height: 4),
          const Text(
            'v$appVersion',
            style: TextStyle(color: Colors.grey, fontSize: 12),
          ),
        ],
      ),
    );
  }
}
