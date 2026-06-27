class SelectedTransferFile {
  const SelectedTransferFile({
    required this.path,
    required this.name,
    required this.size,
    this.relativePath,
    this.deleteAfterSend = false,
  });

  final String path;
  final String name;
  final int size;
  final String? relativePath;
  final bool deleteAfterSend;
}
