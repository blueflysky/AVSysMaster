import SwiftUI

struct VisualTheme {
  static func backgroundImage(path: String?) -> Image? {
    guard let path, FileManager.default.fileExists(atPath: path), let uiImage = UIImage(contentsOfFile: path) else {
      return nil
    }
    return Image(uiImage: uiImage)
  }

  static func logoImage(path: String?) -> Image? {
    guard let path, FileManager.default.fileExists(atPath: path), let uiImage = UIImage(contentsOfFile: path) else {
      return nil
    }
    return Image(uiImage: uiImage)
  }
}

struct AlertMessage: Identifiable {
  let id = UUID()
  let message: String
}
