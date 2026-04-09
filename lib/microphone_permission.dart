import 'package:permission_handler/permission_handler.dart';

/// Prompts for microphone access once the main shell is shown (after login).
/// Android: runtime dialog; iOS: uses [NSMicrophoneUsageDescription].
Future<void> requestMicrophonePermissionIfNeeded() async {
  final status = await Permission.microphone.status;
  if (status.isGranted) return;
  if (status.isPermanentlyDenied) return;
  await Permission.microphone.request();
}
