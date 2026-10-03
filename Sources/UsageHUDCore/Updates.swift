import Foundation

/// Release checks against a GitHub repository's latest release. Tags like `v2.2` or `2.2.1` compare numerically.
public enum Updates {
    public static func isNewer(_ tag: String, than current: String) -> Bool {
        func parts(_ text: String) -> [Int] {
            text.trimmingCharacters(in: CharacterSet(charactersIn: "vV ")).split(separator: ".").map { part in Int(part.prefix { $0.isNumber }) ?? 0 }
        }
        let new = parts(tag), old = parts(current)
        for index in 0..<max(new.count, old.count) {
            let a = index < new.count ? new[index] : 0, b = index < old.count ? old[index] : 0
            if a != b { return a > b }
        }
        return false
    }
    /// The release tag and page from GitHub's `releases/latest` response, when it is newer than `current`.
    public static func newer(_ response: [String: Any], than current: String) -> (tag: String, page: URL)? {
        guard let tag = response["tag_name"] as? String, isNewer(tag, than: current),
              let page = (response["html_url"] as? String).flatMap(URL.init(string:)) else { return nil }
        return (tag, page)
    }
}
