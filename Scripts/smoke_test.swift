// macOS command-line check of the same Core ML + Vision path used on iPhone.
// Usage: swift Scripts/smoke_test.swift model.mlpackage photo.jpg [...]
import Foundation
import CoreML
import Vision

let args = CommandLine.arguments
let compiled = try MLModel.compileModel(at: URL(fileURLWithPath: args[1]))
let config = MLModelConfiguration()
config.computeUnits = .cpuOnly
let model = try VNCoreMLModel(for: MLModel(contentsOf: compiled, configuration: config))
for path in args.dropFirst(2) {
    let request = VNCoreMLRequest(model: model)
    request.imageCropAndScaleOption = .scaleFill
    let handler = VNImageRequestHandler(url: URL(fileURLWithPath: path), orientation: .up)
    let start = Date()
    try handler.perform([request])
    guard let objects = request.results as? [VNRecognizedObjectObservation] else {
        fatalError("Model did not return object observations")
    }
    let signs = objects.filter { $0.labels.first?.identifier == "stop sign" && ($0.labels.first?.confidence ?? 0) >= 0.4 }
    print("\(URL(fileURLWithPath: path).lastPathComponent): \(signs.count) stop signs, \(Int(Date().timeIntervalSince(start) * 1000)) ms (Mac CPU)")
    for sign in signs { print("  confidence=\(sign.labels[0].confidence), box=\(sign.boundingBox)") }
}
