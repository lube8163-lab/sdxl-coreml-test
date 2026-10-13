import Foundation

public enum ContentSafetyContext: String, Sendable { case publicText, generationPrompt }

public enum ContentSafetyError: Error, LocalizedError, Equatable {
    case blocked, unavailable, tooLong
    public var errorDescription: String? {
        switch self {
        case .blocked: "この内容からは画像を生成できません。内容を変えてお試しください。"
        case .unavailable: "入力の安全性を確認できないため、生成を停止しました。"
        case .tooLong: "プロンプトが長すぎます。短くしてお試しください。"
        }
    }
}

/// Local rules catch explicit patterns; they are not a semantic classifier or a guarantee
/// that all harmful content is detected. Adapted from MiM; generated images must also pass ImageSafetyChecker.
public struct ContentSafetyPolicy: Codable, Sendable {
    struct Rule: Codable, Sendable {
        let id: String
        let category: String
        let contexts: [String]
        let groups: [[String]]
        let maxSpan: Int
    }
    let version: Int
    let revision: String
    let supportedLanguages: [String]
    let maxUTF16Length: Int
    let benignPhrases: [String]
    let rules: [Rule]

    private static let loaded: Result<Self, Error> = Result {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let url = bundle.url(forResource: "ContentSafetyPolicy", withExtension: "json") else {
            throw ContentSafetyError.unavailable
        }
        do { return try decode(Data(contentsOf: url)) }
        catch { throw ContentSafetyError.unavailable }
    }

    public static func bundled() throws -> Self { try loaded.get() }

    public static func decode(_ data: Data) throws -> Self {
        let policy = try JSONDecoder().decode(Self.self, from: data)
        guard policy.version == 1, policy.revision == "local-generation-20261013-v1",
              policy.maxUTF16Length == 4000, !policy.rules.isEmpty,
              Set(policy.rules.map(\.id)).count == policy.rules.count else {
            throw ContentSafetyError.unavailable
        }
        for rule in policy.rules {
            guard !rule.groups.isEmpty, rule.groups.allSatisfy({ !$0.isEmpty }),
                  (1...4000).contains(rule.maxSpan), !rule.contexts.isEmpty,
                  rule.contexts.allSatisfy({ ContentSafetyContext(rawValue: $0) != nil }) else {
                throw ContentSafetyError.unavailable
            }
            for pattern in rule.groups.flatMap({ $0 }) {
                guard !pattern.isEmpty else { throw ContentSafetyError.unavailable }
                _ = try NSRegularExpression(pattern: pattern)
            }
        }
        return policy
    }

    public static func normalize(_ input: String) -> String {
        let folded = input.precomposedStringWithCompatibilityMapping.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX")).lowercased(with: Locale(identifier: "en_US_POSIX"))
        let withoutControls = folded.unicodeScalars.filter { $0.properties.generalCategory != .format }
        let lookalikes: [Character: Character] = ["а":"a", "е":"e", "о":"o", "р":"p", "с":"c", "х":"x", "у":"y", "і":"i"]
        return String(String.UnicodeScalarView(withoutControls)).map { String(lookalikes[$0] ?? $0) }.joined()
    }

    public func validate(_ text: String?, context: ContentSafetyContext = .publicText) throws {
        guard let text else { return }
        guard text.utf16.count <= maxUTF16Length else { throw ContentSafetyError.tooLong }
        var normalized = Self.normalize(text)
        // Remove only these exact, benign expressions, never the remainder of a message.
        for phrase in benignPhrases {
            normalized = normalized.replacingOccurrences(of: Self.normalize(phrase), with: " ")
        }
        let fullRange = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
        for rule in rules where rule.contexts.contains(context.rawValue) {
            let matches: [[NSRange]] = try rule.groups.map { group in
                try group.flatMap { pattern in
                    try NSRegularExpression(pattern: pattern).matches(in: normalized, range: fullRange).map(\.range)
                }
            }
            guard matches.allSatisfy({ !$0.isEmpty }) else { continue }
            let starts = matches.flatMap { $0.map(\.location) }
            if starts.contains(where: { start in
                matches.allSatisfy { group in group.contains { $0.location >= start && NSMaxRange($0) <= start + rule.maxSpan } }
            }) { throw ContentSafetyError.blocked }
        }
    }

    public func permits(_ text: String?, context: ContentSafetyContext = .publicText) -> Bool {
        (try? validate(text, context: context)) != nil
    }

    public static func displayText(_ text: String?, fallback: String = "") -> String {
        guard let policy = try? bundled(), policy.permits(text) else { return fallback }
        return text ?? fallback
    }
}
