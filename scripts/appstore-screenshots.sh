#!/bin/bash
# appstore-screenshots.sh — the App Store's screenshots (2880×1800) from the guide's, which
# scripts/capture-screenshots.sh makes from the demo data: each window centred on the
# window background colour, nothing cropped, numbered in upload order. Opaque and sRGB: the
# guide's images keep the windows' shadows as transparency, which an App Store screenshot
# can't have (sips pads an image but can't flatten it), and the display's colour profile.
# Writes .build/appstore/screenshots/.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=.build/appstore/screenshots
TMP="$(mktemp -d)"
finished=0
trap 'rm -rf "$TMP"; [ "$finished" = 1 ] || exit 1' EXIT
# The cross-server join first (what sets the app apart), then a query across four servers,
# Content, Structure and Home. The guide has no dark-mode image.
NAMES="cross-engine-join hero content structure home"
pairs=(); n=0
for name in $NAMES; do
  src="guide/images/$name.png"
  [ -f "$src" ] || { echo "missing $src: run scripts/capture-screenshots.sh"; exit 1; }
  n=$((n + 1)); pairs+=("$src" "$OUT/$n-$name.png")
done
cat > "$TMP/flatten.swift" <<'SWIFT'
// Each source window, scaled to fit inside the canvas's margins (90 px left and right, 72
// top and bottom), centred on the window background colour (#ECECEC) on whole pixels,
// written as an opaque PNG.
import CoreGraphics
import Foundation
import ImageIO

let width = 2880, height = 1800
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
var args = Array(CommandLine.arguments.dropFirst())
while args.count >= 2 {
    let source = URL(fileURLWithPath: args.removeFirst()), target = URL(fileURLWithPath: args.removeFirst())
    guard let file = CGImageSourceCreateWithURL(source as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(file, 0, nil) else {
        FileHandle.standardError.write(Data("can't read \(source.path)\n".utf8)); exit(1)
    }
    let scale = min(Double(width - 180) / Double(image.width), Double(height - 144) / Double(image.height))
    let w = (Double(image.width) * scale).rounded(), h = (Double(image.height) * scale).rounded()
    let frame = CGRect(x: ((Double(width) - w) / 2).rounded(), y: ((Double(height) - h) / 2).rounded(), width: w, height: h)
    let canvas = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                           space: srgb, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let ground: CGFloat = 0xEC / 255
    canvas.setFillColor(CGColor(colorSpace: srgb, components: [ground, ground, ground, 1])!)
    canvas.fill(CGRect(x: 0, y: 0, width: width, height: height))
    // A capture may carry a faint shadow layer out to its edges (a corner pixel of black at a
    // few percent): under the image goes the colour that layer turns into the background,
    // or the image's edge would show as a box.
    var corner = [UInt8](repeating: 0, count: 4)
    let probe = CGContext(data: &corner, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: srgb,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    probe.draw(image.cropping(to: CGRect(x: 0, y: 0, width: 1, height: 1))!, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    let alpha = CGFloat(corner[3]) / 255
    let under = (0..<3).map { min(1, max(0, (ground - CGFloat(corner[$0]) / 255) / (1 - alpha))) }
    canvas.setFillColor(CGColor(colorSpace: srgb, components: under + [1])!)
    canvas.fill(frame)
    canvas.interpolationQuality = .high
    canvas.draw(image, in: frame)
    guard let out = CGImageDestinationCreateWithURL(target as CFURL, "public.png" as CFString, 1, nil) else { exit(1) }
    CGImageDestinationAddImage(out, canvas.makeImage()!, nil)
    guard CGImageDestinationFinalize(out) else { exit(1) }
}
SWIFT
rm -rf "$OUT"; mkdir -p "$OUT"
swift "$TMP/flatten.swift" "${pairs[@]}"
for f in "$OUT"/*.png; do
  got=$(sips -g pixelWidth -g pixelHeight -g hasAlpha "$f" | tail -3 | awk '{print $2}' | tr '\n' ' ')
  [ "$got" = "2880 1800 no " ] || { echo "FAIL: $f is $got"; exit 1; }
  echo "2880×1800, opaque: $f"
done
finished=1
