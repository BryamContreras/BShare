// Build explicitly with --target tool/webrtc_native_probe.dart into a separate
// build directory. This diagnostic entrypoint is never part of release builds.
//
// Sender: --probe-mode sender --probe-port 53318 --probe-control-port 53319
// Receiver: --viewer-ip 127.0.0.1 --viewer-port 53318
// Android can use corresponding BSHARE_PROBE_* --dart-define values.
// Only run desktop screen capture on an isolated synthetic display (Xvfb/CI).
// GET /status reports progress; POST /stop awaits native media/server cleanup.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show AppExitType;

import 'package:args/args.dart';
import 'package:bshare/src/domain/entities/device_info.dart';
import 'package:bshare/src/domain/entities/screen_capture_settings.dart';
import 'package:bshare/src/domain/entities/transfer_control.dart';
import 'package:bshare/src/infrastructure/services/android_screen_share_execution_service.dart';
import 'package:bshare/src/infrastructure/services/app_logger.dart';
import 'package:bshare/src/infrastructure/services/file_server.dart';
import 'package:bshare/src/infrastructure/services/screen_share_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

Future<void> main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  final options =
      (ArgParser()
            ..addOption(
              'probe-mode',
              defaultsTo: const String.fromEnvironment(
                'BSHARE_PROBE_MODE',
                defaultValue: 'receiver',
              ),
            )
            ..addOption(
              'probe-port',
              defaultsTo: const String.fromEnvironment(
                'BSHARE_PROBE_PORT',
                defaultValue: '0',
              ),
            )
            ..addOption(
              'probe-control-port',
              defaultsTo: const String.fromEnvironment(
                'BSHARE_PROBE_CONTROL_PORT',
                defaultValue: '0',
              ),
            )
            ..addOption('probe-seconds', defaultsTo: '90')
            ..addOption('probe-resolution', defaultsTo: '1080')
            ..addOption('probe-fps', defaultsTo: '30')
            ..addOption(
              'viewer-ip',
              defaultsTo: const String.fromEnvironment(
                'BSHARE_PROBE_IP',
                defaultValue: '127.0.0.1',
              ),
            )
            ..addOption(
              'viewer-port',
              defaultsTo: const String.fromEnvironment(
                'BSHARE_PROBE_REMOTE_PORT',
                defaultValue: '53318',
              ),
            )
            ..addOption('viewer-name'))
          .parse(arguments);
  final sender = options['probe-mode'] == 'sender';
  if (!sender && options['probe-mode'] != 'receiver') {
    throw ArgumentError('probe-mode must be sender or receiver');
  }
  final logger = _ProbeLogger();
  final service = ScreenShareService(
    logger,
    AndroidScreenShareExecutionService(),
  );
  final fileServer = FileServer(logger)..fileReceptionEnabled = false;
  final directory = await Directory.systemTemp.createTemp(
    'bshare-native-probe-',
  );
  final control = await HttpServer.bind(
    InternetAddress.loopbackIPv4,
    int.parse(options['probe-control-port'] as String),
  );
  Future<void>? stopping;
  Timer? deadline;
  var ready = false;
  Future<void> stop() => stopping ??= () async {
    deadline?.cancel();
    await service.dispose();
    await fileServer.stop();
    await directory.delete(recursive: true);
    logger.info('BSHARE_PROBE_CLEANUP_COMPLETE');
  }();
  Map<String, Object?> status() => {
    'ready': ready,
    'mode': service.state.value.mode.name,
    'status': service.state.value.status,
    'error': service.state.value.error,
    'sourcePort': fileServer.port,
    'controlPort': control.port,
    'frameWidth': service.remoteRenderer.value.width,
    'frameHeight': service.remoteRenderer.value.height,
    'localFrameWidth': service.localRenderer.value.width,
    'localFrameHeight': service.localRenderer.value.height,
    'firstFrameRendered': logger.firstFrameRendered,
    'decodedFrames': logger.decodedFrames,
    'negotiatedCodec': logger.negotiatedCodec,
    'cleanupComplete': logger.cleanupComplete,
  };
  Future<void> quit({int exitCode = 0}) async {
    await control.close(force: true);
    if (Platform.isAndroid || Platform.isIOS) {
      await SystemNavigator.pop();
    } else {
      await ServicesBinding.instance.exitApplication(
        AppExitType.required,
        exitCode,
      );
    }
  }

  unawaited(() async {
    await for (final request in control) {
      if (request.method == 'POST' && request.uri.path == '/stop') {
        await stop();
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'cleanupComplete': true}));
        await request.response.close();
        await quit();
        break;
      }
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(status()));
      await request.response.close();
    }
  }());
  runApp(
    MaterialApp(
      home: Scaffold(
        body: sender
            ? const _SyntheticDesktop()
            : RTCVideoView(service.remoteRenderer),
      ),
    ),
  );
  try {
    await service.initialize();
    if (sender) {
      await fileServer.start(
        preferredPort: int.parse(options['probe-port'] as String),
        downloadDirectory: directory.path,
        autoAccept: false,
        onIncoming: (_) async => false,
        onSaved: ({required transfer, required savedPath}) async {},
        onProgress:
            ({
              required transfer,
              required receivedBytes,
              required totalBytes,
              required bytesPerSecond,
              required status,
              message,
              savedPath,
            }) {},
        onQueue:
            ({
              required senderId,
              required senderName,
              required transfers,
              controlHost,
              controlPort,
            }) {},
        resolveControl: (_) => TransferControl(),
      );
      await service.startSharing(
        fileServer,
        settings: ScreenCaptureSettings(
          resolution: int.parse(options['probe-resolution'] as String),
          frameRate: int.parse(options['probe-fps'] as String),
        ),
      );
    } else {
      await service.watch(
        DeviceInfo(
          id: 'probe',
          name: 'Synthetic fixture',
          platform: 'Fixture',
          ip: options['viewer-ip'] as String,
          port: int.parse(options['viewer-port'] as String),
          lastSeen: DateTime.now(),
        ),
      );
    }
    ready = true;
    logger.info('BSHARE_PROBE_READY ${jsonEncode(status())}');
    deadline = Timer(
      Duration(seconds: int.parse(options['probe-seconds'] as String)),
      () async {
        await stop();
        await quit();
      },
    );
  } catch (error) {
    logger.error('BSHARE_PROBE_START_FAILED', error);
    await stop();
    await quit(exitCode: 1);
  }
}

