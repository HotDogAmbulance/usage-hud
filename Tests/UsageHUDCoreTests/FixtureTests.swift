import Foundation
@testable import UsageHUDCore

extension CoreTests {
    /// Answers recorded from real accounts (Tests/Fixtures/README.md) are fed back through the real readers, and what the
    /// battery shows must be what the provider's own dashboard showed. Dropping a new file in the folder adds a check.
    func testRecordedAnswersStillParse() throws {
        let here = URL(fileURLWithPath: "\(#filePath)")
        let folder = here.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures")
        let files = (FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }
        expectFalse(files.isEmpty)
        let all = worlds()
        for file in files {
            let name = file.lastPathComponent
            guard let fixture = (try? JSONSerialization.jsonObject(with: Data(contentsOf: file))) as? JSON,
                  let id = fixture["provider"] as? String, let world = all.first(where: { $0.id == id && $0.fail == nil }) else {
                fail("\(name): not a fixture for a reader that talks HTTP"); continue
            }
            try setUpWithError(); defer { try? tearDownWithError() }
            let dial = Dial(), origin = world.origins[0]
            try world.plant(self, origin)
            let provider = try world.make(self, origin, dial)
            let answers = dict(fixture["answers"]).sorted { $0.key.count > $1.key.count }
            http.error = nil
            http.handler = { url in
                guard let hit = answers.first(where: { url.path == $0.key || url.path.hasSuffix($0.key) }) else { throw HTTPFailure(status: 404) }
                let answer = dict(hit.value)
                if let status = number(answer["status"]), status != 200 { throw HTTPFailure(status: Int(status)) }
                return dict(answer["body"])
            }
            let panel = Engine(root: root, credentials: credentials, http: http, providers: [provider]).panels(refresh: "automatic").first
            let expect = dict(fixture["expect"])
            if expect["hidden"] as? Bool == true { if panel != nil { fail("\(name): should stay out of the bar") }; continue }
            guard let panel = panel else { fail("\(name): no battery"); continue }
            for (index, row) in (expect["windows"] as? [JSON] ?? []).enumerated() {
                guard index < panel.windows.count else { fail("\(name): window \(index) is missing"); continue }
                let seen = panel.windows[index]
                if let label = row["label"] as? String, seen.label != label { fail("\(name): window \(index) is \(seen.label), the dashboard says \(label)") }
                if let pct = number(row["pct"]), abs((seen.pct ?? -1000) - pct) > 0.5 { fail("\(name): \(seen.label) reads \(seen.pct ?? -1)%, the dashboard says \(pct)%") }
                if let text = row["right"] as? String, seen.right != text { fail("\(name): \(seen.label) shows '\(seen.right ?? "")', the dashboard says '\(text)'") }
            }
            if expect.keys.contains("alert"), panel.alert != expect["alert"] as? String { fail("\(name): alert is \(panel.alert ?? "none")") }
            if let note = expect["note"] as? String, panel.note != note { fail("\(name): note is '\(panel.note)'") }
            if leaks(world.secret, [panel]) { fail("\(name): the secret reached a panel") }
        }
    }
}
