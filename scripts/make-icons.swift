// Generates the custom SF Symbols in App/Openfeed/Resources/Assets.xcassets/Icons from stroke icons drawn
// on a 24-unit grid (1.75 stroke, round caps and joins).
//   swiftc -O scripts/make-icons.swift -o /tmp/make-icons && /tmp/make-icons App/Openfeed/Resources/Assets.xcassets/Icons
import CoreGraphics
import Foundation

let stroke: CGFloat = 1.75
func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

func poly(_ p: CGMutablePath, _ pts: [CGPoint], close: Bool = false) {
    p.move(to: pts[0]); for q in pts.dropFirst() { p.addLine(to: q) }
    if close { p.closeSubpath() }
}
/// Polygon with rounded corners (radius per corner; 0 = sharp).
func rounded(_ p: CGMutablePath, _ pts: [CGPoint], _ radii: [CGFloat]) {
    let n = pts.count
    let start = CGPoint(x: (pts[0].x + pts[n - 1].x) / 2, y: (pts[0].y + pts[n - 1].y) / 2)
    p.move(to: start)
    for i in 0..<n {
        let c = pts[i], next = pts[(i + 1) % n]
        if radii[i] > 0 { p.addArc(tangent1End: c, tangent2End: next, radius: radii[i]) } else { p.addLine(to: c) }
    }
    p.closeSubpath()
}
func rrect(_ p: CGMutablePath, _ r: CGRect, _ radius: CGFloat) {
    p.addRoundedRect(in: r, cornerWidth: radius, cornerHeight: radius)
}

struct Icon { let name: String; let strokes: CGPath; var fills: CGPath? = nil }
var icons: [Icon] = []
func icon(_ name: String, fill: ((CGMutablePath) -> Void)? = nil, _ build: (CGMutablePath) -> Void) {
    let p = CGMutablePath(); build(p)
    var f: CGPath?
    if let fill { let fp = CGMutablePath(); fill(fp); f = fp }
    icons.append(Icon(name: name, strokes: p, fills: f))
}

icon("sidebar") { p in rrect(p, CGRect(x: 3, y: 4, width: 18, height: 16), 3); poly(p, [P(9.5, 4), P(9.5, 20)]) }
icon("split") { p in rrect(p, CGRect(x: 3, y: 4, width: 18, height: 16), 3); poly(p, [P(12, 4), P(12, 20)]) }
icon("search") { p in p.addEllipse(in: CGRect(x: 4, y: 4, width: 13.5, height: 13.5)); poly(p, [P(15.5, 15.5), P(20.5, 20.5)]) }
icon("refresh") { p in
    p.addArc(center: P(12, 12), radius: 8, startAngle: 0, endAngle: -.pi / 3.2, clockwise: false)
    poly(p, [P(19.5, 3.5), P(19.5, 8.5), P(14.5, 8.5)])
}
let bookmarkPts = [P(6, 3), P(18, 3), P(18, 21), P(12, 17), P(6, 21)]
let bookmarkR: [CGFloat] = [2, 2, 0.5, 0.5, 0.5]
icon("bookmark") { p in rounded(p, bookmarkPts, bookmarkR) }
icon("bookmark.fill", fill: { p in rounded(p, bookmarkPts, bookmarkR) }) { p in rounded(p, bookmarkPts, bookmarkR) }
icon("external") { p in
    poly(p, [P(14, 3.5), P(20.5, 3.5), P(20.5, 10)]); poly(p, [P(20.5, 3.5), P(11, 13)])
    rounded(p, [P(10, 5.5), P(5.5, 5.5), P(5.5, 18.5), P(18.5, 18.5), P(18.5, 14)], [0, 2.5, 2.5, 2.5, 0])
}
icon("share") { p in
    let t = CGMutablePath()
    t.move(to: P(3.5, 14.5)); t.addLine(to: P(3.5, 18)); t.addArc(tangent1End: P(3.5, 20.5), tangent2End: P(6, 20.5), radius: 2.5)
    t.addLine(to: P(18, 20.5)); t.addArc(tangent1End: P(20.5, 20.5), tangent2End: P(20.5, 18), radius: 2.5); t.addLine(to: P(20.5, 14.5))
    p.addPath(t)
    poly(p, [P(7.5, 8), P(12, 3.5), P(16.5, 8)]); poly(p, [P(12, 3.5), P(12, 15)])
}
icon("send") { p in poly(p, [P(21, 3), P(14.5, 21), P(11, 13), P(3, 9.5)], close: true); poly(p, [P(21, 3), P(11, 13)]) }
icon("expand") { p in
    poly(p, [P(14.5, 3.5), P(20.5, 3.5), P(20.5, 9.5)]); poly(p, [P(9.5, 20.5), P(3.5, 20.5), P(3.5, 14.5)])
    poly(p, [P(20.5, 3.5), P(14, 10)]); poly(p, [P(3.5, 20.5), P(10, 14)])
}
icon("collapse") { p in
    poly(p, [P(4, 14), P(10, 14), P(10, 20)]); poly(p, [P(20, 10), P(14, 10), P(14, 4)])
    poly(p, [P(14, 10), P(20.5, 3.5)]); poly(p, [P(3.5, 20.5), P(10, 14)])
}
icon("close") { p in poly(p, [P(6, 6), P(18, 18)]); poly(p, [P(18, 6), P(6, 18)]) }
icon("plus") { p in poly(p, [P(12, 5), P(12, 19)]); poly(p, [P(5, 12), P(19, 12)]) }

