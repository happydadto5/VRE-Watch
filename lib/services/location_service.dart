import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:isolate';

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

  final Battery _battery = Battery();

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
    _originalVolume = await VolumeController().getVolume();
    // Set volume to max for all announcements
    VolumeController().setVolume(1.0);

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
        'BACKGROUND: *** PROCESSING LOCATION *** ${position.latitude}, ${position.longitude}');

    // Check if we need to issue a "Leave House" reminder
    if (_currentTrain == "326" || _currentTrain == "328") {
      final now = DateTime.now();
      if (now.hour == 6 && now.minute == 5) {
        print('BACKGROUND: *** TIME TO LEAVE HOUSE ***');
        VolumeController().setVolume(1.0);
        _flutterTts?.speak(LocationConstants.reminderMsgLeaveHouse);
      }
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

  @override
  void onRepeatEvent(DateTime timestamp) {
    // Handle repeat events
    print('BACKGROUND: *** REPEAT EVENT *** $timestamp');
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    _locationSubscription?.cancel();
    await _flutterTts?.stop();
    VolumeController().setVolume(_originalVolume);
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
