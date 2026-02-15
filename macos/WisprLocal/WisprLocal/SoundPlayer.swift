import AppKit

final class SoundPlayer {
    enum Sound {
        case start
        case stop
    }

    func play(_ sound: Sound) {
        let name: NSSound.Name = switch sound {
        case .start: "Pop"
        case .stop: "Tink"
        }
        NSSound(named: name)?.play()
    }
}

