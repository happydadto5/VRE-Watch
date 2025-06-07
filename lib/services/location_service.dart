import 'package:flutter/material.dart';
import 'dart:async';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:volume_controller/volume_controller.dart';
import '../helpers/location_permission_helper.dart';

import '../constants/location_constants.dart';

@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(LocationTaskHandler());
}

class LocationTaskHandler extends TaskHandler {
  Timer? _timer;
  final int _updateInterval = LocationConstants.mediumUpdateFrequency;
  DateTime? _lastVibrationTime;
  bool _hasAcknowledgedAlert = true;
  String _currentTrain = "None";
  String _trackingMode = "Waiting";
  late FlutterTts _flutterTts;
  double? _originalVolume;
  bool _rollingRoadAlertTriggered = false;
  bool _unionStationAlertTriggered = false;

  final Battery _battery = Battery();
  DateTime _lastCheckedDateForReminders = DateTime.now();

  final Set<String> _todaysIssuedReminders = <String>{};
  int _currentUpdateIntervalMillis =
      LocationConstants.mediumUpdateFrequency; // Initialize with a default
  Map<String, double>? _currentTargetStationCoordinates;
  String? _dayOffDateIsoString; // To store the ISO string of the user's day off
  DateTime _effectiveCurrentTime = DateTime.now(); // Initialize with real time
  Timer? _rollingRoadRepeatTimer;
  bool _rollingRoadAlertRepeated = false;
  bool _twoMileAlertIssuedForRollingRoad = false;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    print('LocationTaskHandler onStart: $timestamp');

    _flutterTts = FlutterTts();
    await _flutterTts.setSharedInstance(true);
// Initialize tracking mode based on current time
    await _updateTrackingModeBasedOnTime();

    await _flutterTts.setSpeechRate(0.5);
    await _flutterTts.setVolume(1.0);
    // Store original volume to restore later if needed
    _originalVolume = await VolumeController().getVolume();
    // Set volume to max for all announcements
    VolumeController().setVolume(1.0);
    _lastCheckedDateForReminders = DateTime.now(); // Add this line

