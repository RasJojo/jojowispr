import Dispatch
import Foundation
import Darwin

@MainActor
final class MediaRemoteController {
    static let shared = MediaRemoteController()

    // Private API: MediaRemote.framework (not App Store safe).
    private let handle: UnsafeMutableRawPointer?

    private typealias IsPlayingCallback = @convention(block) (UInt8) -> Void
    private typealias GetIsPlayingFn = @convention(c) (DispatchQueue, @escaping IsPlayingCallback) -> Void
    private typealias SendCommandFn = @convention(c) (Int, CFDictionary?) -> Void

    private let getIsPlayingFn: GetIsPlayingFn?
    private let sendCommandFn: SendCommandFn?

    private init() {
        handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY)
        if let handle {
            let isPlayingPtr = dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying")
            let sendPtr = dlsym(handle, "MRMediaRemoteSendCommand")
            if let isPlayingPtr {
                getIsPlayingFn = unsafeBitCast(isPlayingPtr, to: GetIsPlayingFn.self)
            } else {
                getIsPlayingFn = nil
            }
            if let sendPtr {
                sendCommandFn = unsafeBitCast(sendPtr, to: SendCommandFn.self)
            } else {
                sendCommandFn = nil
            }
        } else {
            getIsPlayingFn = nil
            sendCommandFn = nil
        }
    }

    func pauseIfPlaying() async -> Bool {
        guard await isPlaying() else { return false }
        togglePlayPause()
        return true
    }

    func resumeIfPaused() async {
        guard !(await isPlaying()) else { return }
        togglePlayPause()
    }

    private func isPlaying() async -> Bool {
        guard let getIsPlayingFn else { return false }
        return await withCheckedContinuation { cont in
            getIsPlayingFn(.main) { value in
                cont.resume(returning: value != 0)
            }
        }
    }

    private func togglePlayPause() {
        // Empirically stable across macOS versions: 2 = toggle play/pause.
        sendCommandFn?(2, nil)
    }
}
