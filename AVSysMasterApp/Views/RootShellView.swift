import SwiftUI

struct RootShellView: View {
  @State private var showSettings = false

  var body: some View {
    ControlPageView(showSettings: $showSettings)
      .fullScreenCover(isPresented: $showSettings) {
        SettingsView()
      }
  }
}