// Template geometry (SF Symbols template, point size 100): cap height 70.459 above the baseline.
let scale: CGFloat = 100 / 24
let baselineM: CGFloat = 1126, caplineM: CGFloat = 1055.54
let midY = (baselineM + caplineM) / 2
let left: CGFloat = 1400

func svgPath(_ path: CGPath) -> String {
    var d = ""
    func f(_ v: CGFloat) -> String { String(format: "%.3f", v) }
    func t(_ q: CGPoint) -> String { "\(f(left + q.x * scale)) \(f(midY + (q.y - 12) * scale))" }
    path.applyWithBlock { el in
        let pts = el.pointee.points
        switch el.pointee.type {
        case .moveToPoint: d += "M\(t(pts[0]))"
        case .addLineToPoint: d += "L\(t(pts[0]))"
        case .addQuadCurveToPoint: d += "Q\(t(pts[0])) \(t(pts[1]))"
        case .addCurveToPoint: d += "C\(t(pts[0])) \(t(pts[1])) \(t(pts[2]))"
        case .closeSubpath: d += "Z"
        @unknown default: break
        }
    }
    return d
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
for ic in icons {
    var outline = ic.strokes.copy(strokingWithWidth: stroke, lineCap: .round, lineJoin: .round, miterLimit: 10)
    if let fills = ic.fills { outline = outline.union(fills, using: .winding) } else { outline = outline.normalized(using: .winding) }
    let svg = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">
    <svg version="1.1" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="3300" height="2200">
     <g id="Notes">
      <text id="template-version" x="2934" y="1933" style="font-size:13px">Template v.2.0</text>
     </g>
     <g id="Guides">
      <line id="Baseline-S" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;" x1="263" x2="3036" y1="696" y2="696"/>
      <line id="Capline-S" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;" x1="263" x2="3036" y1="625.541" y2="625.541"/>
      <line id="Baseline-L" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;" x1="263" x2="3036" y1="1556" y2="1556"/>
      <line id="Capline-L" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;" x1="263" x2="3036" y1="1485.54" y2="1485.54"/>
      <line id="Baseline-M" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;" x1="263" x2="3036" y1="\(baselineM)" y2="\(baselineM)"/>
      <line id="Capline-M" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;" x1="263" x2="3036" y1="\(caplineM)" y2="\(caplineM)"/>
      <line id="left-margin" style="fill:none;stroke:#00AEEF;stroke-width:0.5;opacity:1.0;" x1="\(left)" x2="\(left)" y1="1030" y2="1150"/>
      <line id="right-margin" style="fill:none;stroke:#00AEEF;stroke-width:0.5;opacity:1.0;" x1="\(left + 100)" x2="\(left + 100)" y1="1030" y2="1150"/>
     </g>
     <g id="Symbols">
      <g id="Regular-M">
       <path d="\(svgPath(outline))"/>
      </g>
     </g>
    </svg>
    """
    let dir = out.appendingPathComponent("of.\(ic.name).symbolset")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try! svg.write(to: dir.appendingPathComponent("of.\(ic.name).svg"), atomically: true, encoding: .utf8)
    let contents = #"{"info":{"author":"xcode","version":1},"symbols":[{"filename":"of.\#(ic.name).svg","idiom":"universal"}]}"#
    try! contents.write(to: dir.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
}
print("wrote \(icons.count) symbols")