class _ProbeLogger extends AppLogger {
  bool firstFrameRendered = false;
  bool cleanupComplete = false;
  int decodedFrames = 0;
  String? negotiatedCodec;
  @override
  void info(String message) {
    firstFrameRendered |= message.contains('renderer received its first frame');
    cleanupComplete |= message == 'BSHARE_PROBE_CLEANUP_COMPLETE';
    final decoded = RegExp(r'decoded=(\d+)').firstMatch(message);
    if (decoded != null) {
      decodedFrames = int.parse(decoded.group(1)!);
    }
    const codecPrefix = 'Screen share negotiated codec: ';
    if (message.startsWith(codecPrefix)) {
      negotiatedCodec = message.substring(codecPrefix.length);
    }
    super.info(message);
  }
}

class _SyntheticDesktop extends StatefulWidget {
  const _SyntheticDesktop();
  @override
  State<_SyntheticDesktop> createState() => _SyntheticDesktopState();
}

class _SyntheticDesktopState extends State<_SyntheticDesktop>
    with SingleTickerProviderStateMixin {
  late final AnimationController animation = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 2),
  )..repeat();
  @override
  void dispose() {
    animation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final diameter =
          math.min(constraints.maxWidth, constraints.maxHeight) * 0.2;
      return AnimatedBuilder(
        animation: animation,
        builder: (context, _) => ColoredBox(
          color: const Color(0xff12324a),
          child: Center(
            child: Transform.translate(
              offset: Offset(
                math.sin(animation.value * math.pi * 2) *
                    constraints.maxWidth *
                    0.2,
                0,
              ),
              child: SizedBox(
                width: diameter,
                height: diameter,
                child: const DecoratedBox(
                  decoration: BoxDecoration(
                    color: Color(0xffefb841),
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}
