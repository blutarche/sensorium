#!/usr/bin/env python3
"""Exercise the renderer's actual colour conversion with a Display P3 image."""

from pathlib import Path
import subprocess
import sys
import tempfile


if sys.platform != "darwin":
    print("SKIP: UI preview colour conversion requires CoreGraphics")
    raise SystemExit(0)

root = Path(__file__).resolve().parent.parent
source = (root / "Scripts/render-ui-previews.swift").read_text()
start = source.index("let sRGB =")
end = source.index("/// Draws a view", start)
fixture = """
import AppKit

func fail(_ message: String) -> Never {
    fputs("FAIL: \\(message)\\n", stderr)
    exit(1)
}
""" + source[start:end] + """
let wide = CGColorSpace(name: CGColorSpace.displayP3)!
let expected: [Int] = [226, 111, 92]
let ink = CGColor(colorSpace: sRGB, components: [226.0/255, 111.0/255, 92.0/255, 1])!
let context = CGContext(data: nil, width: 4, height: 3, bitsPerComponent: 8,
    bytesPerRow: 0, space: wide,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
context.setFillColor(ink)
context.fill(CGRect(x: 0, y: 0, width: 4, height: 3))
let converted = inSRGB(context.makeImage()!)
guard converted.colorSpace?.name == CGColorSpace.sRGB else {
    fail("preview retained the source colour profile")
}
guard converted.width == 4, converted.height == 3 else {
    fail("preview colour conversion changed the image dimensions")
}
let actual = Array((converted.dataProvider!.data! as Data).prefix(3)).map(Int.init)
guard zip(actual, expected).allSatisfy({ abs($0 - $1) <= 2 }) else {
    fail("preview changed the sRGB error ink: \\(actual)")
}
print("PASS: UI preview converts Display P3 to sRGB with correct error ink \\(actual)")
"""

with tempfile.TemporaryDirectory(prefix="preview-colors-", dir=root / ".build") as folder:
    fixture_path = Path(folder) / "fixture.swift"
    fixture_path.write_text(fixture)
    result = subprocess.run(["swift", str(fixture_path)], cwd=root)
    raise SystemExit(result.returncode)
