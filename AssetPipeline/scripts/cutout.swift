// Step 3: lift the character off its black background with Vision's
// on-device subject segmentation and write an RGBA PNG per pose.
//
// Usage: swift cutout.swift <in_dir> <out_dir>
import AppKit
import CoreImage
import Vision

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write(Data("usage: cutout.swift <in_dir> <out_dir>\n".utf8))
    exit(2)
}
let inDir = URL(fileURLWithPath: args[1])
let outDir = URL(fileURLWithPath: args[2])
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let context = CIContext()
let files = try FileManager.default.contentsOfDirectory(at: inDir, includingPropertiesForKeys: nil)
    .filter { $0.pathExtension == "png" }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }

for file in files {
    let handler = VNImageRequestHandler(url: file)
    let request = VNGenerateForegroundInstanceMaskRequest()
    try handler.perform([request])
    guard let observation = request.results?.first else {
        print("\(file.lastPathComponent): no subject found")
        continue
    }
    // The soft mask alone, at full input resolution; compositing happens in Python
    // so the RGB stays untouched and only alpha comes from Vision.
    let mask = try observation.generateScaledMaskForImage(
        forInstances: observation.allInstances, from: handler)
    let image = CIImage(cvPixelBuffer: mask)
    let out = outDir.appendingPathComponent(file.lastPathComponent)
    guard let space = CGColorSpace(name: CGColorSpace.linearGray) else { exit(1) }
    try context.writePNGRepresentation(of: image, to: out, format: .L8, colorSpace: space)
    print("\(file.lastPathComponent): \(observation.allInstances.count) instance(s)")
}
