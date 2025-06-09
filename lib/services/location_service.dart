import 'package:flutter/material.dart';
import 'dart:async';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_tts/flutter_tts.dart';

import 'package:volume_controller/volume_controller.dart';
import '../helpers/location_permission_helper.dart';

import '../constants/location_constants.dart';

@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(LocationTaskHandler());
}

@pragma('vm:entry-point')
class LocationTaskHandler extends TaskHandler {
  static const String backgroundServiceVersion = '1.0.7';
  StreamSubscription<Position>? _locationSubscription;
  FlutterTts? _flutterTts;
  double _originalVolume = 0.0;
  DateTime? _lastCheckedDateForReminders;
  String _currentTrain = "None";
  String _trackingMode = "Waiting";
  Map<String, double>? _currentTargetStationCoordinates;
  Timer? _timer;
  final int _updateInterval = LocationConstants.mediumUpdateFrequency;
  DateTime? _lastVibrationTime;
  bool _hasAcknowledgedAlert = true;
  bool _rollingRoadAlertTriggered = false;
  bool _unionStationAlertTriggered = false;
  bool _rollingRoadAlertRepeated = false;
  bool _unionStationAlertRepeated = false;
  Set<String> _todaysIssuedReminders = {};
  int _currentUpdateIntervalMillis = LocationConstants.mediumUpdateFrequency;
  String? _dayOffDateIsoString;
  DateTime _effectiveCurrentTime = DateTime.now();
  DateTime? _lastSimulatedTimeChecked;
  String? _lastReminderFired;

  DateTime? _simulatedStart;
  DateTime? _realTimeAtSimulationStart;
  double _simulationSpeedFactor = 45.0;
  bool _useSimulatedTime = false;

  bool _afternoonPrepReminderFired = false;
  bool _afternoonArrivedReminderFired = false;

  Position? _lastPosition;

  DateTime _getCurrentTimeForLogic() {
    if (_useSimulatedTime &&
        _simulatedStart != null &&
        _realTimeAtSimulationStart != null) {
      final Duration elapsedRealTime =
          DateTime.now().difference(_realTimeAtSimulationStart!);
      final int acceleratedMilliseconds =
          (elapsedRealTime.inMilliseconds * _simulationSpeedFactor).round();
      return _simulatedStart!
          .add(Duration(milliseconds: acceleratedMilliseconds));
    }
    return DateTime.now();
  }

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    print('BACKGROUND: *** SERVICE STARTED ***');
    print('BACKGROUND: *** SENDING VERSION: $backgroundServiceVersion ***');

    // Send initial version info
    FlutterForegroundTask.sendDataToMain({
      'backgroundServiceVersion': backgroundServiceVersion,
      'status': 'started'
    });

    // Initialize TTS and volume
    _flutterTts = FlutterTts();
    await _flutterTts?.setSharedInstance(true);
    await _flutterTts?.setSpeechRate(0.5);
    await _flutterTts?.setVolume(1.0);

    // Store original volume to restore later if needed
    _originalVolume = await VolumeController.instance.getVolume();
    // Set volume to max for all announcements
    VolumeController.instance.setVolume(1.0);

    _lastCheckedDateForReminders = DateTime.now();
    await _initFromPrefs();
    _updateTargetStation();

