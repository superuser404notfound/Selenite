import Foundation
import Testing

/// The app's string catalogs live in the app target, which `swift test` does not build, so they
/// are read straight from the repository.
private let repository = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// The languages Selenite ships, the same set as Sodalite.
private let languages: Set<String> = [
    "cs", "da", "de", "el", "en", "es", "fi", "fr", "hr", "hu", "it", "ja", "ko", "nb", "nl", "pl",
    "pt-BR", "pt-PT", "ro", "ru", "sk", "sv", "tr", "uk", "zh-Hans", "zh-Hant",
]

private func catalog(_ name: String) throws -> [String: [String: Any]] {
    let data = try Data(contentsOf: repository.appendingPathComponent("Selenite/\(name).xcstrings"))
    let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    return try #require(root["strings"] as? [String: [String: Any]])
}

/// The format specifiers of a string, with positions dropped: "%2$lld" counts as "%lld".
private func specifiers(_ text: String) -> [String] {
    let regex = try! NSRegularExpression(pattern: #"%(?:\d+\$)?(lld|@|%)"#)
    let range = NSRange(text.startIndex..., in: text)
    return regex.matches(in: text, range: range).map { (text as NSString).substring(with: $0.range(at: 1)) }.sorted()
}

/// Every translated value of one localization: its string unit, or each plural form.
private func values(_ localization: [String: Any]) -> [(state: String?, value: String)] {
    if let unit = localization["stringUnit"] as? [String: String] {
        return [(unit["state"], unit["value"] ?? "")]
    }
    let plural = (localization["variations"] as? [String: Any])?["plural"] as? [String: [String: Any]] ?? [:]
    return plural.values.compactMap { $0["stringUnit"] as? [String: String] }.map { ($0["state"], $0["value"] ?? "") }
}

@Test func everyStringIsTranslatedIntoEveryLanguageWithItsPlaceholders() throws {
    for (key, entry) in try catalog("Localizable") {
        let localizations = entry["localizations"] as? [String: [String: Any]] ?? [:]
        let missing = languages.subtracting(localizations.keys).subtracting(["en"])
        #expect(missing.isEmpty, "\(key): missing \(missing.sorted())")
        for (language, localization) in localizations {
            let found = values(localization)
            #expect(!found.isEmpty, "\(key) [\(language)]: no value")
            for (state, value) in found {
                #expect(state == "translated", "\(key) [\(language)]: state \(state ?? "nil")")
                #expect(!value.isEmpty, "\(key) [\(language)]: empty")
                #expect(specifiers(value) == specifiers(key), "\(key) [\(language)]: \(value)")
            }
        }
    }
}

@Test func theInfoPlistStringsAreTranslatedIntoEveryLanguage() throws {
    for (key, entry) in try catalog("InfoPlist") {
        let localizations = entry["localizations"] as? [String: [String: Any]] ?? [:]
        #expect(Set(localizations.keys) == languages, "\(key)")
        for (language, localization) in localizations {
            #expect(values(localization).allSatisfy { !$0.value.isEmpty }, "\(key) [\(language)]")
        }
    }
}
