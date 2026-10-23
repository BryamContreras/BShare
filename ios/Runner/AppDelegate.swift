import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var cameraChannel: FlutterMethodChannel?
  private var cameraOriginalBrightness: CGFloat?
  private var cameraOriginalIdleTimer: Bool?
  private var cameraAwake = false
  private var cameraDimmed = false
  private var cameraBackgroundObserver: NSObjectProtocol?
  private var cameraForegroundObserver: NSObjectProtocol?
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "BShareCameraDisplay") else { return }
    let channel = FlutterMethodChannel(name: "bshare/camera", binaryMessenger: registrar.messenger())
    cameraChannel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return result(nil) }
      switch call.method {
      case "setDisplayState":
        let arguments = call.arguments as? [String: Any] ?? [:]
        let awake = arguments["awake"] as? Bool ?? false
        let dimmed = awake && (arguments["dimmed"] as? Bool ?? false)
        if awake && self.cameraOriginalBrightness == nil {
          self.cameraOriginalBrightness = UIScreen.main.brightness
          self.cameraOriginalIdleTimer = UIApplication.shared.isIdleTimerDisabled
        }
        self.cameraAwake = awake
        self.cameraDimmed = dimmed
        self.applyCameraDisplay()
        if !awake {
          self.cameraOriginalBrightness = nil
          self.cameraOriginalIdleTimer = nil
        }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    cameraBackgroundObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
    ) { [weak self] _ in
      // iOS brightness is global; never dim another app after leaving BShare.
      guard let self = self else { return }
      if let brightness = self.cameraOriginalBrightness { UIScreen.main.brightness = brightness }
    }
    cameraForegroundObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in self?.applyCameraDisplay() }
  }

  private func applyCameraDisplay() {
    guard cameraOriginalIdleTimer != nil || cameraOriginalBrightness != nil else { return }
    UIApplication.shared.isIdleTimerDisabled = cameraAwake || (cameraOriginalIdleTimer ?? false)
    if let original = cameraOriginalBrightness {
      UIScreen.main.brightness = cameraAwake && cameraDimmed && UIApplication.shared.applicationState == .active ? 0.01 : original
    }
  }

  deinit {
    if let observer = cameraBackgroundObserver { NotificationCenter.default.removeObserver(observer) }
    if let observer = cameraForegroundObserver { NotificationCenter.default.removeObserver(observer) }
  }
}