    await _initFromPrefs(); // _currentTrain is now loaded
    _updateTargetStation(); // Set initial target based on loaded train
// Auto-set default train on service start if none selected
    if (_currentTrain == "None") {
      _updateTrackingModeBasedOnTime(); // This will trigger auto-train selection
    }
    // Determine initial interval based on target or default if no train
    int initialIntervalMillis = LocationConstants.mediumUpdateFrequency;
    if (_currentTrain == "None" || _currentTargetStationCoordinates == null) {
      initialIntervalMillis = LocationConstants.intervalFarMillis;
    } else if (_trackingMode == "RollingRoadAlerted" ||
        _trackingMode == "UnionStationAlerted") {
      initialIntervalMillis = LocationConstants.intervalPostArrivalMillis;
    }
    // For other cases, _updateLocation will calculate the adaptive interval on its first run.
    // We use _changeUpdateInterval to set it up.
    _changeUpdateInterval(initialIntervalMillis);
    _updateLocation(); // Call once immediately to perform initial checks and adapt interval if needed.
    // _changeUpdateInterval already starts the periodic timer.
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    print('LocationTaskHandler onRepeatEvent: $timestamp');
    _updateLocation();
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    print('LocationTaskHandler onDestroy: $timestamp, isTimeout: $isTimeout');
    _timer?.cancel();
    await _flutterTts.stop();
    if (_originalVolume != null) {
      VolumeController().setVolume(_originalVolume!);
    }
  }

  @override
  void onReceiveData(Object data) async {
    print('LocationTaskHandler onReceiveData: $data');
    if (data is Map<String, dynamic>) {
      final String? action = data['action'] as String?;
      if (action == LocationConstants.actionAcknowledge) {
        // [cite: 76]
        acknowledgeAlert();
      } else if (action == 'updateTrain') {
        final String? newTrain = data['currentTrain'] as String?;

        if (newTrain != null && _currentTrain != newTrain) {
          print(
              'LocationTaskHandler: Updating currentTrain to $newTrain (was $_currentTrain)');
          _currentTrain = newTrain;

          _todaysIssuedReminders.clear();
          print(
              'LocationTaskHandler: Cleared today\'s issued reminders due to train change.');

          _updateTrackingModeBasedOnTime(); // Update mode based on current time
          _cancelRollingRoadRepeatTimer();
          _rollingRoadAlertRepeated = false;
          _twoMileAlertIssuedForRollingRoad = false;

          _updateTargetStation(); // Update target for new train
          // Set a default active interval; _updateLocation will then adapt it.
          _changeUpdateInterval(LocationConstants.mediumUpdateFrequency);
          await _saveState(); // Save new train and tracking mode
          // --- START CODE TO INSERT ---
          // Immediately send the confirmed new state back to the UI
          FlutterForegroundTask.sendDataToMain({
            'currentTrain': _currentTrain, // Send the updated _currentTrain
            'trackingMode': _trackingMode, // Send the updated _trackingMode
            // We assume the service is running if this callback is active.
            'isServiceRunning': true,
          });
          print(
              'LocationTaskHandler: Sent confirmed train update to UI: $_currentTrain');
          // --- END CODE TO INSERT ---
        }
      } else if (action == 'updateDayOffDate') {
        _dayOffDateIsoString = data['dayOffDate'] as String?;
        // When day off changes, also clear today's issued reminders as the context might change
        _todaysIssuedReminders.clear();
        print(
            'LocationTaskHandler: Updated dayOffDate to $_dayOffDateIsoString and cleared reminders.');
      } else if (action == 'updateEffectiveTime') {
        print('LTH_ONRECEIVE: action=updateEffectiveTime');
        final String? timeStr = data['effectiveTime'] as String?;
        if (timeStr != null) {
          print('LTH_ONRECEIVE: effectiveTime string received: $timeStr');
          final DateTime? newEffectiveTime = DateTime.tryParse(timeStr);
          if (newEffectiveTime != null) {
            print(
                'LTH_ONRECEIVE: Parsed newEffectiveTime: ${newEffectiveTime.toIso8601String()}');
            bool dayChanged =
                _effectiveCurrentTime.year != newEffectiveTime.year ||
                    _effectiveCurrentTime.month != newEffectiveTime.month ||
                    _effectiveCurrentTime.day != newEffectiveTime.day;

            _effectiveCurrentTime = newEffectiveTime;
            print(
                'LTH_ONRECEIVE: _effectiveCurrentTime updated to: ${_effectiveCurrentTime.toIso8601String()}, dayChanged: $dayChanged');

            if (dayChanged) {
              print(
                  'LTH_ONRECEIVE: Effective day changed. Clearing reminders. Old _lastCheckedDateForReminders: ${_lastCheckedDateForReminders.toIso8601String()}');
              print(
                  'LocationTaskHandler: Effective day changed via UI update to ${_effectiveCurrentTime.toIso8601String()}. Forcing reminder state refresh.');
              _todaysIssuedReminders.clear();
              _lastCheckedDateForReminders = _effectiveCurrentTime;
              print(
                  'LTH_ONRECEIVE: New _lastCheckedDateForReminders: ${_lastCheckedDateForReminders.toIso8601String()}');
            }
          }
        }
      }
    }
  }

  Future<void> _checkAndIssueDepartureReminders() async {
    print(
        'LTH_REMINDERS: Entered. EffectiveTime: ${_effectiveCurrentTime.toIso8601String()}, CurrentTrain: $_currentTrain, LastCheckedDay: ${_lastCheckedDateForReminders.toIso8601String()}, TodaysIssued: ${_todaysIssuedReminders.toString()}');
    final DateTime now = _effectiveCurrentTime; // Use the time sent from UI
    print(
        'LTH_REMINDERS: Using "now" as: ${now.toIso8601String()} for checks.');

    await _checkAndApplyAutomaticTrainDefaultsInBackground(now);

    // 1. Weekday Check: Only operate on Monday-Friday
    if (now.weekday < DateTime.monday || now.weekday > DateTime.friday) {
      print(
          'LTH_REMINDERS: Exiting due to weekday check. now.weekday: ${now.weekday}');

      // It's a weekend, so no reminders.
      // Optionally, clear reminders if you want a clean slate for Monday,
      // though the day change logic below should handle it.
      // print('Weekend: No departure reminders.');
      return;
    }

// Check if the day has changed, if so, reset issued reminders
    // This check is now more robustly handled when _effectiveCurrentTime is updated
    // from the UI, especially for large jumps in simulated time.
    // However, keeping a similar check here based on 'now' (which is _effectiveCurrentTime)
    // ensures consistency if onRepeatEvent is the primary trigger.

    DateTime currentDateOnly = DateTime(now.year, now.month, now.day);
    DateTime lastCheckedDateOnly = DateTime(_lastCheckedDateForReminders.year,
        _lastCheckedDateForReminders.month, _lastCheckedDateForReminders.day);

    if (!currentDateOnly.isAtSameMomentAs(lastCheckedDateOnly)) {
      print(
          'Effective day changed to $currentDateOnly (was $lastCheckedDateOnly). Clearing issued reminders.');
      _todaysIssuedReminders.clear();
      _lastCheckedDateForReminders =
          now; // Update with the 'now' that represents the current effective day
    }
    print(
        'LTH_REMINDERS: Passed weekday & day change logic. Current _todaysIssuedReminders: ${_todaysIssuedReminders.toString()}');

// 2. "Day Off" Check
    if (_dayOffDateIsoString != null && _dayOffDateIsoString!.isNotEmpty) {
      final String currentDateIso =
          "${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}";
      if (_dayOffDateIsoString == currentDateIso) {
        // It is the designated "Day Off"
        if (now.hour >= 20) {
          // Check if it's 8 PM (20:00) or later
          await _autoClearDayOffSetting(); // Call the new method to clear the day off
          // After clearing, we should still return to prevent further reminder processing for this tick
          // as the day off state has just been reset.
          print(
              'LTH_REMINDERS: Exiting due to Day Off (past 8 PM, day off cleared).');
          return;
        } else {
          // It's the day off, but before 8 PM. Suppress reminders.
          print(
              'User is off today ($_dayOffDateIsoString) and it is before 8 PM. No departure reminders.');
          _todaysIssuedReminders.clear();
          print(
              'LTH_REMINDERS: Exiting due to Day Off (before 8 PM). DayOffISO: $_dayOffDateIsoString');
          return;
        }
      }
      // Optional: If _dayOffDateIsoString is for a past date (and somehow wasn't cleared),
      // you could add logic here to clear it too. For now, focusing on end-of-day clearing.
    }
    if (_currentTrain == "None") {
      return; // No reminders if no train is selected
    }
    print('LTH_REMINDERS: Passed Day Off check.');

    String departureTimeStr;
    int getReadyLeadMinutes;
    int catchTrainLeadMinutes;
    bool isMorningTrain;

    // Determine train details based on _currentTrain
    switch (_currentTrain) {
      case "326":
        departureTimeStr = LocationConstants.departureTimeTrain326;
        getReadyLeadMinutes = LocationConstants.morningGetReadyLeadTimeMinutes;
        catchTrainLeadMinutes =
            LocationConstants.morningCatchTrainLeadTimeMinutes;
        isMorningTrain = true;
        break;
      case "328":
        departureTimeStr = LocationConstants.departureTimeTrain328;
        getReadyLeadMinutes = LocationConstants.morningGetReadyLeadTimeMinutes;
        catchTrainLeadMinutes =
            LocationConstants.morningCatchTrainLeadTimeMinutes;
        isMorningTrain = true;
        break;
      case "331":
        departureTimeStr = LocationConstants.departureTimeTrain331;
        getReadyLeadMinutes =
            LocationConstants.afternoonGetReadyLeadTimeMinutes;
        catchTrainLeadMinutes =
            LocationConstants.afternoonCatchTrainLeadTimeMinutes;
        isMorningTrain = false;
        break;
      case "333":
        departureTimeStr = LocationConstants.departureTimeTrain333;
        getReadyLeadMinutes =
            LocationConstants.afternoonGetReadyLeadTimeMinutes;
        catchTrainLeadMinutes =
            LocationConstants.afternoonCatchTrainLeadTimeMinutes;
        isMorningTrain = false;
        break;
      case "329":
        departureTimeStr = LocationConstants.departureTimeTrain329;
        getReadyLeadMinutes =
            LocationConstants.afternoonGetReadyLeadTimeMinutes;
        catchTrainLeadMinutes =
            LocationConstants.afternoonCatchTrainLeadTimeMinutes;
        isMorningTrain = false;
        break;
      default:
        // Unknown train, do nothing
        return;
    }

    // Parse departure time
    final List<String> timeParts = departureTimeStr.split(':');
    if (timeParts.length != 2) return; // Invalid format

    final int hour = int.tryParse(timeParts[0]) ?? -1;
    final int minute = int.tryParse(timeParts[1]) ?? -1;

    if (hour == -1 || minute == -1) return; // Invalid time parts

    final DateTime departureDateTime =
        DateTime(now.year, now.month, now.day, hour, minute);
// Define reminder keys
    final String getReadyKey = "${_currentTrain}_getReady";
    final String catchTrainKey = "${_currentTrain}_catchTrain";
    final String turnOffAndCatchTrainKey =
        "${_currentTrain}_turnOffAndCatchTrain"; // New key

// --- Check "Get Ready to leave" Reminder ---
    final DateTime getReadyReminderTime =
        departureDateTime.subtract(Duration(minutes: getReadyLeadMinutes));
    if (!_todaysIssuedReminders.contains(getReadyKey) &&
        !now.isBefore(getReadyReminderTime) &&
        now.isBefore(departureDateTime)) {
      print('Issuing "Get Ready" reminder for train $_currentTrain');
      VolumeController().setVolume(1.0);
      await _flutterTts.speak(LocationConstants.reminderMsgGetReady);
      _todaysIssuedReminders.add(getReadyKey);
    }

    // --- Check "Catch Train" Reminder ---
    final DateTime catchTrainReminderTime =
        departureDateTime.subtract(Duration(minutes: catchTrainLeadMinutes));
    if (!_todaysIssuedReminders.contains(catchTrainKey) &&
        !now.isBefore(catchTrainReminderTime) &&
        now.isBefore(departureDateTime)) {
      print('Issuing "Catch Train" reminder for train $_currentTrain');
      VolumeController().setVolume(1.0);

      // Use different messages for morning vs afternoon trains
      if (isMorningTrain) {
        await _flutterTts.speak(LocationConstants.reminderMsgLeaveHouse);
      } else {
        await _flutterTts.speak(LocationConstants.reminderMsgCatchTrain);
      }

      _todaysIssuedReminders.add(catchTrainKey);
    }

    // --- Check "Turn off and Catch Train" Reminder (Morning Trains Only) ---
    if (isMorningTrain) {
      final DateTime turnOffAndCatchTrainReminderTime =
          departureDateTime.subtract(const Duration(
              minutes: LocationConstants
                  .morningTurnOffAndCatchTrainLeadTimeMinutes));
      if (!_todaysIssuedReminders.contains(turnOffAndCatchTrainKey) &&
          !now.isBefore(turnOffAndCatchTrainReminderTime) &&
          now.isBefore(departureDateTime)) {
        print(
            'Issuing "Turn off and Catch Train" reminder for train $_currentTrain');
        VolumeController().setVolume(1.0);
        await _flutterTts
            .speak(LocationConstants.reminderMsgTurnOffAndCatchTrain);
        _todaysIssuedReminders.add(turnOffAndCatchTrainKey);
      }
    }
  }

  Future<void> _autoClearDayOffSetting() async {
    print(
        'LocationTaskHandler: Automatically clearing Day Off setting as it is past 8 PM.');
    _dayOffDateIsoString = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(LocationConstants.prefDayOffDate);
    _todaysIssuedReminders
        .clear(); // Clear any reminders that might have been relevant for the day off

    // Notify the UI that the day off was automatically cleared
    FlutterForegroundTask.sendDataToMain({
      'action': 'dayOffAutomaticallyCleared',
      'dayOffDate': null // Explicitly send null for the date
    });
  }

  @override
  void onNotificationButtonPressed(String id) {
    print('LocationTaskHandler onNotificationButtonPressed: $id');
  }

  @override
  void onNotificationPressed() {
    print('LocationTaskHandler onNotificationPressed');
  }

  @override
  void onNotificationDismissed() {
    print('LocationTaskHandler onNotificationDismissed');
  }

  Future<void> _initFromPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _currentTrain = prefs.getString('currentTrain') ?? "None";
      _trackingMode = prefs.getString('trackingMode') ?? "Waiting";

      print(
          'Initialized from prefs: currentTrain=$_currentTrain, trackingMode=$_trackingMode');
      _dayOffDateIsoString = prefs.getString(LocationConstants.prefDayOffDate);
    } catch (e) {
      print('Error initializing from prefs: $e');
    }
  }

  Future<void> _updateLocation() async {
    print('LTH_UPDATE_LOC: Calling _checkAndIssueDepartureReminders...');
    await _checkAndIssueDepartureReminders();
    try {
      // Update tracking mode based on current time and conditions
      _updateTrackingModeBasedOnTime();

      // Only perform location tracking during Morning and Afternoon modes
      if (_trackingMode != LocationConstants.trackingModeMorning &&
          _trackingMode != LocationConstants.trackingModeAfternoon) {
        print('Location tracking skipped. Current mode: $_trackingMode');
        return;
      }

      // Check if location services are still enabled
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        print('Location services disabled');
        return;
      }

      final Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.bestForNavigation,
        timeLimit: const Duration(seconds: 10),
      );
      print('Current position: ${position.latitude}, ${position.longitude}');

      FlutterForegroundTask.sendDataToMain({
        'latitude': position.latitude,
        'longitude': position.longitude,
        'speed': position.speed * LocationConstants.metersPerSecondToMph,
        'heading': position.heading,
        'currentTrain': _currentTrain,
        'trackingMode': _trackingMode,
        'isServiceRunning': true,
      });

      final bool isCloseToRollingRoad = _isWithinRadius(
          position,
          LocationConstants.rollingRoadStation,
          LocationConstants.rollingRoadAlertRadius);
      final bool isCloseToKingStreet = _isWithinRadius(
          position,
          LocationConstants.kingStreetStation,
          LocationConstants.kingStreetAlertRadius);

      // ... (inside _updateLocation method)

      // This is the existing check for Rolling Road (trains "331" || "333"), leave it as is:
      final bool isAfternoonTrain = _currentTrain == "331" ||
          _currentTrain == "333" ||
          _currentTrain == "329";
      final bool isMorningTrain =
          _currentTrain == "326" || _currentTrain == "328";

      // Use the locally defined isCloseToRollingRoad if needed, or re-evaluate if not available in this scope
      // For clarity, we'll use the variable defined earlier in the method if it's still in scope
      // final bool isCloseToRollingRoad = _isWithinRadius(position, LocationConstants.rollingRoadStation, LocationConstants.rollingRoadAlertRadius);
      // The variable 'isCloseToRollingRoad' was defined at line and should still be in scope.

      if (isAfternoonTrain &&
          _trackingMode == LocationConstants.trackingModeAfternoon) {
        final bool isCurrentlyWithin1MileRadiusRR =
            isCloseToRollingRoad; // Re-using the variable from line
        final bool isCurrentlyWithin2MilesRR = _isWithinRadius(
            position,
            LocationConstants.rollingRoadStation,
            LocationConstants.distance2MilesMeters);

        // 2-mile beep logic for Rolling Road
        if (isCurrentlyWithin2MilesRR &&
            !isCurrentlyWithin1MileRadiusRR &&
            !_twoMileAlertIssuedForRollingRoad) {
          print(
              'LocationTaskHandler: Approaching 2 miles from Rolling Road. Requesting beep.');
          FlutterForegroundTask.sendDataToMain({
            'action': LocationConstants.actionPlayBeep,
            // Use the new action from constants
          });
          _twoMileAlertIssuedForRollingRoad = true;
        }
        // Reset 2-mile flag if we move out of 2-mile zone before 1-mile alert
        else if (!isCurrentlyWithin2MilesRR &&
            _twoMileAlertIssuedForRollingRoad) {
          _twoMileAlertIssuedForRollingRoad = false;
          print(
              'LocationTaskHandler: Moved out of 2-mile Rolling Road radius before 1-mile alert. Resetting 2-mile toast flag.');
        }

        // 1-mile alert and repeat logic for Rolling Road

        if (isCurrentlyWithin1MileRadiusRR && !_rollingRoadAlertTriggered) {
          print(
              'LocationTaskHandler: Approaching 1 mile from Rolling Road. Triggering alert.');
          await _triggerAlert('Approaching station!');
          _rollingRoadAlertRepeated =
              false; // Reset repeat flag for this new alert instance
          _rollingRoadAlertTriggered = true; // Mark as triggered
          _trackingMode = "RollingRoadAlerted"; // Set alerted state
          _startRollingRoadRepeatTimer(); // Start the 30-second timer

          await _saveState();
        } else if (!isCurrentlyWithin1MileRadiusRR &&
            _rollingRoadAlertTriggered) {
          // Left the 1-mile alert zone for Rolling Road, potentially arrived.
          // Only trigger this if we actually had a 1-mile alert first
          print(
              'LocationTaskHandler: Left 1-mile Rolling Road radius (potential arrival).');
          _updateTrackingModeBasedOnTime(); // Reset to time-based modeto time-based mode
          _cancelRollingRoadRepeatTimer();
          _rollingRoadAlertRepeated = false;
          _twoMileAlertIssuedForRollingRoad = false;
          _rollingRoadAlertTriggered = false;
          _unionStationAlertTriggered = false;
          _rollingRoadAlertTriggered = false; // Reset for next trip

          bool trainWasSetToNone = false;
          if (_effectiveCurrentTime.weekday == DateTime.friday) {
            if (_currentTrain != "None") {
              print(
                  'LocationTaskHandler: It is Friday evening after Rolling Road alert. Setting train to "None" for the weekend.');
              _currentTrain = "None";
              trainWasSetToNone = true;
              // Clear any remaining reminders for Friday, as the "commute day" is over.
              _todaysIssuedReminders.clear();
              print(
                  'LocationTaskHandler: Cleared today\'s issued reminders as train set to None for weekend.');
            }
          }

          await _saveState(); // Save the new state (_trackingMode is "Waiting", _currentTrain might be "None")

          if (trainWasSetToNone) {
            // Ensure UI updates immediately if train was changed to "None"
            // This sends the updated train and tracking mode to the UI.
            FlutterForegroundTask.sendDataToMain({
              'currentTrain': _currentTrain, // This will be "None"
              'trackingMode': _trackingMode // This will be "Waiting"
            });
          }
        }
      }
      // Logic for morning/northbound trains (Union Station)
      else if (isMorningTrain &&
          _trackingMode == LocationConstants.trackingModeMorning) {
        final bool isCloseToUnionStation = _isWithinRadius(
            position,
            LocationConstants.unionStation,
            LocationConstants.unionStationAlertRadius);

        if (isCloseToUnionStation && !_unionStationAlertTriggered) {
          await _triggerAlert('Approaching Station!');
          _hasAcknowledgedAlert =
              true; // No acknowledgement needed for Union Station
          _unionStationAlertTriggered = true; // Mark as triggered
          _trackingMode = "UnionStationAlerted"; // Set alerted state
          await _saveState();
        } else if (!isCloseToUnionStation && _unionStationAlertTriggered) {
          _unionStationAlertTriggered = false; // Reset for next trip
          _updateTrackingModeBasedOnTime(); // Reset to time-based mode
        }
      }

      final batteryLevel = await _battery.batteryLevel;
