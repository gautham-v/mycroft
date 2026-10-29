import Foundation
import Testing
@testable import OpenDispatchCore
@Test func zscratch() throws {
    let page = try String(contentsOfFile: "/private/tmp/claude-501/-Users-gautham-Code-personal-opendispatch/96043e92-814a-4efc-a408-19d0ef281d9e/scratchpad/a2/raw/18.html", encoding: .utf8)
    let d = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "/private/tmp/claude-501/-Users-gautham-Code-personal-opendispatch/96043e92-814a-4efc-a408-19d0ef281d9e/scratchpad/a2/int/out/18.json"))) as! [String: Any]
    let art = d["html"] as! String
    print("ZZ statesCutOff", PaywallDetection.statesCutOff(page), "walled", PaywallDetection.isWalled(pageHTML: page, articleHTML: art, url: "https://www.businessinsider.com/x"))
    print("ZZ words", ExtractionDOM.plainText(art).split(whereSeparator: { $0.isWhitespace }).count)
}
