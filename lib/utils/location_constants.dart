class LocationConstants {
  // Train tracking modes
  static const String trackingModeMorning = "Morning";
  static const String trackingModeAfternoon = "Afternoon";

  // SharedPreferences keys
  static const String prefCurrentTrain = "currentTrain";
  static const String prefTrackingMode = "trackingMode";
  static const String prefTrainThreshold = "trainThreshold";
  static const String prefStationThreshold = "stationThreshold";
  static const String prefProximityThreshold = "proximityThreshold";
  static const String prefMondayMorningTime = "mondayMorningTime";
  static const String prefReturnHomeTime = "returnHomeTime";
  static const String prefSleepReminderTime = "sleepReminderTime";
  static const String prefDayOffDate = "dayOffDate";

  // Default values
  static const double defaultTrainThreshold = 2.0;
  static const double defaultStationThreshold = 0.5;
  static const double defaultProximityThreshold = 1.0;
  static const String defaultMondayMorningTime = "06:30";
  static const String defaultReturnHomeTime = "17:30";
  static const String defaultSleepReminderTime = "22:00";

  // Station coordinates
  static const Map<String, double> unionStationCoordinates = {
    'latitude': 38.8977,
    'longitude': -77.0065,
  };

  static const Map<String, double> rollingRoadCoordinates = {
    'latitude': 38.8977,
    'longitude': -77.0065,
  };

  // Morning train times
  static final DateTime morningGetReadyTime = DateTime(2024, 1, 1, 6, 30);
  static final DateTime morningCatchTrainTime = DateTime(2024, 1, 1, 7, 0);
  static final DateTime morningTurnOffAndCatchTrainTime =
      DateTime(2024, 1, 1, 7, 15);

  // Afternoon train times
  static final DateTime afternoonGetReadyTime = DateTime(2024, 1, 1, 16, 30);
  static final DateTime afternoonCatchTrainTime = DateTime(2024, 1, 1, 17, 0);
  static final DateTime afternoonTurnOffAndCatchTrainTime =
      DateTime(2024, 1, 1, 17, 15);

  // Reminder lead times (in minutes)
  static const int morningGetReadyLeadTimeMinutes = 30;
  static const int morningCatchTrainLeadTimeMinutes = 15;
  static const int morningTurnOffAndCatchTrainLeadTimeMinutes = 5;
  static const int afternoonGetReadyLeadTimeMinutes = 30;
  static const int afternoonCatchTrainLeadTimeMinutes = 15;
  static const int afternoonTurnOffAndCatchTrainLeadTimeMinutes = 5;

  // Reminder messages
  static const String reminderMsgGetReady = "Time to get ready for your train";
  static const String reminderMsgCatchTrain = "Time to leave for your train";
  static const String reminderMsgTurnOffAndCatchTrain =
      "Turn off your computer and catch your train";
}