// ... (rest of the method)

      FlutterForegroundTask.sendDataToMain({
        'batteryLevel': batteryLevel,
      });
    } catch (e) {
      print('Error updating location: $e');
      FlutterForegroundTask.sendDataToMain(
          {'error': 'Location update failed: $e'});
    }
  }

  bool _isWithinRadius(Position currentPosition, Map<String, double> target,
      double radiusMeters) {
    final double distance = Geolocator.distanceBetween(
      currentPosition.latitude,
      currentPosition.longitude,
      target['latitude']!,
      target['longitude']!,
    );
    print('Distance to target: $distance meters');
    return distance <= radiusMeters;
  }

  Future<void> _triggerAlert(String message) async {
    if (!_hasAcknowledgedAlert) return;

    print('Triggering alert: $message');

    // Volume already set to max in onStart, just ensure it's still at max
    //VolumeController().setVolume(1.0);

    VolumeController().setVolume(1.0);
    await _flutterTts.speak(message);

    // SystemSound not available in background isolate context
    // await SystemSound.play(SystemSoundType.alert);  // Removed

    FlutterForegroundTask.sendDataToMain({
      'action': LocationConstants.actionAlert,
      'message': message,
    });

    _hasAcknowledgedAlert = false;
  }

  Future<void> _saveState() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('currentTrain', _currentTrain);
    await prefs.setString('trackingMode', _trackingMode);
    print(
        'State saved: currentTrain=$_currentTrain, trackingMode=$_trackingMode');
  }

  void _startRollingRoadRepeatTimer() {
    _cancelRollingRoadRepeatTimer(); // Cancel any existing timer
    // Check if it's an afternoon train, we triggered the alert, and it hasn't been repeated yet.
    bool isAfternoonTrain = _currentTrain == "329" ||
        _currentTrain == "331" ||
        _currentTrain == "333";
    if (isAfternoonTrain &&
        _rollingRoadAlertTriggered &&
        !_rollingRoadAlertRepeated &&
        !_hasAcknowledgedAlert) {
      print(
          'LocationTaskHandler: Starting 30-second repeat timer for Rolling Road alert.');
      _rollingRoadRepeatTimer = Timer(const Duration(seconds: 30), () async {
        if (!_hasAcknowledgedAlert &&
            _rollingRoadAlertTriggered &&
            !_rollingRoadAlertRepeated) {
          print(
              'LocationTaskHandler: Rolling Road alert not acknowledged in 30s. Repeating audio announcement only.');
          VolumeController().setVolume(1.0);
          await _flutterTts
              .speak('Repeating: Approaching station!'); // Audio only
          _rollingRoadAlertRepeated =
              true; // Mark as repeated to prevent further audio repeats for this instance
          // Note: _hasAcknowledgedAlert remains false from the initial unacknowledged alert.
          // The original UI alert is still pending.
        }
      });
    }
  }

  void _cancelRollingRoadRepeatTimer() {
    if (_rollingRoadRepeatTimer != null) {
      print('LocationTaskHandler: Cancelling Rolling Road repeat timer.');
      _rollingRoadRepeatTimer?.cancel();
      _rollingRoadRepeatTimer = null;
    }
  }

  void _changeUpdateInterval(int newMillis) {
    if (!(_timer?.isActive ?? false) &&
        newMillis == _currentUpdateIntervalMillis) {
      //k Geminithis specific scenario needs care. For now, only change if newMillis is different OR timer isn't active.
    }

    // Only log and restart if the interval is actually changing, or if the timer needs to be started.
    if (newMillis != _currentUpdateIntervalMillis ||
        !(_timer?.isActive ?? false)) {
      print(
          'LocationTaskHandler: Changing update interval from $_currentUpdateIntervalMillis ms to $newMillis ms.');
      _currentUpdateIntervalMillis = newMillis;
      _timer?.cancel();
      _timer = Timer.periodic(
          Duration(milliseconds: _currentUpdateIntervalMillis), (timer) {
        _updateLocation();
      });
    }
  }

  void _updateTargetStation() {
    if (_currentTrain == "326" || _currentTrain == "328") {
      // Morning trains to Union Station
      _currentTargetStationCoordinates = LocationConstants.unionStation;
    } else if (_currentTrain == "329" ||
        _currentTrain == "331" ||
        _currentTrain == "333") {
      // Evening trains to Rolling Road
      _currentTargetStationCoordinates = LocationConstants.rollingRoadStation;
    } else {
      _currentTargetStationCoordinates = null; // No specific target
    }
  }

  void setCurrentTrain(String train) {
    _currentTrain = train;
    FlutterForegroundTask.sendDataToMain(
        {'action': 'trainUpdated', 'currentTrain': train});
    _saveState();
  }

  void acknowledgeAlert() {
    _hasAcknowledgedAlert = true;
    _cancelRollingRoadRepeatTimer(); // <<< THIS LINE IS ADDED/MODIFIED IN CONTEXT
    FlutterForegroundTask.sendDataToMain({'action': 'alertAcknowledged'});
    print('Alert acknowledged');
  }

  String? _morningDefaultAppliedDateBackground;
  String? _afternoonDefaultAppliedDateBackground;

  Future<void> _checkAndApplyAutomaticTrainDefaultsInBackground(
      DateTime currentTime) async {
    // Skip if it's a weekend
    if (currentTime.weekday < DateTime.monday ||
        currentTime.weekday > DateTime.friday) {
      return;
    }

    if (_dayOffDateIsoString != null && _dayOffDateIsoString!.isNotEmpty) {
      final String currentDateIso =
          "${currentTime.year}-${currentTime.month.toString().padLeft(2, '0')}-${currentTime.day.toString().padLeft(2, '0')}";
      if (_dayOffDateIsoString == currentDateIso && currentTime.hour < 20) {
        return; // It's a day off and before 8 PM
      }
    }

    final String currentDateStr =
        "${currentTime.year}-${currentTime.month.toString().padLeft(2, '0')}-${currentTime.day.toString().padLeft(2, '0')}";

    // Reset applied dates if the day has changed
    if (_morningDefaultAppliedDateBackground != null &&
        _morningDefaultAppliedDateBackground != currentDateStr) {
      _morningDefaultAppliedDateBackground = null;
    }
    if (_afternoonDefaultAppliedDateBackground != null &&
        _afternoonDefaultAppliedDateBackground != currentDateStr) {
      _afternoonDefaultAppliedDateBackground = null;
    }

    // Morning default: between 5:30 AM and noon
    // Morning default: between 5:30 AM and noon
    // Morning default: between 5:30 AM and noon

    // Morning default: between 5:30 AM and noon
    bool isMorningWindow =
        (currentTime.hour == 5 && currentTime.minute >= 30) ||
            (currentTime.hour > 5 && currentTime.hour < 12);

    if (isMorningWindow &&
        _morningDefaultAppliedDateBackground != currentDateStr) {
      if (_currentTrain == "None" ||
          _currentTrain == "331" ||
          _currentTrain == "333" ||
          _currentTrain == "329") {
        print(
            'LocationTaskHandler: Auto-switching to morning train 326 at ${currentTime.hour}:${currentTime.minute.toString().padLeft(2, '0')}');
        _currentTrain = "326";
        _trackingMode = LocationConstants.trackingModeMorning;
        _updateTargetStation();
        await _saveState();

        // Notify UI of the change
        FlutterForegroundTask.sendDataToMain({
          'currentTrain': _currentTrain,
          'trackingMode': _trackingMode,
          'action': 'trainAutoSwitched',
          'message': 'Auto-switched to morning train 326'
        });
      } else if (_currentTrain == "326" || _currentTrain == "328") {
        // If already on a morning train, just set the mode to Morning
        _trackingMode = LocationConstants.trackingModeMorning;
        await _saveState();
      }
      _morningDefaultAppliedDateBackground = currentDateStr;
    }

    // Afternoon default: noon or later
    if (currentTime.hour >= 12 &&
        _afternoonDefaultAppliedDateBackground != currentDateStr) {
      if (_currentTrain == "None" ||
          _currentTrain == "326" ||
          _currentTrain == "328") {
        print(
            'LocationTaskHandler: Auto-switching to afternoon train 331 at ${currentTime.hour}:${currentTime.minute.toString().padLeft(2, '0')}');
        _currentTrain = "331";
        _trackingMode = LocationConstants.trackingModeAfternoon;
        _updateTargetStation();
        await _saveState();

        // Notify UI of the change
        FlutterForegroundTask.sendDataToMain({
          'currentTrain': _currentTrain,
          'trackingMode': _trackingMode,
          'action': 'trainAutoSwitched',
          'message': 'Auto-switched to afternoon train 331'
        });
      }
      _afternoonDefaultAppliedDateBackground = currentDateStr;
    }
  }

  Future<void> _updateTrackingModeBasedOnTime() async {
    final DateTime now = _effectiveCurrentTime;

    // Store previous mode to detect changes
    String previousMode = _trackingMode;

    // Check if it's weekend
    // Check if it's weekend
    if (now.weekday == DateTime.saturday || now.weekday == DateTime.sunday) {
      _trackingMode = LocationConstants.trackingModeInactive;
      if (_currentTrain != "None") {
        _currentTrain = "None";
        _updateTargetStation();
        await _saveState();
        // Notify UI of the change
        FlutterForegroundTask.sendDataToMain({
          'currentTrain': _currentTrain,
          'trackingMode': _trackingMode,
        });
      }
      return; // Return AFTER all weekend logic is complete
    }

    // Check if it's a day off
    if (_dayOffDateIsoString != null && _dayOffDateIsoString!.isNotEmpty) {
      final String currentDateIso =
          "${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}";
      if (_dayOffDateIsoString == currentDateIso && now.hour < 20) {
        _trackingMode = LocationConstants.trackingModeDayOff;
        return;
      }
    }

    // Determine mode based on time
    bool isMorningTime = (now.hour == LocationConstants.morningModeStartHour &&
            now.minute >= LocationConstants.morningModeStartMinute) ||
        (now.hour > LocationConstants.morningModeStartHour &&
            now.hour < LocationConstants.morningModeEndHour);

    bool isWorkdayTime = now.hour >= LocationConstants.morningModeEndHour &&
        now.hour < LocationConstants.workdayModeEndHour;

    bool isAfternoonTime = now.hour >= LocationConstants.afternoonModeStartHour;

    if (isMorningTime) {
      _trackingMode = LocationConstants.trackingModeMorning;
    } else if (isWorkdayTime) {
      _trackingMode = LocationConstants.trackingModeWorkday;
    } else if (isAfternoonTime) {
      _trackingMode = LocationConstants.trackingModeAfternoon;
    } else {
      _trackingMode = LocationConstants.trackingModeInactive;
    }

    // Auto-set default train when entering Morning or Afternoon mode with no train
    if (_trackingMode != previousMode && _currentTrain == "None") {
      if (_trackingMode == LocationConstants.trackingModeMorning) {
        print(
            'LocationTaskHandler: Auto-setting default morning train 326 on app launch');
        _currentTrain = "326";
        _updateTargetStation();
        _saveState();

        // Notify UI of the change
        FlutterForegroundTask.sendDataToMain({
          'currentTrain': _currentTrain,
          'trackingMode': _trackingMode,
          'action': 'trainAutoSwitched',
          'message': 'Auto-set to morning train 326'
        });
      } else if (_trackingMode == LocationConstants.trackingModeAfternoon) {
        print(
            'LocationTaskHandler: Auto-setting default afternoon train 331 on app launch');
        _currentTrain = "331";
        _updateTargetStation();
        _saveState();

        // Notify UI of the change
        FlutterForegroundTask.sendDataToMain({
          'currentTrain': _currentTrain,
          'trackingMode': _trackingMode,
          'action': 'trainAutoSwitched',
          'message': 'Auto-set to afternoon train 331'
        });
      }
    }
  }
}

