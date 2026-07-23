import SwiftUI
import UniformTypeIdentifiers

struct UnifiedModelDocument: FileDocument {
  static var readableContentTypes:  [UTType] { [.json] }
  static var writableContentTypes:  [UTType] { [.json] }

  var data: Data

  init(data: Data = Data()) {
    self.data = data
  }

  init(configuration: ReadConfiguration) throws {
    guard let content = configuration.file.regularFileContents else {
      throw CocoaError(.fileReadCorruptFile)
    }
    data = content
  }

  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: data)
  }
}
