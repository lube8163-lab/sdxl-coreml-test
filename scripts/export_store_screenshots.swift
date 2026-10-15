import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Encoding only: preserve the captured UI's dimensions and color space, and
// write an RGB PNG without an alpha channel for App Store Connect.
let arguments = CommandLine.arguments
guard arguments.count >= 3 else { fatalError("Usage: export_store_screenshots.swift <output-directory> <captured-png>...") }
let output = URL(fileURLWithPath: arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for name in arguments.dropFirst(2) {
    let input = URL(fileURLWithPath: name)
    guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
          let context = CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
        fatalError("Cannot encode \(input.lastPathComponent)")
    }
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let destinationURL = output.appendingPathComponent(input.lastPathComponent)
    guard let rgb = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(destinationURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("Cannot create RGB PNG")
    }
    CGImageDestinationAddImage(destination, rgb, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("PNG export failed") }
    print(destinationURL.path)
}