class LocationService {
  LocationService._privateConstructor();
  static final LocationService _instance =
      LocationService._privateConstructor();
  static LocationService get instance => _instance;

  final _locationController =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get locationStream => _locationController.stream;

  bool _isTracking = false;
  bool get isTracking => _isTracking;

  double trainThreshold = LocationConstants.defaultTrainThreshold;
  double stationThreshold = LocationConstants.defaultStationThreshold;
  double proximityThreshold = LocationConstants.defaultProximityThreshold;
  String mondayMorningTime = LocationConstants.defaultMondayMorningTime;
  String returnHomeTime = LocationConstants.defaultReturnHomeTime;
  String sleepReminderTime = LocationConstants.defaultSleepReminderTime;
  String currentTrain = "None";
  String trackingMode = "Waiting";
  //DateTime? lastAcknowledgedAlertTime;

  void initCommunication() {
    // Communication is now handled by TaskDataCallback in the UI
    // No need for receivePort listening here
  }

  Future<bool> startTracking(String train, BuildContext context,
      {int interval = 1000}) async {
    // Check permissions first
    bool hasPermission =
        await LocationPermissionHelper.requestLocationPermissions(context);
    if (!hasPermission) {
      print('Location permission not granted');
      return false;
    }

    final bool reqResult =
        await FlutterForegroundTask.requestIgnoreBatteryOptimization();
    print('Ignore Battery Optimization: $reqResult');

    final bool canDraw = await FlutterForegroundTask.canDrawOverlays;
    print('Can Draw Overlays: $canDraw');

    // Initialize the service first
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'vre_watch_service',
        channelName: 'VRE Watch Service',
        channelDescription: 'VRE Watch location tracking service',
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(interval),
        autoRunOnBoot: true,
        autoRunOnMyPackageReplaced: true,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );

