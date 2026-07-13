import Foundation

// Stub implementation compiled when the toolchain cannot build the real
// SpeechAnalyzer bridge (e.g. Command-Line-Tools-only toolchains or SDKs
// that predate macOS 26). Mirrors apple_intelligence_stub.swift's pattern:
// every symbol declared in speech_analyzer_bridge.h must be defined here so
// the stub build links identically to the real build.

private typealias ResultPointer = UnsafeMutablePointer<AppleSpeechResult>

private func makeErrorResult(_ message: String) -> ResultPointer {
    let ptr = ResultPointer.allocate(capacity: 1)
    ptr.initialize(to: AppleSpeechResult(text: nil, success: 0, error_message: strdup(message)))
    return ptr
}

@_cdecl("apple_speech_available")
public func apple_speech_available() -> Int32 { return 0 }

@_cdecl("apple_speech_locale_installed")
public func apple_speech_locale_installed(_ lang: UnsafePointer<CChar>?) -> Int32 { return 0 }

@_cdecl("apple_speech_install_locale")
public func apple_speech_install_locale(_ lang: UnsafePointer<CChar>?) -> UnsafeMutablePointer<AppleSpeechResult>? {
    return makeErrorResult("Apple Speech is not available in this build (SDK requirement not met).")
}

@_cdecl("apple_speech_transcribe")
public func apple_speech_transcribe(
    _ samples: UnsafePointer<Float>?,
    _ len: Int,
    _ lang: UnsafePointer<CChar>?
) -> UnsafeMutablePointer<AppleSpeechResult>? {
    return makeErrorResult("Apple Speech is not available in this build (SDK requirement not met).")
}

@_cdecl("apple_speech_supported_locales_json")
public func apple_speech_supported_locales_json() -> UnsafeMutablePointer<CChar>? {
    return strdup("[]")
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
