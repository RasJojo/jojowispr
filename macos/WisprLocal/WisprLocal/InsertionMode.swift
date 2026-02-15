import Foundation

enum InsertionMode: String, CaseIterable, Identifiable {
    case type
    case paste

    var id: String { rawValue }

    var title: String {
        switch self {
        case .type:
            return "Type"
        case .paste:
            return "Paste"
        }
    }

    var help: String {
        switch self {
        case .type:
            return "Types at the cursor (no clipboard). Can be a bit slower in some apps."
        case .paste:
            return "Writes to clipboard then sends Cmd+V. Fastest, but overwrites clipboard."
        }
    }
}
