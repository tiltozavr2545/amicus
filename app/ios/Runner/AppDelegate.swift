import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // IMM-251: iOS 27's UIScene lifecycle moves plugin registration out of
  // didFinishLaunchingWithOptions into this callback, which fires once the
  // implicit Flutter engine exists. The iPad window-controls inset
  // (IMM-170) moved to SceneDelegate, since it needs `window`, which now
  // belongs to the scene rather than the app delegate.
  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}
