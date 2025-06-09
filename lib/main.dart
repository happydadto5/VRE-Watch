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
import 'utils/simulated_time.dart';

// App version
const String appVersion = '1.2.6';

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

  double _currentLatitude = 0.0; // Will be set by GPS
  double _currentLongitude = 0.0; // Will be set by GPS
  bool _hasRealGpsData = false; // Track if we have actual GPS data

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

  Map<String, double>? _currentTargetStationCoordinates;

  // --- UTC Handling ---
  DateTime _toUtc(DateTime dt) => dt.toUtc();
  DateTime _fromUtc(String iso) => DateTime.parse(iso).toLocal();

  // --- Missed Alerts Queue ---
  final List<String> _missedAlertsQueue = [];

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

    Future.delayed(const Duration(seconds: 2), () {
      _autoStartBackgroundService();
    });

    // Auto-select default train on app launch if none selected
    if (_currentTrain == "None") {
      _checkAndApplyAutomaticTrainDefaults();
    }
    // Always sync train state to background on app start
    _sendTrainStateToBackground();
  }

  void _autoStartBackgroundService() async {
    print('UI: *** AUTO-STARTING BACKGROUND SERVICE ***');
    _startBackgroundTracking();
  }

  void _testDirectGPS() async {
    print('UI: *** TESTING DIRECT GPS ***');
    try {
      final Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.bestForNavigation,
        timeLimit: const Duration(seconds: 10),
      );

      print(
          'UI: *** DIRECT GPS SUCCESS *** ${position.latitude}, ${position.longitude}');

      if (mounted) {
        setState(() {
          _currentLatitude = position.latitude;
          _currentLongitude = position.longitude;
          _hasRealGpsData = true;
        });
      }

      _showToast(
          'GPS: ${position.latitude.toStringAsFixed(4)}, ${position.longitude.toStringAsFixed(4)}');
    } catch (e) {
      print('UI: *** DIRECT GPS FAILED *** $e');
      _showToast('GPS Error: $e');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    VolumeController.instance.removeListener();
    flutterTts.stop();
    locationService.dispose();
    _dateTimeTimer?.cancel();
    _trainDefaultsTimer?.cancel(); // Cancel the new timer
    FlutterForegroundTask.removeTaskDataCallback(_onReceiveTaskData);
    super.dispose();
  }

  Future<void> _initVolumeController() async {
    _currentVolume = await VolumeController.instance.getVolume();
    VolumeController.instance.setVolume(0.7);
    VolumeController.instance.addListener((volume) {
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
      VolumeController.instance.setVolume(1.0);
      await flutterTts.speak(text);
    }
  }

  void _initForegroundTaskCommunication() {
    // Set up callback to receive GPS data from background service
    FlutterForegroundTask.addTaskDataCallback(_onReceiveTaskData);
    print('UI: *** DATA CALLBACK REGISTERED ***');
  }

  void _onReceiveTaskData(Object data) {
    if (data is Map<String, dynamic>) {
      print('UI: *** RECEIVED DATA FROM BACKGROUND *** $data');

      // Check background service version
      if (data.containsKey('backgroundServiceVersion')) {
        String bgVersion = data['backgroundServiceVersion'];
        print('UI: *** BACKGROUND SERVICE VERSION: $bgVersion ***');
      }

      if (mounted) {
        setState(() {
          // Update GPS coordinates from background service
          if (data.containsKey('latitude') && data.containsKey('longitude')) {
            double newLat = data['latitude'];
            double newLon = data['longitude'];
            if (newLat != 0.0 && newLon != 0.0) {
              _currentLatitude = newLat;
              _currentLongitude = newLon;
              _hasRealGpsData = true;
              print(
                  'UI: *** GPS UPDATED *** ${_currentLatitude.toStringAsFixed(4)}, ${_currentLongitude.toStringAsFixed(4)}');

              // Calculate and update distance immediately
              _updateDistanceToStation();
            }
          }

          // Update other data if needed
          if (data.containsKey('currentTrain')) {
            _currentTrain = data['currentTrain'];
            locationService.currentTrain = _currentTrain;
          }

          if (data.containsKey('trackingMode')) {
            _trackingMode = data['trackingMode'];
            _displayTrackingMode = _getDisplayTrackingMode(_trackingMode);
          }
        });
      }
    } else {
      print('UI: *** RECEIVED NON-MAP DATA *** $data');
    }
  }

  void _updateDistanceToStation() {
    if (!_hasRealGpsData) return;

    double distance = _getDistanceToStation();
    print('UI: *** DISTANCE UPDATED *** $distance miles');

    if (mounted) {
      setState(() {
        _locationStatus =
            "${distance.toStringAsFixed(1)} miles to ${_getTargetStationName()}";
      });
    }
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
    return SimulatedTime.getCurrentTime();
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
    // Force restart to ensure latest code is running
    print('UI: *** FORCE RESTARTING BACKGROUND SERVICE ***');
    await FlutterForegroundTask.stopService();
    await Future.delayed(Duration(seconds: 1)); // Wait a moment

    await FlutterForegroundTask.startService(
      notificationTitle: 'VRE Watch Active v1.0.5',
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

    print('DEBUG: _checkAndApplyAutomaticTrainDefaults called');
    print('DEBUG: now = $now');
    print('DEBUG: currentDateStr = $currentDateStr');
    print('DEBUG: _currentTrain = $_currentTrain');
    print('DEBUG: _morningDefaultAppliedDate = $_morningDefaultAppliedDate');
    print(
        'DEBUG: _afternoonDefaultAppliedDate = $_afternoonDefaultAppliedDate');

    // Don't apply defaults if we're in inactive mode (weekend or day off)
    if (now.weekday == DateTime.saturday || now.weekday == DateTime.sunday) {
      print('DEBUG: Weekend detected, skipping auto-selection.');
      if (_currentTrain != _trainNone) {
        await _switchToTrain(_trainNone, "Weekend mode - no train selected");
      }
      return;
    }

    // Reset applied dates if the day has changed
    if (_morningDefaultAppliedDate != currentDateStr) {
      print('DEBUG: Resetting _morningDefaultAppliedDate for new day.');
      _morningDefaultAppliedDate = null;
      await prefs.remove(LocationConstants.prefMorningDefaultAppliedDate);
    }
    if (_afternoonDefaultAppliedDate != currentDateStr) {
      print('DEBUG: Resetting _afternoonDefaultAppliedDate for new day.');
      _afternoonDefaultAppliedDate = null;
      await prefs.remove(LocationConstants.prefAfternoonDefaultAppliedDate);
    }

    // Morning default logic (5:30 AM to 8:00 AM)
    bool isMorningWindow =
        (now.hour == 5 && now.minute >= 30) || (now.hour > 5 && now.hour < 8);
    print('DEBUG: isMorningWindow = $isMorningWindow');

    if (isMorningWindow && _morningDefaultAppliedDate != currentDateStr) {
      print('DEBUG: In morning window and not yet applied today.');
      if (_currentTrain == _trainNone) {
        print('DEBUG: Switching to morning train $_trainMorning1');
        await _switchToTrain(_trainMorning1, "Auto-selected morning train 326");
        _morningDefaultAppliedDate = currentDateStr;
        await prefs.setString(
          LocationConstants.prefMorningDefaultAppliedDate,
          currentDateStr,
        );
      } else {
        print('DEBUG: _currentTrain is not None, skipping switch.');
      }
    }
    // Afternoon default logic (after 8:00 AM)
    else if (now.hour >= 8 && _afternoonDefaultAppliedDate != currentDateStr) {
      print('DEBUG: In afternoon window and not yet applied today.');
      if (_currentTrain == _trainNone) {
        print('DEBUG: Switching to afternoon train $_trainEvening1');
        await _switchToTrain(
            _trainEvening1, "Auto-selected afternoon train 331");
        _afternoonDefaultAppliedDate = currentDateStr;
        await prefs.setString(
          LocationConstants.prefAfternoonDefaultAppliedDate,
          currentDateStr,
        );
      } else {
        print('DEBUG: _currentTrain is not None, skipping switch.');
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

  void _setSimulatedTime(DateTime newSimulatedTime) {
    setState(() {
      simulatedStart = newSimulatedTime;
      _realTimeAtSimulationStart = DateTime.now();
      SimulatedTime.simulatedStart = newSimulatedTime;
      SimulatedTime.realTimeAtSimulationStart = _realTimeAtSimulationStart;
      _morningDefaultAppliedDate = null;
      _afternoonDefaultAppliedDate = null;
      _currentTrain = _trainNone;
      // Reset location-based reminder flags in background
      FlutterForegroundTask.sendDataToTask(
          {'action': 'resetLocationReminders'});
    });
    print('DEBUG: Simulated time set to $newSimulatedTime');
    if (simulatedStart != null && _realTimeAtSimulationStart != null) {
      FlutterForegroundTask.sendDataToTask({
        'action': 'updateSimulatedTime',
        'simulatedStart': simulatedStart!.toIso8601String(),
        'realTimeAtSimulationStart':
            _realTimeAtSimulationStart!.toIso8601String(),
        'simulationSpeedFactor': SimulatedTime.simulationSpeedFactor,
      });
    }
    _checkAndApplyAutomaticTrainDefaults();
    _sendTrainStateToBackground();
  }

  void _testTimeMondayMorning() {
    // Set simulated time to 5:28 AM Monday
    final now = DateTime.now();
    final int daysToMonday = (DateTime.monday - now.weekday) % 7;
    final DateTime nextMonday = now.add(Duration(days: daysToMonday));
    final DateTime mondayMorning = DateTime(
      nextMonday.year,
      nextMonday.month,
      nextMonday.day,
      5,
      28,
    );
    _setSimulatedTime(mondayMorning);
    // Reset applied dates and train selection for fresh testing
    setState(() {
      _morningDefaultAppliedDate = null;
      _afternoonDefaultAppliedDate = null;
      _currentTrain = _trainNone;
    });
    print('DEBUG: Test time set to Monday 5:28 AM, state reset.');
    _checkAndApplyAutomaticTrainDefaults();
  }

  Future<void> _testTimeToggle() async {
    if (simulatedStart == null) {
      // 1. Pick Date
      final DateTime? pickedDate = await showDatePicker(
        context: context,
        initialDate: DateTime.now(),
        firstDate: DateTime(2000),
        lastDate: DateTime(2101),
      );
      if (pickedDate == null) return;
      // 2. Pick Time
      final TimeOfDay? pickedTime = await showTimePicker(
        context: context,
        initialTime: TimeOfDay.fromDateTime(DateTime.now()),
        initialEntryMode: TimePickerEntryMode.input,
      );
      if (pickedTime == null) return;
      // 3. Combine Date and Time
      final DateTime newSimulatedStartTime = DateTime(
        pickedDate.year,
        pickedDate.month,
        pickedDate.day,
        pickedTime.hour,
        pickedTime.minute,
      );
      _setSimulatedTime(newSimulatedStartTime);
      _showToast(
        "Test time set to: " +
            DateFormat('EEE, MMM d, HH:mm').format(newSimulatedStartTime) +
            " (simulated)",
      );
    } else {
      setState(() {
        simulatedStart = null;
        _realTimeAtSimulationStart = null;
      });
      print('DEBUG: Test mode exited, reverted to real time.');
      _checkAndApplyAutomaticTrainDefaults();
      _showToast("Reverted to real time.");
    }
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

  Future<void> _switchToTrain(String newTrain, String reason) async {
    print('UI: *** SWITCHING TRAIN *** $newTrain - $reason');
    if (mounted) {
      setState(() {
        _currentTrain = newTrain;
      });
    }
    locationService.currentTrain = _currentTrain;
    _updateTargetStation();
    await _saveState();
    _showToast("Train set to: $_currentTrain");
    // Always sync train state to background after switch
    _sendTrainStateToBackground();
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

  String _getTargetStationName() {
    if (_currentTrain == "None") return "station";

    // Morning trains go to Union Station
    if (_currentTrain == _trainMorning1 || _currentTrain == _trainMorning2) {
      return "Union Station";
    }

    // Afternoon trains go to Rolling Road
    return "Rolling Road";
  }

  double _getDistanceToStation() {
    if (!_hasRealGpsData) return 0.0;

    // Get target station coordinates based on train
    Map<String, double> targetCoords;
    if (_currentTrain == _trainMorning1 || _currentTrain == _trainMorning2) {
      // Morning trains go to Union Station
      targetCoords = LocationConstants.unionStationCoordinates;
    } else if (_currentTrain == _trainEvening1 ||
        _currentTrain == _trainEvening2 ||
        _currentTrain == _trainEvening3) {
      // Afternoon trains go to Rolling Road
      targetCoords = LocationConstants.rollingRoadCoordinates;
    } else {
      return 0.0; // No train selected
    }

    // Calculate distance using Geolocator
    double distanceInMeters = Geolocator.distanceBetween(
        _currentLatitude,
        _currentLongitude,
        targetCoords['latitude']!,
        targetCoords['longitude']!);

    // Convert to miles
    return distanceInMeters * 0.000621371; // meters to miles conversion
  }

  void _updateTargetStation() {
    if (_currentTrain == _trainMorning1 || _currentTrain == _trainMorning2) {
      _currentTargetStationCoordinates =
          LocationConstants.unionStationCoordinates;
    } else if (_currentTrain == _trainEvening1 ||
        _currentTrain == _trainEvening2 ||
        _currentTrain == _trainEvening3) {
      _currentTargetStationCoordinates =
          LocationConstants.rollingRoadCoordinates;
    } else {
      _currentTargetStationCoordinates = null;
    }
  }

  void _sendTrainStateToBackground() {
    FlutterForegroundTask.sendDataToTask({
      'action': 'updateTrain',
      'currentTrain': _currentTrain,
      'trackingMode': _trackingMode,
    });
    print(
        'DEBUG: Sent train state to background: $_currentTrain, $_trackingMode');
  }

  Future<void> _resetSimulationState() async {
    // Reset all reminder flags in the background service
    locationService.acknowledgeAlert();
    // Optionally, clear any local state as well
    setState(() {
      // Reset any local flags or state variables here if needed
      _currentTrain = _trainNone;
      _trackingMode = 'Waiting';
      _displayTrackingMode = 'Initializing...';
      _locationStatus = 'Initializing...';
      _hasRealGpsData = false;
      _currentLatitude = 0.0;
      _currentLongitude = 0.0;
      _isServiceRunning = false;
      _dayOffDateTime = null;
      _morningDefaultAppliedDate = null;
      _afternoonDefaultAppliedDate = null;
      _currentTargetStationCoordinates = null;
    });
  }

  Future<void> _handleSimulatedTimeTravel() async {
    // Reset flags on backwards jumps
    if (simulatedStart != null && _realTimeAtSimulationStart != null) {
      if (simulatedStart!.isBefore(_realTimeAtSimulationStart!)) {
        await _resetSimulationState();
      }
    }
  }

  Future<void> _checkGpsAccuracy() async {
    // Re-check on accuracy improvement
    if (_hasRealGpsData) {
      // Logic to check GPS accuracy and adjust alerts
      final accuracy = await _getGpsAccuracy();
      if (accuracy < 10) {
        // Example threshold for accuracy
        // Delay alert until accuracy improves
        await Future.delayed(Duration(seconds: 5));
        await _checkGpsAccuracy(); // Recursive call to re-check
      } else {
        // Proceed with alert
        _triggerAlert();
      }
    }
  }

  Future<double> _getGpsAccuracy() async {
    // Logic to get GPS accuracy
    // This is a placeholder; replace with actual GPS accuracy retrieval logic
    return 5.0; // Example accuracy value
  }

  void _triggerAlert() {
    // Logic to trigger the alert
    // This is a placeholder; replace with actual alert logic
  }

  Future<void> _handleMissedAlerts() async {
    // Check for all missed events
    // Logic to handle missed alerts
    // This is a placeholder; replace with actual logic to handle missed alerts
  }

  Future<void> _persistState() async {
    // Persist and restore all state
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('currentTrain', _currentTrain);
    await prefs.setString('trackingMode', _trackingMode);
    await prefs.setString('displayTrackingMode', _displayTrackingMode);
    await prefs.setString('locationStatus', _locationStatus);
    await prefs.setBool('hasRealGpsData', _hasRealGpsData);
    await prefs.setDouble('currentLatitude', _currentLatitude);
    await prefs.setDouble('currentLongitude', _currentLongitude);
    await prefs.setBool('isServiceRunning', _isServiceRunning);
    if (_dayOffDateTime != null) {
      await prefs.setString(
          'dayOffDateTime', _dayOffDateTime!.toIso8601String());
    }
    await prefs.setString(
        'morningDefaultAppliedDate', _morningDefaultAppliedDate ?? '');
    await prefs.setString(
        'afternoonDefaultAppliedDate', _afternoonDefaultAppliedDate ?? '');
    if (_currentTargetStationCoordinates != null) {
      await prefs.setString('currentTargetStationCoordinates',
          _currentTargetStationCoordinates.toString());
    }
  }

  Future<void> _useUtcInternally() async {
    // Example: convert all relevant times to UTC before saving
    if (_dayOffDateTime != null) {
      _dayOffDateTime = _toUtc(_dayOffDateTime!);
    }
    if (simulatedStart != null) {
      simulatedStart = _toUtc(simulatedStart!);
    }
    if (_realTimeAtSimulationStart != null) {
      _realTimeAtSimulationStart = _toUtc(_realTimeAtSimulationStart!);
    }
    // Add more as needed
  }

  Future<void> _resetStateOnTrainModeChange() async {
    // Reset all state on change
    await _resetSimulationState();
    simulatedStart = null;
    _missedAlertsQueue.clear();
    // Reset any reminder flags here as well
  }

  Future<void> _queueMissedAlerts(String alert) async {
    // Queue or fallback for missed alerts
    _missedAlertsQueue.add(alert);
  }

  void _processMissedAlertsIfPossible() {
    if (_hasRealGpsData && _missedAlertsQueue.isNotEmpty) {
      for (final alert in _missedAlertsQueue) {
        _triggerAlertWithMessage(alert);
      }
      _missedAlertsQueue.clear();
    }
  }

  void _triggerAlertWithMessage(String message) {
    // Actual alert logic (e.g., show notification, TTS, etc.)
    _speak(message);
    // Add more alert logic as needed
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
                onPressed: _testDirectGPS,
                child: const Text('TESTING: Get GPS Now'),
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
                      ? 'TESTING: Stop GPS Service'
                      : 'TESTING: Restart GPS Service',
                ),
              ),
              const SizedBox(height: 10),
              ElevatedButton(
                onPressed: _checkAndApplyAutomaticTrainDefaults,
                child: const Text('DEBUG: Trigger Auto Train Selection'),
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
      hasRealGpsData: _hasRealGpsData,
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
  final bool hasRealGpsData;

  const TopInfoDisplayWidget({
    super.key,
    required this.displayDateTimeString,
    required this.currentTrain,
    required this.displayTrackingMode,
    required this.locationStatus,
    required this.currentLatitude,
    required this.currentLongitude,
    required this.dayOffStatusText,
    required this.hasRealGpsData,
  });

  String? _getDistanceToStation() {
    // Only show distance in morning or afternoon mode
    if (displayTrackingMode != LocationConstants.trackingModeMorning &&
        displayTrackingMode != LocationConstants.trackingModeAfternoon) {
      return null;
    }

    // Check if we have real GPS data
    if (!hasRealGpsData) {
      return "No GPS location";
    }

    // Determine which station to use based on tracking mode
    Map<String, double> targetStation;
    if (displayTrackingMode == LocationConstants.trackingModeMorning) {
      targetStation = LocationConstants.unionStationCoordinates;
    } else {
      targetStation = LocationConstants.rollingRoadCoordinates;
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
