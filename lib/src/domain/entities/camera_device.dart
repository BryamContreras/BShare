/// The primary front or rear video input advertised by WebRTC.
/// Native IDs are retained for capture; individual lenses stay internal.
class CameraDevice {
  const CameraDevice({
    required this.id,
    required this.label,
    required this.frontFacing,
  });

  final String id;
  final String label;
  final bool frontFacing;
}
