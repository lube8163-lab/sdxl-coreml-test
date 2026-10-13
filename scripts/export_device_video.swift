import AppKit
import AVFoundation
import Foundation

// File-only media processing. Does not control apps or synthesize device frames.
let args = CommandLine.arguments
guard args.count >= 3 else { fatalError("info <movie> | frame <movie> <seconds> <png> | export <movie> <mp4> <start> <duration>") }
let asset = AVURLAsset(url: URL(fileURLWithPath: args[2]))
let duration = try await asset.load(.duration)
let tracks = try await asset.loadTracks(withMediaType: .video)
guard let track = tracks.first else { fatalError("No video track") }
let size = try await track.load(.naturalSize)
let transform = try await track.load(.preferredTransform)
let frameRate = try await track.load(.nominalFrameRate)
if args[1] == "info" {
    print("duration=\(duration.seconds) natural=\(size) transform=\(transform) fps=\(frameRate)")
} else if args[1] == "frame" {
    guard args.count == 5, let seconds = Double(args[3]) else { fatalError("Invalid frame arguments") }
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    let result = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
    let bitmap = NSBitmapImageRep(cgImage: result.image)
    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[4]))
} else if args[1] == "export" {
    guard args.count == 6, let start = Double(args[4]), let length = Double(args[5]),
          start >= 0, length > 0, start + length <= duration.seconds + 0.1 else { fatalError("Invalid export range") }
    let output = URL(fileURLWithPath: args[3])
    guard !FileManager.default.fileExists(atPath: output.path),
          let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
        fatalError("Output exists or exporter unavailable")
    }
    let composition = AVMutableVideoComposition()
    composition.renderSize = CGSize(width: 720, height: 1280)
    composition.frameDuration = CMTime(value: 1, timescale: 30)
    let bounds = CGRect(origin: .zero, size: size).applying(transform).standardized
    let scale = min(720 / bounds.width, 1280 / bounds.height)
    let adjusted = transform.concatenating(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
        .concatenating(CGAffineTransform(scaleX: scale, y: scale))
        .concatenating(CGAffineTransform(translationX: (720 - bounds.width * scale) / 2,
                                        y: (1280 - bounds.height * scale) / 2))
    let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
    layer.setTransform(adjusted, at: .zero)
    let instruction = AVMutableVideoCompositionInstruction()
    instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
    instruction.layerInstructions = [layer]
    composition.instructions = [instruction]
    exporter.videoComposition = composition
    exporter.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                    duration: CMTime(seconds: length, preferredTimescale: 600))
    exporter.shouldOptimizeForNetworkUse = true
    let audio = AVMutableAudioMix()
    audio.inputParameters = try await asset.loadTracks(withMediaType: .audio).map {
        let input = AVMutableAudioMixInputParameters(track: $0)
        input.setVolume(0, at: .zero)
        return input
    }
    exporter.audioMix = audio
    try await exporter.export(to: output, as: .mp4)
    print(output.path)
}
