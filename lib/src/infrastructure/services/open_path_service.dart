import 'dart:io';

import 'package:open_filex/open_filex.dart';

class OpenPathService {
  Future<void> open(String path) async {
    if (Platform.isWindows) {
      await Process.run('explorer', [path]);
      return;
    }
    if (Platform.isMacOS) {
      await Process.run('open', [path]);
      return;
    }
    if (Platform.isLinux) {
      await Process.run('xdg-open', [path]);
      return;
    }
    await OpenFilex.open(path);
  }
}
