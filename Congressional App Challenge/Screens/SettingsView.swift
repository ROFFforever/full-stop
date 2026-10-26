import SwiftUI

enum AppSettings {
    static let modelKey = "detectorModel"
    static let voiceKey = "voiceAlerts"
    static let lookCheckKey = "lookCheck"
    static let recordKey = "recordDrives"
    static let marksKey = "passengerMarks"
    static let facePreviewKey = "facePreview"
    static let reviewBoxesKey = "reviewBoxes"

    static var model: DetectorModel {
        UserDefaults.standard.string(forKey: modelKey).flatMap(DetectorModel.init(rawValue:)) ?? DetectionMode.balanced.model
    }
    static var voice: Bool { bool(voiceKey, default: true) }
    static var lookCheck: Bool { bool(lookCheckKey, default: true) }
    static var record: Bool { bool(recordKey, default: true) }
    static var passengerMarks: Bool {
        #if DEBUG
        bool(marksKey, default: false)
        #else
        false
        #endif
    }
    static var facePreview: Bool {
        #if DEBUG
        bool(facePreviewKey, default: false)
        #else
        false
        #endif
    }

    private static func bool(_ key: String, default value: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? value
    }
}

enum DetectionMode: CaseIterable, Identifiable {
    case high, balanced, batterySaver
    var id: Self { self }
    var model: DetectorModel {
        switch self {
        case .high: return .small1280
        case .balanced: return .small960
        case .batterySaver: return .nano960
        }
    }
    var label: String {
        switch self {
        case .high: return "High performance"
        case .balanced: return "Balanced"
        case .batterySaver: return "Battery saver"
        }
    }
    init?(_ model: DetectorModel) {
        guard let mode = Self.allCases.first(where: { $0.model == model }) else { return nil }
        self = mode
    }
}

struct SettingsView: View {
    @ObservedObject var detector: DetectorDashboard
    @AppStorage(AppSettings.voiceKey) private var voice = true
    @AppStorage(AppSettings.lookCheckKey) private var lookCheck = true
    @AppStorage(AppSettings.recordKey) private var record = true

    var body: some View {
        Form {
            Section("Detection") {
                Picker("Mode", selection: Binding(get: { DetectionMode(detector.model) },
                                                        set: { if let mode = $0 { detector.select(mode.model) } })) {
                    ForEach(DetectionMode.allCases) { Text($0.label).tag(Optional($0)) }
                    if DetectionMode(detector.model) == nil { Text("Custom").tag(DetectionMode?.none) }
                }
            }

            Section("Coaching") {
                Toggle("Spoken alerts", isOn: $voice)
                Toggle("Look-both-ways check", isOn: $lookCheck)
                Toggle("Save drive video", isOn: $record)
            }
        }
        .navigationTitle("Settings")
        .toolbar(.visible, for: .navigationBar)
    }
}
