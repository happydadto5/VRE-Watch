// Constants for location tracking and alerts
import 'package:geolocator/geolocator.dart';

class LocationConstants {
  // Conversion factors
  static const double metersPerSecondToMph = 2.23694;
  static const double metersToMiles = 0.000621371;
  static const String actionPlayBeep = 'play_beep'; // For the 2-mile beep

  // --- Reminder Constants ---

  // Scheduled Departure Times (HH:mm format)
  // Morning trains from Rolling Road
  static const String departureTimeTrain326 = "06:29";
  static const String departureTimeTrain328 = "06:49";
  // Afternoon/Evening trains from Union Station
  static const String departureTimeTrain331 = "17:10"; // 5:10 PM
  static const String departureTimeTrain333 = "17:30"; // 5:30 PM
  static const String departureTimeTrain329 = "16:10"; // 4:10 PM

  // Reminder Lead Times (in minutes before departure)
  static const int morningGetReadyLeadTimeMinutes = 22;
  static const int morningCatchTrainLeadTimeMinutes = 20;
  static const int afternoonGetReadyLeadTimeMinutes = 12;
  static const int afternoonCatchTrainLeadTimeMinutes = 10;
  static const int morningTurnOffAndCatchTrainLeadTimeMinutes = 6; // New

  // Reminder Messages
  static const String reminderMsgGetReady = "Leave Shortly";
  static const String reminderMsgCatchTrain = "Catch Train";
  static const String reminderMsgTurnOffAndCatchTrain = "Off, Lock and Catch Train"; // New
// --- New Tracking Mode Constants ---
  static const String trackingModeDayOff = "Day Off";
  static const String trackingModeMorning = "Morning";
  static const String trackingModeWorkday = "Workday";
  static const String trackingModeAfternoon = "Afternoon";
  static const String trackingModeInactive = "Inactive";
  // --- End of New Tracking Mode Constants ---
  // --- End of Reminder Constants ---

  // Foreground task and communication channels
  static const String uiCommunicationPort = 'vre_ui_channel';
  static const String backgroundCommunicationPort = 'vre_background_channel';
  static const int foregroundTaskId = 123;

  static const String foregroundServiceChannelId = 'vre_watch_service_channel';

  static const int defaultInterval = 5000;

  // Actions for inter-isolate communication
  static const String actionAcknowledge = 'acknowledge_alert';
  static const String actionAlert = 'show_alert';
  static const String actionToast = 'show_toast';

  // Default threshold values
  static const double defaultTrainThreshold = 500.0;
  static const double defaultStationThreshold = 50.0;
  static const double defaultProximityThreshold = 20.0;
  static const double bufferDistance = 10.0;

  // Default times
  static const String defaultMondayMorningTime = "06:00";
  static const String defaultReturnHomeTime = "17:00";
  static const String defaultSleepReminderTime = "22:00";

  // Default coordinates
  static const double defaultHomeLat = 38.8075;
  static const double defaultHomeLon = -77.2653;
  static const double defaultWorkLat = 38.9072;
  static const double defaultWorkLon = -77.0369;

  // Specific station coordinates for alerts
  static const Map<String, double> rollingRoadStation = {
    'latitude': 38.7974,
    'longitude': -77.2583,
  };
  static const double rollingRoadAlertRadius = 800.0;

  static const Map<String, double> kingStreetStation = {
    'latitude': 38.8048,
    'longitude': -77.0515,
  };
  static const double kingStreetAlertRadius = 1000.0;


// Add these lines for Union Station
  static const Map<String, double> unionStation = {
    'latitude': 38.8971,
    'longitude': -77.0063,
  };
  static const double unionStationAlertRadius = 1200.0; // Or your preferred radius
// End of lines to add


  // Critical battery threshold
  static const int criticalBatteryThreshold = 20;

  // Alert cooldown
  static const int alertCooldownSeconds = 60;

  // Update frequencies
  static const int highUpdateFrequency = 1000;
  static const int mediumUpdateFrequency = 5000;
  static const int lowUpdateFrequency = 10000;

  // Shared Preferences keys
  static const String prefTrainThreshold = 'train_threshold';
  static const String prefStationThreshold = 'station_threshold';
  static const String prefProximityThreshold = 'proximity_threshold';
  static const String prefMondayMorningTime = 'monday_morning_time';
  static const String prefReturnHomeTime = 'return_home_time';
  static const String prefSleepReminderTime = 'sleep_reminder_time';
  static const String prefCurrentTrain = 'current_train';
  static const String prefTrackingMode = 'tracking_mode';
  static const String prefUpdateFrequency = 'update_frequency';
  //static const String prefLastAcknowledgedAlertTime = 'last_acknowledged_alert_time';
  static const String prefHomeLat = 'home_lat';
  static const String prefHomeLon = 'home_lon';
  static const String prefWorkLat = 'work_lat';
  static const String prefWorkLon = 'work_lon';
  static const String prefDayOffDate = 'day_off_date'; // For storing the user's selected day off
  static const String prefMorningDefaultAppliedDate = 'morning_default_applied_date';
  static const String prefAfternoonDefaultAppliedDate = 'afternoon_default_applied_date';
// Adaptive Update Intervals (milliseconds)
  static const int interval1MileMillis = 15000;    // 15 seconds
  static const int interval2MilesMillis = 30000;   // 30 seconds (for 1-1.99 miles)
  // Time boundaries for tracking modes (24-hour format)
  static const int morningModeStartHour = 5;
  static const int morningModeStartMinute = 30;
  static const int morningModeEndHour = 10;
  static const int workdayModeEndHour = 15; // 3:00 PM
  static const int afternoonModeStartHour = 15; // 3:00 PM
  static const int interval6MilesMillis = 60000;   // 1 minute (for 2-5.99 miles)
  static const int intervalFarMillis = 120000;     // 2 minutes (for 6+ miles or no target)
  static const int intervalPostArrivalMillis = 300000; // 5 minutes (for checks after arrival)

  // Distance thresholds (meters)
  static const double distance1MileMeters = 1609.34;
  static const double distance2MilesMeters = 3218.69;
  static const double distance6MilesMeters = 9656.06; // Approx 6 miles


  // Location settings for Android (removed const)
  static final LocationSettings androidSettings = AndroidSettings(
    accuracy: LocationAccuracy.bestForNavigation,
    distanceFilter: 10,
    forceLocationManager: false,
    intervalDuration: const Duration(seconds: 5),
    foregroundNotificationConfig: const ForegroundNotificationConfig(
      notificationTitle: 'VRE Location Tracking',
      notificationText: 'Tracking your location in the background',
      enableWakeLock: true,
    ),
  );

  // Location settings for iOS (removed const)
  static final LocationSettings iosSettings = AppleSettings(
    accuracy: LocationAccuracy.bestForNavigation,
    distanceFilter: 10,
    pauseLocationUpdatesAutomatically: true,
    showBackgroundLocationIndicator: false,
  );
}