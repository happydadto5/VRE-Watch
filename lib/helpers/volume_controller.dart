import 'package:volume_controller/volume_controller.dart';

class VolumeControllerHelper {
  static final VolumeControllerHelper instance =
      VolumeControllerHelper._internal();
  factory VolumeControllerHelper() => instance;
  VolumeControllerHelper._internal();

  Future<void> setVolume(double volume) async {
    try {
      await VolumeController.instance.setVolume(volume);
    } catch (e) {
      print('Error setting volume: $e');
      rethrow;
    }
  }

  Future<double> getVolume() async {
    try {
      return await VolumeController.instance.getVolume();
    } catch (e) {
      print('Error getting volume: $e');
      return 0.0;
    }
  }
}
