import Foundation

public enum QuotaPalette: String, Codable {
    case google, claude, openAI, claudeOpenAI, mixed
    public static func families(_ names: [String]) -> QuotaPalette? {
        let joined = names.joined(separator: " ").lowercased()
        let google = joined.contains("gemini") || joined.contains("google")
        let claude = joined.contains("claude")
        let openAI = joined.contains("gpt") || joined.contains("openai")
        if google && (claude || openAI) { return .mixed }
        if google { return .google }
        if claude && openAI { return .claudeOpenAI }
        if claude { return .claude }
        if openAI { return .openAI }
        return nil
    }
}