    if (await FlutterForegroundTask.isRunningService) {
      print('Service already running, updating train to $train');
      final ServiceRequestResult updateResult =
          await FlutterForegroundTask.updateService(
        notificationTitle: 'VRE Watch',
        notificationText: 'Tracking $train train...',
        callback: startCallback,
      );
      if (updateResult is ServiceRequestSuccess) {
        _isTracking = true;
        return true;
      } else {
        print('Failed to update existing service.');
        return false;
      }
    }

    final ServiceRequestResult startResult =
        await FlutterForegroundTask.startService(
      notificationTitle: 'VRE Watch',
      notificationText: 'Tracking $train train...',
      callback: startCallback,
    );

    if (startResult is ServiceRequestSuccess) {
      _isTracking = true;
      print('Started tracking: $train');
      return true;
    } else {
      print('Failed to start tracking service.');
      return false;
    }
  }

  Future<bool> restartTracking(String train, BuildContext context,
      {int interval = 1000}) async {
    if (!await FlutterForegroundTask.isRunningService) {
      print(
          'Service not running, calling startTracking instead of restartTracking.');
      return startTracking(train, context, interval: interval);
    }

    final ServiceRequestResult result =
        await FlutterForegroundTask.restartService();

    if (result is ServiceRequestSuccess) {
      _isTracking = true;
      print('Restarted tracking: $train');
      return true;
    } else {
      print('Failed to restart tracking service.');
      return false;
    }
  }

  Future<void> loadState() async {
    final prefs = await SharedPreferences.getInstance();
    _isTracking = prefs.getBool('isTracking') ?? false;
    print('Service state loaded: isTracking=$_isTracking');
  }

  Future<void> saveState() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('isTracking', _isTracking);
    print('Service state saved: isTracking=$_isTracking');
  }

  void acknowledgeAlert() {
    FlutterForegroundTask.sendDataToTask({
      'action': LocationConstants.actionAcknowledge,
    });
  }

  void dispose() {
    _locationController.close();
  }
}
