import Foundation

enum TextPostProcessor {
    static func process(_ input: String) -> String {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)

        // Backtrack (best-effort). If the user says "scratch that" / "annule", keep only what's after the last command.
        if let r = lastMatchRange(in: text, pattern: #"(?i)\b(?:scratch\s+that|annule(?:\s+ça)?|efface(?:\s+ça)?|supprime(?:\s+ça)?)\b"#) {
            text = String(text[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        text = replace(text, pattern: #"(?i)\b(?:nouvelle\s+ligne|new\s+line|newline)\b"#, with: "\n")

        // Punctuation commands (best-effort).
        text = replace(text, pattern: #"(?i)\b(?:virgule|comma)\b"#, with: ",")
        text = replace(text, pattern: #"(?i)\b(?:point\s+d['’]interrogation|question\s+mark)\b"#, with: "?")
        text = replace(text, pattern: #"(?i)\b(?:point\s+d['’]exclamation|exclamation\s+mark)\b"#, with: "!")
        text = replace(text, pattern: #"(?i)\b(?:deux\s+points|colon)\b"#, with: ":")
        text = replace(text, pattern: #"(?i)\b(?:point[-\s]virgule|semicolon)\b"#, with: ";")
        text = replace(text, pattern: #"(?i)\b(?:point|period)\b"#, with: ".")

        // Cleanup spacing around punctuation and newlines.
        text = replace(text, pattern: #"[ \t]+\n[ \t]+"#, with: "\n")
        text = replace(text, pattern: #"[ \t]{2,}"#, with: " ")
        text = replace(text, pattern: #"\s+([,.;:!?])"#, with: "$1")
        text = replace(text, pattern: #"([,.;:!?])([^\s\n])"#, with: "$1 $2")
        text = replace(text, pattern: #" *\n *"#, with: "\n")

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replace(_ text: String, pattern: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: replacement)
    }

    private static func lastMatchRange(in text: String, pattern: String) -> Range<String.Index>? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let nsrange = NSRange(text.startIndex..., in: text)
        guard let match = regex.matches(in: text, range: nsrange).last else { return nil }
        return Range(match.range, in: text)
    }
}

