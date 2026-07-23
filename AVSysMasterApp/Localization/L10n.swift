import Foundation

enum L10n {
  static var control: String { loc("control") }
  static var settings: String { loc("settings") }
  static var editor: String { loc("editor") }
  static var devices: String { loc("devices") }
  static var commands: String { loc("commands") }
  static var modelEditor: String { loc("model_editor") }
  static var operationMode: String { loc("operation_mode") }
  static var save: String { loc("save") }
  static var publish: String { loc("publish") }
  static var rollback: String { loc("rollback") }
  static var addButton: String { loc("add_button") }
  static var addSlider: String { loc("add_slider") }
  static var addToggle: String { loc("add_toggle") }
  static var addLogo: String { loc("add_logo") }
  static var spacing: String { loc("spacing") }
  static var runMode: String { loc("run_mode") }
  static var editMode: String { loc("edit_mode") }
  static var sendFailed: String { loc("send_failed") }
  static var validationFailed: String { loc("validation_failed") }
  static var importConfig: String { loc("import_config") }
  static var exportConfig: String { loc("export_config") }
  static var matrixDisplays: String { loc("matrix_displays") }
  static var matrixVideoSources: String { loc("matrix_video_sources") }
  static var liveMatrixSources: String { loc("live_matrix_sources") }
  static var liveMatrixDisplays: String { loc("live_matrix_displays") }
  static var lmEditorIOColumns: String { loc("lm_editor_io_columns") }
  static var lmEditorNameCmd: String { loc("lm_editor_name_cmd") }
  static var lmEditorMacIpPort: String { loc("lm_editor_mac_ip_port") }
  static var lmEditorDisplayFooter: String { loc("lm_editor_display_footer") }
  static var lmEditorStreamFooter: String { loc("lm_editor_stream_footer") }
  static var lmEditorRouteID: String { loc("lm_editor_route_id") }
  static var lmEditorMacPlaceholder: String { loc("lm_editor_mac_placeholder") }
  static var lmEditorDeviceIP: String { loc("lm_editor_device_ip") }
  static var lmEditorStreamPort: String { loc("lm_editor_stream_port") }
  static var lmEditorFetchAll: String { loc("lm_editor_fetch_all") }
  static var lmEditorStreamServerRequired: String { loc("lm_editor_stream_server_required") }
  static var lmEditorMacEmptyWarning: String { loc("lm_editor_mac_empty_warning") }
  static var lmEditorIpInvalidWarning: String { loc("lm_editor_ip_invalid_warning") }
  static var lmEditorPreviewStream: String { loc("lm_editor_preview_stream") }
  static var lmEditorRouteBlacklist: String { loc("lm_editor_route_blacklist") }
  static func lmEditorChannelsAdded(_ n: Int) -> String { String(format: loc("lm_editor_channels_added"), n) }
  static var lmChipSettings: String { loc("lm_chip_settings") }
  static var lmChipName: String { loc("lm_chip_name") }
  static var lmChipCommand: String { loc("lm_chip_command") }
  static var lmChipIndex: String { loc("lm_chip_index") }
  static var lmChipParent: String { loc("lm_chip_parent") }
  static var lmChipEditParent: String { loc("lm_chip_edit_parent") }
  static var lmChipCommandOverride: String { loc("lm_chip_command_override") }
  static var lmChipCommandTemplateHint: String { loc("lm_chip_command_template_hint") }
  static var lmChipCommandPreview: String { loc("lm_chip_command_preview") }
  static var lmChipStreamDevice: String { loc("lm_chip_stream_device") }
  static var lmChipInheritedDevice: String { loc("lm_chip_inherited_device") }
  static var lmChipNoParentDevice: String { loc("lm_chip_no_parent_device") }
  static var lmEditorFetchDevicelist: String { loc("lm_editor_fetch_devicelist") }
  static var lmEditorPickDevice: String { loc("lm_editor_pick_device") }
  static var lmEditorDevicelistEmpty: String { loc("lm_editor_devicelist_empty") }
  static var lmEditorDevicelistError: String { loc("lm_editor_devicelist_error") }
  static func lmEditorDevicelistCount(_ n: Int) -> String { String(format: loc("lm_editor_devicelist_count"), n) }
  static func lmEditorDevicelistEncodersCount(_ n: Int) -> String { String(format: loc("lm_editor_devicelist_encoders_count"), n) }
  static func lmEditorDevicelistDecodersCount(_ n: Int) -> String { String(format: loc("lm_editor_devicelist_decoders_count"), n) }
  static var lmEditorPickDeviceNone: String { loc("lm_editor_pick_device_none") }
  static var addVolumeLevel: String { loc("add_level") }
  static var volumeLevelTitle: String { loc("level_title") }
  static func holdToTurnOn(_ n: Int) -> String { String(format: loc("hold_to_turn_on"), n) }
  static func holdToTurnOff(_ n: Int) -> String { String(format: loc("hold_to_turn_off"), n) }

  private static func loc(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
  }
}
