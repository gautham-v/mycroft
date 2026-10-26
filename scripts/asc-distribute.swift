// Hands an uploaded iOS build to the TestFlight Internal group, so it shows up on the testers' phones.
// The group can't be set to receive every build automatically through the API, and App Store Connect
// never does it on its own, so release-ios.sh runs this after each upload.
//
//   swift scripts/asc-distribute.swift <CFBundleVersion>
//
// Waits for App Store Connect to finish processing that build (up to 30 minutes), then adds it to the
// group. Reads ASC_KEY (path to the .p8), ASC_KEY_ID and ASC_ISSUER from the environment.
import CryptoKit
import Foundation

let appID = "6826969452"
let internalGroup = "aaddb5b9-3f60-4c7e-bae6-7ef8ba2cb013"
let api = "https://api.appstoreconnect.apple.com/v1"

guard CommandLine.arguments.count == 2 else {
    print("usage: asc-distribute.swift <CFBundleVersion>")
    exit(2)
}
let buildNumber = CommandLine.arguments[1]
let env = ProcessInfo.processInfo.environment
guard let keyPath = env["ASC_KEY"], let keyID = env["ASC_KEY_ID"], let issuer = env["ASC_ISSUER"] else {
    print("ASC_KEY, ASC_KEY_ID and ASC_ISSUER must be set (source ~/.appstoreconnect/opendispatch.env)")
    exit(2)
}

func base64url(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

/// ES256 JWT for the App Store Connect API, good for 20 minutes.
func token() throws -> String {
    let pem = try String(contentsOfFile: keyPath, encoding: .utf8)
    let key = try P256.Signing.PrivateKey(pemRepresentation: pem)
    let now = Int(Date().timeIntervalSince1970)
    let header = try JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": keyID, "typ": "JWT"])
    let claims = try JSONSerialization.data(withJSONObject: ["iss": issuer, "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"])
    let input = base64url(header) + "." + base64url(claims)
    let signature = try key.signature(for: Data(input.utf8))
    return input + "." + base64url(signature.rawRepresentation)
}

func request(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> (Int, [String: Any]) {
    var req = URLRequest(url: URL(string: api + path)!)
    req.httpMethod = method
    req.setValue("Bearer \(try token())", forHTTPHeaderField: "Authorization")
    if let body {
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    let (data, response) = try await URLSession.shared.data(for: req)
    let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    return ((response as? HTTPURLResponse)?.statusCode ?? 0, json)
}

let query = "/builds?filter[app]=\(appID)&filter[version]=\(buildNumber)&limit=1"
let deadline = Date().addingTimeInterval(30 * 60)
var buildID: String?
while Date() < deadline {
    let (_, json) = try await request("GET", query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)
    if let build = (json["data"] as? [[String: Any]])?.first,
       let attributes = build["attributes"] as? [String: Any],
       let state = attributes["processingState"] as? String {
        print("build \(buildNumber): \(state)")
        if state == "VALID" { buildID = build["id"] as? String; break }
        if state == "FAILED" || state == "INVALID" { exit(1) }
    } else {
        print("build \(buildNumber): not in App Store Connect yet")
    }
    try await Task.sleep(for: .seconds(30))
}
guard let buildID else {
    print("build \(buildNumber) didn't finish processing in 30 minutes; add it to the group later")
    exit(1)
}

let (status, json) = try await request("POST", "/betaGroups/\(internalGroup)/relationships/builds",
                                       body: ["data": [["type": "builds", "id": buildID]]])
guard status == 204 else {
    print("adding the build to the Internal group failed (\(status)): \(json)")
    exit(1)
}
print("build \(buildNumber) is in TestFlight for the Internal group")
