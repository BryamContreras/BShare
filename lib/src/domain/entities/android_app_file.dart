class AndroidAppFile {
  const AndroidAppFile({
    required this.name,
    required this.packageName,
    required this.sourcePath,
    required this.size,
    required this.iconBase64,
  });

  final String name;
  final String packageName;
  final String sourcePath;
  final int size;
  final String iconBase64;
}
