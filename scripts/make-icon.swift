// Renders the app icon into an .iconset directory: `swift scripts/make-icon.swift <out.iconset>`.
// Drawn in code so the repo has no binary design files to keep in sync.
import AppKit

let output = URL(filePath: CommandLine.arguments[1], directoryHint: .isDirectory)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func render(pixels: Int) -> Data {
  let size = CGFloat(pixels)
  let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

  // macOS icon grid: the tile is ~80% of the canvas with a soft shadow around it.
  let inset = size * 0.1
  let tile = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
  let path = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225)

  let shadow = NSShadow()
  shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
  shadow.shadowBlurRadius = size * 0.02
  shadow.shadowOffset = NSSize(width: 0, height: -size * 0.008)
  NSGraphicsContext.saveGraphicsState()
  shadow.set()
  NSColor.black.setFill()
  path.fill()
  NSGraphicsContext.restoreGraphicsState()

  NSGradient(
    colors: [
      NSColor(red: 0.10, green: 0.13, blue: 0.16, alpha: 1),
      NSColor(red: 0.05, green: 0.07, blue: 0.09, alpha: 1),
    ])!.draw(in: path, angle: -90)

  // Three signal lights: CI, review, merge.
  let lights: [NSColor] = [.systemGreen, .systemOrange, .systemRed]
  let lightSize = tile.width * 0.085
  for (index, color) in lights.enumerated() {
    let x = tile.minX + tile.width * 0.2 + CGFloat(index) * lightSize * 1.6
    let rect = NSRect(x: x, y: tile.maxY - tile.height * 0.22, width: lightSize, height: lightSize)
    (index == 0 ? color : color.withAlphaComponent(0.35)).setFill()
    NSBezierPath(ovalIn: rect).fill()
  }

  let configuration = NSImage.SymbolConfiguration(pointSize: tile.width * 0.46, weight: .semibold)
    .applying(.init(paletteColors: [NSColor(red: 0.30, green: 0.85, blue: 0.45, alpha: 1)]))
  if let symbol = NSImage(systemSymbolName: "arrow.triangle.pull", accessibilityDescription: nil)?
    .withSymbolConfiguration(configuration)
  {
    let symbolSize = symbol.size
    let rect = NSRect(
      x: tile.midX - symbolSize.width / 2, y: tile.midY - symbolSize.height / 2 - tile.height * 0.06,
      width: symbolSize.width, height: symbolSize.height)
    symbol.draw(in: rect)
  }

  NSGraphicsContext.restoreGraphicsState()
  return rep.representation(using: .png, properties: [:])!
}

for points in [16, 32, 128, 256, 512] {
  for scale in [1, 2] {
    let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
    try render(pixels: points * scale).write(to: output.appending(path: name))
  }
}
