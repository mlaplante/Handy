import Foundation
import Speech
import AVFoundation

// Real Swift implementation of the Apple SpeechAnalyzer/SpeechTranscriber
// bridge (macOS 26+). This file is compiled via the Cargo build script for
// Apple Silicon targets whose toolchain supports the real API (mirrors
// apple_intelligence.swift's real/stub split).
//
// Task 1 scope: only `apple_speech_available` and
// `apple_speech_supported_locales_json` are functionally implemented.
// `apple_speech_install_locale` / `apple_speech_transcribe` are
// error-returning placeholders so every symbol declared in
// speech_analyzer_bridge.h resolves at link time; their real bodies land in
// Task 4 (transcribe) and Task 6 (install).

private typealias ResultPointer = UnsafeMutablePointer<AppleSpeechResult>

private func makeErrorResult(_ message: String) -> ResultPointer {
    let ptr = ResultPointer.allocate(capacity: 1)
    ptr.initialize(to: AppleSpeechResult(text: nil, success: 0, error_message: strdup(message)))
    return ptr
}

@_cdecl("apple_speech_available")
public func apple_speech_available() -> Int32 {
    if #available(macOS 26.0, *) { return 1 } else { return 0 }
}

@_cdecl("apple_speech_locale_installed")
public func apple_speech_locale_installed(_ lang: UnsafePointer<CChar>?) -> Int32 {
    // Real locale-installed check lands in Task 6 (AssetInventory.status).
    return 0
}

@_cdecl("apple_speech_install_locale")
public func apple_speech_install_locale(_ lang: UnsafePointer<CChar>?) -> UnsafeMutablePointer<AppleSpeechResult>? {
    // Placeholder: real AssetInventory-backed install lands in Task 6.
    return makeErrorResult("not implemented yet")
}

@_cdecl("apple_speech_transcribe")
public func apple_speech_transcribe(
    _ samples: UnsafePointer<Float>?,
    _ len: Int,
    _ lang: UnsafePointer<CChar>?
) -> UnsafeMutablePointer<AppleSpeechResult>? {
    // Placeholder: real SpeechAnalyzer/SpeechTranscriber transcribe path
    // lands in Task 4.
    return makeErrorResult("not implemented yet")
}

@_cdecl("apple_speech_supported_locales_json")
public func apple_speech_supported_locales_json() -> UnsafeMutablePointer<CChar>? {
    guard #available(macOS 26.0, *) else {
        return strdup("[]")
    }

    let semaphore = DispatchSemaphore(value: 0)

    final class ResultBox: @unchecked Sendable {
        var ids: [String] = []
    }
    let box = ResultBox()

    Task.detached(priority: .userInitiated) {
        defer { semaphore.signal() }
        let locales = await SpeechTranscriber.supportedLocales
        box.ids = locales.map { $0.identifier(.bcp47) }
    }
    semaphore.wait()

    let json = (try? JSONSerialization.data(withJSONObject: box.ids)) ?? Data("[]".utf8)
    return strdup(String(data: json, encoding: .utf8) ?? "[]")
}

@_cdecl("apple_speech_free")
public func apple_speech_free(_ result: UnsafeMutablePointer<AppleSpeechResult>?) {
    guard let result = result else { return }
    if let t = result.pointee.text { free(t) }
    if let e = result.pointee.error_message { free(e) }
    result.deallocate()
}

@_cdecl("apple_speech_free_str")
public func apple_speech_free_str(_ s: UnsafeMutablePointer<CChar>?) { if let s = s { free(s) } }
