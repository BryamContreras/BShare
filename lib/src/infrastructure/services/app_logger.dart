class AppLogger {
  const AppLogger();

  void info(String message) {
    // ignore: avoid_print
    print('[BShare][INFO] $message');
  }

  void warn(String message) {
    // ignore: avoid_print
    print('[BShare][WARN] $message');
  }

  void error(String message, [Object? error]) {
    // ignore: avoid_print
    print('[BShare][ERROR] $message ${error ?? ''}');
  }
}