    // Start location updates immediately
    _startLocationUpdates();
  }

  void _startLocationUpdates() {
    print('BACKGROUND: *** STARTING LOCATION UPDATES ***');
    _locationSubscription = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 10, // Update every 10 meters
      ),
    ).listen((Position position) {
      print(
          'BACKGROUND: *** GOT GPS UPDATE *** ${position.latitude}, ${position.longitude}');

      // Send GPS data to main app
      FlutterForegroundTask.sendDataToMain({
        'latitude': position.latitude,
        'longitude': position.longitude,
        'timestamp': DateTime.now().toIso8601String(),
        'backgroundServiceVersion': backgroundServiceVersion,
        'currentTrain': _currentTrain,
        'trackingMode': _trackingMode
      });

      // Process location for alerts
      _processLocation(position);
    }, onError: (error) {
      print('BACKGROUND: *** GPS ERROR *** $error');
      FlutterForegroundTask.sendDataToMain({
        'error': error.toString(),
        'backgroundServiceVersion': backgroundServiceVersion
      });
    });
  }

  void _processLocation(Position position) {
    print(
        'BACKGROUND: *** PROCESSING LOCATION *** [32m${position.latitude}, ${position.longitude}[0m');
    print(
        'BACKGROUND: *** _currentTrain = $_currentTrain, _trackingMode = $_trackingMode');
    final now = _getCurrentTimeForLogic();
    print('BACKGROUND: *** now = $now');

    // Only do afternoon reminders for afternoon trains
    if (_currentTrain == "329" ||
        _currentTrain == "331" ||
        _currentTrain == "333") {
      // Calculate distance to Rolling Road
      final target = LocationConstants.rollingRoadCoordinates;
      final distanceMeters = Geolocator.distanceBetween(
        position.latitude,
        position.longitude,
        target['latitude']!,
        target['longitude']!,
      );
      final distanceMiles = distanceMeters * LocationConstants.metersToMiles;
      final prepThreshold = 1.0; // miles (example, set to your prep threshold)
      final arrivedThreshold =
          0.1; // miles (example, set to your arrived threshold)

      double? lastDistanceMiles;
      if (_lastPosition != null) {
        final lastDistanceMeters = Geolocator.distanceBetween(
          _lastPosition!.latitude,
          _lastPosition!.longitude,
          target['latitude']!,
          target['longitude']!,
        );
        lastDistanceMiles =
            lastDistanceMeters * LocationConstants.metersToMiles;
      }

      // Fire prep reminder if threshold crossed or currently within and not yet fired
      if (!_afternoonPrepReminderFired &&
          ((lastDistanceMiles != null &&
                  lastDistanceMiles > prepThreshold &&
                  distanceMiles <= prepThreshold) ||
              (lastDistanceMiles == null && distanceMiles <= prepThreshold))) {
        _afternoonPrepReminderFired = true;
        VolumeController.instance.setVolume(1.0);
        _flutterTts?.speak("Prep: Approaching Rolling Road");
      }
      // Fire arrived reminder if threshold crossed or currently within and not yet fired
      if (!_afternoonArrivedReminderFired &&
          ((lastDistanceMiles != null &&
                  lastDistanceMiles > arrivedThreshold &&
                  distanceMiles <= arrivedThreshold) ||
              (lastDistanceMiles == null &&
                  distanceMiles <= arrivedThreshold))) {
        _afternoonArrivedReminderFired = true;
        VolumeController.instance.setVolume(1.0);
        _flutterTts?.speak("Arrived: Get off the train at Rolling Road");
      }
      _lastPosition = position;
    }

    // Get departure time for current train
    String? departureTimeStr;
    int? getReadyLead;
    int? catchTrainLead;
    int? turnOffAndCatchLead;
    String? getReadyMsg;
    String? catchTrainMsg;
    String? turnOffAndCatchMsg;

    switch (_currentTrain) {
      case "326":
        departureTimeStr = LocationConstants.departureTimeTrain326;
        getReadyLead = LocationConstants.morningGetReadyLeadTimeMinutes;
        catchTrainLead = LocationConstants.morningCatchTrainLeadTimeMinutes;
        turnOffAndCatchLead =
            LocationConstants.morningTurnOffAndCatchTrainLeadTimeMinutes;
        getReadyMsg = LocationConstants.reminderMsgGetReady;
        catchTrainMsg = LocationConstants.reminderMsgCatchTrain;
        turnOffAndCatchMsg = LocationConstants.reminderMsgTurnOffAndCatchTrain;
        break;
      case "328":
        departureTimeStr = LocationConstants.departureTimeTrain328;
        getReadyLead = LocationConstants.morningGetReadyLeadTimeMinutes;
        catchTrainLead = LocationConstants.morningCatchTrainLeadTimeMinutes;
        turnOffAndCatchLead =
            LocationConstants.morningTurnOffAndCatchTrainLeadTimeMinutes;
        getReadyMsg = LocationConstants.reminderMsgGetReady;
        catchTrainMsg = LocationConstants.reminderMsgCatchTrain;
        turnOffAndCatchMsg = LocationConstants.reminderMsgTurnOffAndCatchTrain;
        break;
      case "329":
        departureTimeStr = LocationConstants.departureTimeTrain329;
        getReadyLead = LocationConstants.afternoonGetReadyLeadTimeMinutes;
        catchTrainLead = LocationConstants.afternoonCatchTrainLeadTimeMinutes;
        getReadyMsg = LocationConstants.reminderMsgGetReady;
        catchTrainMsg = LocationConstants.reminderMsgCatchTrain;
        break;
      case "331":
        departureTimeStr = LocationConstants.departureTimeTrain331;
        getReadyLead = LocationConstants.afternoonGetReadyLeadTimeMinutes;
        catchTrainLead = LocationConstants.afternoonCatchTrainLeadTimeMinutes;
        getReadyMsg = LocationConstants.reminderMsgGetReady;
        catchTrainMsg = LocationConstants.reminderMsgCatchTrain;
        break;
      case "333":
        departureTimeStr = LocationConstants.departureTimeTrain333;
        getReadyLead = LocationConstants.afternoonGetReadyLeadTimeMinutes;
        catchTrainLead = LocationConstants.afternoonCatchTrainLeadTimeMinutes;
        getReadyMsg = LocationConstants.reminderMsgGetReady;
        catchTrainMsg = LocationConstants.reminderMsgCatchTrain;
        break;
      default:
        print('BACKGROUND: No reminders for train $_currentTrain');
        return;
    }

    if (departureTimeStr == null) return;
    final depParts = departureTimeStr.split(":");
    final depHour = int.parse(depParts[0]);
    final depMinute = int.parse(depParts[1]);
    final today = DateTime(now.year, now.month, now.day, depHour, depMinute);

    // Calculate reminder times
    DateTime? getReadyTime = getReadyLead != null
        ? today.subtract(Duration(minutes: getReadyLead))
        : null;
    DateTime? catchTrainTime = catchTrainLead != null
        ? today.subtract(Duration(minutes: catchTrainLead))
        : null;
    DateTime? turnOffAndCatchTime = turnOffAndCatchLead != null
        ? today.subtract(Duration(minutes: turnOffAndCatchLead))
        : null;

    // Fire reminders if current time matches
    if (getReadyTime != null &&
        now.hour == getReadyTime.hour &&
        now.minute == getReadyTime.minute) {
      print(
          'BACKGROUND: *** GET READY REMINDER for $_currentTrain at ${getReadyTime.hour}:${getReadyTime.minute.toString().padLeft(2, '0')} ***');
      VolumeController.instance.setVolume(1.0);
      _flutterTts?.speak(getReadyMsg ?? "Get Ready");
    }
    if (catchTrainTime != null &&
        now.hour == catchTrainTime.hour &&
        now.minute == catchTrainTime.minute) {
      print(
          'BACKGROUND: *** CATCH TRAIN REMINDER for $_currentTrain at ${catchTrainTime.hour}:${catchTrainTime.minute.toString().padLeft(2, '0')} ***');
      VolumeController.instance.setVolume(1.0);
      _flutterTts?.speak(catchTrainMsg ?? "Catch Train");
    }
    if (turnOffAndCatchTime != null &&
        now.hour == turnOffAndCatchTime.hour &&
        now.minute == turnOffAndCatchTime.minute) {
      print(
          'BACKGROUND: *** TURN OFF AND CATCH TRAIN REMINDER for $_currentTrain at ${turnOffAndCatchTime.hour}:${turnOffAndCatchTime.minute.toString().padLeft(2, '0')} ***');
      VolumeController.instance.setVolume(1.0);
      _flutterTts?.speak(turnOffAndCatchMsg ?? "Turn Off and Catch Train");
    }
  }

  Future<void> _initFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    _currentTrain =
        prefs.getString(LocationConstants.prefCurrentTrain) ?? "None";
    _trackingMode =
        prefs.getString(LocationConstants.prefTrackingMode) ?? "Waiting";
    print(
        'BACKGROUND: *** INITIALIZED FROM PREFS *** Train: $_currentTrain, Mode: $_trackingMode');
  }

  void _updateTargetStation() {
    if (_currentTrain == "326" || _currentTrain == "328") {
      _currentTargetStationCoordinates =
          LocationConstants.unionStationCoordinates;
      _trackingMode = LocationConstants.trackingModeMorning;
    } else if (_currentTrain == "329" ||
        _currentTrain == "331" ||
        _currentTrain == "333") {
      _currentTargetStationCoordinates =
          LocationConstants.rollingRoadCoordinates;
      _trackingMode = LocationConstants.trackingModeAfternoon;
    } else {
      _currentTargetStationCoordinates = null;
      _trackingMode = "Waiting";
    }
    print(
        'BACKGROUND: *** UPDATED TARGET STATION *** Train: $_currentTrain, Mode: $_trackingMode');
  }

  @override
  Future<void> onEvent(DateTime timestamp, TaskStarter starter) async {
    // Handle periodic events
  }

  void _checkRemindersForMissedTimes() {
    final now = _getCurrentTimeForLogic();
    final last = _lastSimulatedTimeChecked ?? now;
    _lastSimulatedTimeChecked = now;

    // Get departure time for current train
    String? departureTimeStr;
    int? getReadyLead;
    int? catchTrainLead;
    int? turnOffAndCatchLead;
    String? getReadyMsg;
    String? catchTrainMsg;
    String? turnOffAndCatchMsg;

    switch (_currentTrain) {
      case "326":
        departureTimeStr = LocationConstants.departureTimeTrain326;
        getReadyLead = LocationConstants.morningGetReadyLeadTimeMinutes;
        catchTrainLead = LocationConstants.morningCatchTrainLeadTimeMinutes;
        turnOffAndCatchLead =
            LocationConstants.morningTurnOffAndCatchTrainLeadTimeMinutes;
        getReadyMsg = LocationConstants.reminderMsgGetReady;
        catchTrainMsg = LocationConstants.reminderMsgCatchTrain;
        turnOffAndCatchMsg = LocationConstants.reminderMsgTurnOffAndCatchTrain;
        break;
      case "328":
        departureTimeStr = LocationConstants.departureTimeTrain328;
        getReadyLead = LocationConstants.morningGetReadyLeadTimeMinutes;
        catchTrainLead = LocationConstants.morningCatchTrainLeadTimeMinutes;
        turnOffAndCatchLead =
            LocationConstants.morningTurnOffAndCatchTrainLeadTimeMinutes;
        getReadyMsg = LocationConstants.reminderMsgGetReady;
        catchTrainMsg = LocationConstants.reminderMsgCatchTrain;
        turnOffAndCatchMsg = LocationConstants.reminderMsgTurnOffAndCatchTrain;
        break;
      case "329":
        departureTimeStr = LocationConstants.departureTimeTrain329;
        getReadyLead = LocationConstants.afternoonGetReadyLeadTimeMinutes;
        catchTrainLead = LocationConstants.afternoonCatchTrainLeadTimeMinutes;
        getReadyMsg = LocationConstants.reminderMsgGetReady;
        catchTrainMsg = LocationConstants.reminderMsgCatchTrain;
        break;
      case "331":
        departureTimeStr = LocationConstants.departureTimeTrain331;
        getReadyLead = LocationConstants.afternoonGetReadyLeadTimeMinutes;
        catchTrainLead = LocationConstants.afternoonCatchTrainLeadTimeMinutes;
        getReadyMsg = LocationConstants.reminderMsgGetReady;
        catchTrainMsg = LocationConstants.reminderMsgCatchTrain;
        break;
      case "333":
        departureTimeStr = LocationConstants.departureTimeTrain333;
        getReadyLead = LocationConstants.afternoonGetReadyLeadTimeMinutes;
        catchTrainLead = LocationConstants.afternoonCatchTrainLeadTimeMinutes;
        getReadyMsg = LocationConstants.reminderMsgGetReady;
        catchTrainMsg = LocationConstants.reminderMsgCatchTrain;
        break;
      default:
        print('BACKGROUND: No reminders for train $_currentTrain');
        return;
    }

    if (departureTimeStr == null) return;
    final depParts = departureTimeStr.split(":");
    final depHour = int.parse(depParts[0]);
    final depMinute = int.parse(depParts[1]);
    final today = DateTime(now.year, now.month, now.day, depHour, depMinute);

    // Calculate reminder times
    DateTime? getReadyTime = getReadyLead != null
        ? today.subtract(Duration(minutes: getReadyLead))
        : null;
    DateTime? catchTrainTime = catchTrainLead != null
        ? today.subtract(Duration(minutes: catchTrainLead))
        : null;
    DateTime? turnOffAndCatchTime = turnOffAndCatchLead != null
        ? today.subtract(Duration(minutes: turnOffAndCatchLead))
        : null;

    // Check for missed reminders between last and now
    void checkAndFire(DateTime? reminderTime, String msg, String logMsg) {
      if (reminderTime == null) return;
      if (!reminderTime.isAfter(last) && !reminderTime.isAtSameMomentAs(last))
        return;
      if (reminderTime.isAfter(now)) return;
      if (_lastReminderFired == logMsg) return; // Prevent duplicate firing
      print(
          'BACKGROUND: *** $logMsg for $_currentTrain at ${reminderTime.hour}:${reminderTime.minute.toString().padLeft(2, '0')} ***');
      VolumeController.instance.setVolume(1.0);
      _flutterTts?.speak(msg);
      _lastReminderFired = logMsg;
      // Optionally, send status to foreground
      FlutterForegroundTask.sendDataToMain({
        'lastReminderFired': logMsg,
        'reminderTime': reminderTime.toIso8601String(),
        'train': _currentTrain,
      });
    }

    checkAndFire(
        getReadyTime, getReadyMsg ?? "Get Ready", "GET READY REMINDER");
    checkAndFire(
        catchTrainTime, catchTrainMsg ?? "Catch Train", "CATCH TRAIN REMINDER");
    checkAndFire(
        turnOffAndCatchTime,
        turnOffAndCatchMsg ?? "Turn Off and Catch Train",
        "TURN OFF AND CATCH TRAIN REMINDER");
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    // Handle repeat events
    print('BACKGROUND: *** REPEAT EVENT *** $timestamp');
    _checkRemindersForMissedTimes();
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    _locationSubscription?.cancel();
    await _flutterTts?.stop();
    VolumeController.instance.setVolume(_originalVolume);
  }

  @override
  void onReceiveData(Object data) {
    if (data is Map<String, dynamic>) {
      if (data['action'] == 'updateTrain') {
        final String? newTrain = data['currentTrain'];
        final String? newTrackingMode = data['trackingMode'];
        if (newTrain != null) {
          _currentTrain = newTrain;
          print(
              'BACKGROUND: Received train update from main app: $_currentTrain');
          _updateTargetStation();
        }
        if (newTrackingMode != null) {
          _trackingMode = newTrackingMode;
          print(
              'BACKGROUND: Received tracking mode update from main app: $_trackingMode');
        }
      } else if (data['action'] == 'updateSimulatedTime') {
        _simulatedStart = DateTime.tryParse(data['simulatedStart'] ?? '');
        _realTimeAtSimulationStart =
            DateTime.tryParse(data['realTimeAtSimulationStart'] ?? '');
        _simulationSpeedFactor =
            (data['simulationSpeedFactor'] as num?)?.toDouble() ?? 45.0;
        _useSimulatedTime =
            _simulatedStart != null && _realTimeAtSimulationStart != null;
        print(
            'BACKGROUND: Received simulated time update: _simulatedStart=$_simulatedStart, _realTimeAtSimulationStart=$_realTimeAtSimulationStart, _simulationSpeedFactor=$_simulationSpeedFactor');
      } else if (data['action'] == 'resetLocationReminders') {
        _afternoonPrepReminderFired = false;
        _afternoonArrivedReminderFired = false;
        print('BACKGROUND: Location-based reminder flags reset.');
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
