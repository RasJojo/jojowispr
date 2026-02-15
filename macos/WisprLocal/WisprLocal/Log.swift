import Foundation
import os

enum Log {
    private static let subsystem: String = {
        Bundle.main.bundleIdentifier ?? "com.jojo.wisprlocal"
    }()

    static let app = Logger(subsystem: subsystem, category: "app")
    static let hotkeys = Logger(subsystem: subsystem, category: "hotkeys")
    static let permissions = Logger(subsystem: subsystem, category: "permissions")
    static let dictation = Logger(subsystem: subsystem, category: "dictation")
    static let network = Logger(subsystem: subsystem, category: "network")
    static let paste = Logger(subsystem: subsystem, category: "paste")
    static let media = Logger(subsystem: subsystem, category: "media")
}

