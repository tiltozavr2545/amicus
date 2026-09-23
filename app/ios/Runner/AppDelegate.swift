import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    let launched = super.application(application, didFinishLaunchingWithOptions: launchOptions)
    reserveSpaceForIPadWindowControls()
    return launched
  }

  /// iPadOS 26's windowed-app mode draws macOS-style traffic-light window
  /// controls in the top-left corner. On some builds iOS does not report
  /// them as part of the safe area, so our own top-left icons (back
  /// buttons, etc.) render underneath them and become unreachable. Rather
  /// than detect windowed vs. full-screen state (no reliable public API,
  /// and it changes at any time via drag/resize), reserve a small extra
  /// top inset unconditionally on iPad, matching how other apps keep their
  /// bar clear of this control regardless of window mode.
  private func reserveSpaceForIPadWindowControls() {
    guard UIDevice.current.userInterfaceIdiom == .pad else { return }
    guard let controller = window?.rootViewController else { return }
    controller.additionalSafeAreaInsets.top = 24
  }
}
