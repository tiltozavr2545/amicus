import Flutter
import UIKit

/// IMM-251: iOS 27 requires apps to adopt the UIScene lifecycle or they
/// crash on launch. `window` now belongs to the scene (via
/// FlutterSceneDelegate), not the app delegate, so the iPad window-controls
/// workaround from IMM-170 moved here from AppDelegate.
class SceneDelegate: FlutterSceneDelegate {
  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    super.scene(scene, willConnectTo: session, options: connectionOptions)
    reserveSpaceForIPadWindowControls()
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
