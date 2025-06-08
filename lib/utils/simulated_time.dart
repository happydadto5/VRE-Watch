// Utility for simulated/test time logic
class SimulatedTime {
  static DateTime? simulatedStart;
  static DateTime? realTimeAtSimulationStart;
  static double simulationSpeedFactor = 45.0;

  static DateTime getCurrentTime() {
    if (simulatedStart != null && realTimeAtSimulationStart != null) {
      final Duration elapsedRealTime =
          DateTime.now().difference(realTimeAtSimulationStart!);
      final int acceleratedMilliseconds =
          (elapsedRealTime.inMilliseconds * simulationSpeedFactor).round();
      return simulatedStart!
          .add(Duration(milliseconds: acceleratedMilliseconds));
    }
    return DateTime.now();
  }
}
