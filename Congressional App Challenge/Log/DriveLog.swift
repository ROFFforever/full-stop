import Foundation
import Combine // ObservableObject/@Published.

// One finished drive: an hour-log line plus its report card. Saved as JSON on the phone.
// Fields added later must be optional so older saved drives still load.
struct DriveSummary: Codable, Identifiable, Equatable {
    struct StopSign: Codable, Equatable {
        let secondsIntoDrive: Double
        let outcome: String // "fullStop", "almostStopped", "rolling" or "unknown" (StopSignResult.Outcome). Pass-throughs aren't saved.
        let minSpeed: Double? // m/s.
        let peakBrakeG: Double
    }
    struct Brake: Codable, Equatable {
        let secondsIntoDrive: Double
        let g: Double // Negative = braking.
    }

    var id = UUID()
    let start: Date
    let end: Date
    let distanceMeters: Double
    let nightSeconds: Double
    let supervisor: String
    let stopSigns: [StopSign]
    let hardBrakes: [Brake]
    let hardAccels: [Brake]
    var recordingFolder: String? // Documents/Drives/<this>, for drive review. nil if not recorded.
    var pedestrianAlerts: Int? // Not built yet.
    var lookChecksPassed: Int? // nil = look check off or not calibrated this drive.
    var lookChecksMissed: Int?

    var duration: Double { end.timeIntervalSince(start) }
    var miles: Double { distanceMeters / 1609.344 }
    var fullStops: Int { stopSigns.filter { $0.outcome == "fullStop" }.count }
    var almostStops: Int { stopSigns.filter { $0.outcome == "almostStopped" }.count }
    var rollingStops: Int { stopSigns.filter { $0.outcome == "rolling" }.count }
}

// Every saved drive, newest first. Lives in Documents/drive-log.json.
@MainActor
final class DriveLog: ObservableObject {
    static let goalHours = 50.0
    static let goalNightHours = 10.0
    static let minSecondsToKeep = 60.0 // Shorter "drives" are test starts; not worth a line in the hour log.

    @Published private(set) var drives: [DriveSummary] = []
    private let file: URL

    init(file: URL? = nil) {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.file = file ?? documents.appendingPathComponent("drive-log.json")
        if let data = try? Data(contentsOf: self.file), let saved = try? Self.decoder.decode([DriveSummary].self, from: data) {
            drives = saved.sorted { $0.start > $1.start }
        }
    }

    var totalHours: Double { drives.reduce(0) { $0 + $1.duration } / 3600 }
    var nightHours: Double { drives.reduce(0) { $0 + $1.nightSeconds } / 3600 }

    func add(_ drive: DriveSummary) {
        guard drive.duration >= Self.minSecondsToKeep else { return }
        drives.insert(drive, at: 0)
        save()
    }

    // Removes the drive from the log and deletes its saved video and sensor data.
    func delete(_ drive: DriveSummary) {
        drives.removeAll { $0.id == drive.id }
        if let folder = drive.recordingFolder {
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            try? FileManager.default.removeItem(at: documents.appendingPathComponent("Drives").appendingPathComponent(folder))
        }
        save()
    }

    private func save() {
        guard let data = try? Self.encoder.encode(drives) else { return }
        try? data.write(to: file, options: .atomic)
    }

    // The hour log as a spreadsheet file, for a parent to review before certifying.
    func exportCSV() -> URL {
        let day = DateFormatter(); day.dateFormat = "yyyy-MM-dd"
        let time = DateFormatter(); time.dateFormat = "h:mm a"
        var lines = ["Date,Start,End,Hours,Night hours,Miles,Supervising driver"]
        for d in drives.sorted(by: { $0.start < $1.start }) {
            let name = "\"" + d.supervisor.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            lines.append([day.string(from: d.start), time.string(from: d.start), time.string(from: d.end),
                          String(format: "%.2f", d.duration / 3600), String(format: "%.2f", d.nightSeconds / 3600),
                          String(format: "%.1f", d.miles), name].joined(separator: ","))
        }
        lines.append(String(format: "Total,,,%.2f,%.2f,,", totalHours, nightHours))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Practice hour log.csv")
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = .prettyPrinted; return e }()
    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}
