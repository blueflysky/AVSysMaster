import SwiftUI
import UIKit

/// Locks the interface to landscape; plist still lists all orientations for App Store / multitasking rules.
final class AppOrientationDelegate: NSObject, UIApplicationDelegate {
  func application(
    _ application: UIApplication,
    supportedInterfaceOrientationsFor window: UIWindow?
  ) -> UIInterfaceOrientationMask {
    .landscape
  }
}

@main
struct AVSysMasterApp: App {
  @UIApplicationDelegateAdaptor(AppOrientationDelegate.self) private var orientationDelegate
  @Environment(\.scenePhase) private var scenePhase

  @StateObject private var modelStore = UnifiedModelStore()
  @StateObject private var runtimeStore = RuntimeControlStore()
  @StateObject private var transport = TcpTransport()
  @StateObject private var mjpegStreamHub = MJPEGStreamHub()

  var body: some Scene {
    WindowGroup {
      RootShellView()
        .environmentObject(modelStore)
        .environmentObject(runtimeStore)
        .environmentObject(transport)
        .environmentObject(mjpegStreamHub)
        .task {
          await modelStore.load()
        }
    }
    .onChange(of: scenePhase) { _, phase in
      if phase == .background {
        transport.disconnectAll()
      } else if phase == .active {
        mjpegStreamHub.refreshAll()
      }
    }
  }
}
