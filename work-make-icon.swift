import AppKit
import ImageIO

let svgURL = URL(fileURLWithPath: CommandLine.arguments[1])
let pngURL = URL(fileURLWithPath: CommandLine.arguments[2])
guard let image = NSImage(contentsOf: svgURL) else { fatalError("Cannot load SVG logo") }
let size = NSSize(width: 1024, height: 1024)
image.size = size
guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { fatalError("Cannot allocate bitmap") }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
image.draw(in: NSRect(origin: .zero, size: size))
NSGraphicsContext.restoreGraphicsState()
guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("Cannot encode PNG") }
try data.write(to: pngURL)
