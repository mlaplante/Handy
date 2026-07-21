import Foundation
import Speech
import AVFoundation

// Real Swift implementation of the Apple SpeechAnalyzer/SpeechTranscriber
// bridge (macOS 26+). This file is compiled via the Cargo build script for
// Apple Silicon targets whose toolchain supports the real API (mirrors
// apple_intelligence.swift's real/stub split).
//
// `apple_speech_transcribe` is implemented using the manual
// AnalyzerInput/AsyncStream buffer path confirmed against the SDK (see the
// plan's Task 0 "FULLY CONFIRMED" block) — SpeechAnalyzer(inputAudioFile:) is
// NOT used; it crashes with SIGTRAP.
//
// `apple_speech_locale_installed`/`apple_speech_install_locale` are backed by
// `AssetInventory.assetInstallationRequest(supporting:)` (Task 0's confirmed
// API): a `nil` request means the locale's assets are already available
// (spike finding: real machines report `.supported`, not `.installed`, once
// usable — so "request is nil" is the readiness signal, not `.installed`).

private typealias ResultPointer = UnsafeMutablePointer<AppleSpeechResult>

private func makeErrorResult(_ message: String) -> ResultPointer {
    let ptr = ResultPointer.allocate(capacity: 1)
    ptr.initialize(to: AppleSpeechResult(text: nil, success: 0, error_message: strdup(message)))
    return ptr
}

private func makeResult(text: String) -> ResultPointer {
    let ptr = ResultPointer.allocate(capacity: 1)
    ptr.initialize(to: AppleSpeechResult(text: strdup(text), success: 1, error_message: nil))
    return ptr
}

/// Resolves a requested BCP-47 identifier (Handy's `resolve_apple_locale`
/// intent, e.g. `"en"`, `"fr"`, `"zh-Hant"`) to Apple's canonical supported
/// `Locale` via `SpeechTranscriber.supportedLocale(equivalentTo:)`. This
/// replaces the hand-rolled base-subtag/script/case matching that used to
/// live in Rust — Apple owns locale equivalence now. Returns `nil` if the
/// requested identifier has no supported equivalent.
@available(macOS 26.0, *)
private func resolveSupportedLocale(_ requested: String) async -> Locale? {
    await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: requested))
}

/// Compares an already-reserved locale against the resolved, selected locale
/// using Apple's BCP-47 identifiers. Falls back to
/// `SpeechTranscriber.supportedLocale(equivalentTo:)` equivalence because
/// `AssetInventory.reservedLocales` may hand back a canonical variant that
/// doesn't literally string-match the identifier the reservation was made
/// under.
@available(macOS 26.0, *)
private func reservationMatches(_ reservedLocale: Locale, _ selectedLocale: Locale) async -> Bool {
    let selectedIdentifier = selectedLocale.identifier(.bcp47)
    if reservedLocale.identifier(.bcp47) == selectedIdentifier {
        return true
    }
    return await SpeechTranscriber.supportedLocale(equivalentTo: reservedLocale)?
        .identifier(.bcp47) == selectedIdentifier
}

/// macOS caps how many locales an app can hold reserved at once
/// (`AssetInventory.maximumReservedLocales`). Cycling through many languages
/// over the app's lifetime can hit that cap, which makes
/// `AssetInventory.assetInstallationRequest(supporting:)` throw. If the
/// locale we're about to install isn't already reserved and the cap is
/// reached, release other (non-selected) reservations until there's room.
/// Spare reservations that aren't in the way are left alone to avoid
/// needless re-download churn later.
@available(macOS 26.0, *)
private func makeRoomForReservation(of locale: Locale) async {
    let selectedIdentifier = locale.identifier(.bcp47)
    let reservedLocales = await AssetInventory.reservedLocales

    var selectedIsReserved = false
    for reservedLocale in reservedLocales {
        if await reservationMatches(reservedLocale, locale) {
            selectedIsReserved = true
            break
        }
    }

    guard !selectedIsReserved, reservedLocales.count >= AssetInventory.maximumReservedLocales else {
        return
    }

    var reservationCount = reservedLocales.count
    for reservedLocale in reservedLocales where reservedLocale.identifier(.bcp47) != selectedIdentifier {
        guard reservationCount >= AssetInventory.maximumReservedLocales else { break }
        if await AssetInventory.release(reservedLocale: reservedLocale) {
            reservationCount -= 1
        }
    }
}

/// Handy's internal audio buffer is 16 kHz mono Float32 (see
/// `src-tauri/src/audio_toolkit/constants.rs::WHISPER_SAMPLE_RATE` and the
/// mono downmix in `audio_toolkit/audio/recorder.rs`). This builds the
/// source `AVAudioPCMBuffer` at that format from the raw sample array.
@available(macOS 26.0, *)
private func makeSourceBuffer(from samples: [Float]) -> AVAudioPCMBuffer? {
    guard
        let sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ),
        let buffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: AVAudioFrameCount(samples.count)
        )
    else { return nil }

    buffer.frameLength = AVAudioFrameCount(samples.count)
    guard let channelData = buffer.floatChannelData else { return nil }
    if !samples.isEmpty {
        samples.withUnsafeBufferPointer { src in
            if let base = src.baseAddress {
                channelData[0].update(from: base, count: samples.count)
            }
        }
    }
    return buffer
}

/// Converts `sourceBuffer` (16 kHz mono Float32) to `targetFormat` (confirmed
/// by Task 0 to be 16 kHz mono Int16 interleaved — the SpeechAnalyzer-required
/// format). Sample rate matches so this is a format-only conversion, but a
/// conversion is still required since Float32 != Int16.
@available(macOS 26.0, *)
private func convert(
    _ sourceBuffer: AVAudioPCMBuffer,
    to targetFormat: AVAudioFormat
) throws -> AVAudioPCMBuffer {
    guard let converter = AVAudioConverter(from: sourceBuffer.format, to: targetFormat) else {
        throw NSError(
            domain: "AppleSpeech", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Failed to create AVAudioConverter"])
    }
    // Output frame count: same duration, target sample rate (rates match here,
    // but compute from ratio to stay correct if that ever changes).
    let ratio = targetFormat.sampleRate / sourceBuffer.format.sampleRate
    let outCapacity = AVAudioFrameCount(Double(sourceBuffer.frameLength) * ratio) + 1
    guard
        let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat, frameCapacity: outCapacity)
    else {
        throw NSError(
            domain: "AppleSpeech", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Failed to allocate converted buffer"])
    }

    var hasSuppliedInput = false
    var conversionError: NSError?
    let status = converter.convert(to: outputBuffer, error: &conversionError) {
        _, outStatus in
        if hasSuppliedInput {
            outStatus.pointee = .endOfStream
            return nil
        }
        hasSuppliedInput = true
        outStatus.pointee = .haveData
        return sourceBuffer
    }

    if status == .error {
        throw conversionError
            ?? NSError(
                domain: "AppleSpeech", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "AVAudioConverter conversion failed"])
    }
    return outputBuffer
}

/// Runs the confirmed analyze → finalize → drain-results path (Task 0) and
/// returns the concatenated final transcript text. Serial ordering with no
/// concurrent drain task is sufficient (proven by the Task 0 spike).
@available(macOS 26.0, *)
private func runAndCollect(
    analyzer: SpeechAnalyzer,
    transcriber: SpeechTranscriber,
    buffer: AVAudioPCMBuffer
) async throws -> String {
    let stream = AsyncStream<AnalyzerInput> { continuation in
        continuation.yield(AnalyzerInput(buffer: buffer))
        continuation.finish()
    }
    try await analyzer.start(inputSequence: stream)
    try await analyzer.finalizeAndFinishThroughEndOfInput()

    var text = ""
    for try await result in transcriber.results where result.isFinal {
        text += String(result.text.characters)
    }
    return text
}

@_cdecl("apple_speech_available")
public func apple_speech_available() -> Int32 {
    if #available(macOS 26.0, *) {
        return SpeechTranscriber.isAvailable ? 1 : 0
    }
    return 0
}

@_cdecl("apple_speech_locale_installed")
public func apple_speech_locale_installed(_ lang: UnsafePointer<CChar>?) -> Int32 {
    guard #available(macOS 26.0, *) else { return 0 }
    guard let lang = lang else { return 0 }
    let localeIdentifier = String(cString: lang)

    let semaphore = DispatchSemaphore(value: 0)

    final class ResultBox: @unchecked Sendable {
        var installed = false
    }
    let box = ResultBox()

    Task.detached(priority: .userInitiated) {
        defer { semaphore.signal() }
        do {
            // Resolve to Apple's canonical supported locale first; an
            // unsupported requested locale is never "installed".
            guard let locale = await resolveSupportedLocale(localeIdentifier) else {
                box.installed = false
                return
            }
            let transcriber = SpeechTranscriber(
                locale: locale,
                transcriptionOptions: [],
                reportingOptions: [],
                attributeOptions: []
            )
            // nil ⇒ nothing to install ⇒ the locale is already usable (Task 0
            // spike finding: don't require AssetInventory.status == .installed).
            let request = try await AssetInventory.assetInstallationRequest(
                supporting: [transcriber])
            box.installed = (request == nil)
        } catch {
            box.installed = false
        }
    }
    // Fast metadata query, but still bounded: if it stalls, treat "couldn't
    // determine" as "not installed" (0) so the caller falls through to the
    // install path rather than blocking the model-load future forever. Do
    // NOT read `box` on timeout — the detached Task may still be writing to
    // it; the abandoned Task finishes harmlessly in the background.
    if semaphore.wait(timeout: .now() + 30) == .timedOut {
        return 0
    }

    return box.installed ? 1 : 0
}

@_cdecl("apple_speech_install_locale")
public func apple_speech_install_locale(_ lang: UnsafePointer<CChar>?) -> UnsafeMutablePointer<AppleSpeechResult>? {
    guard #available(macOS 26.0, *) else {
        return makeErrorResult("Apple Speech requires macOS 26 or newer.")
    }
    guard let lang = lang else {
        return makeErrorResult("Apple Speech locale install received null arguments.")
    }
    let localeIdentifier = String(cString: lang)

    let semaphore = DispatchSemaphore(value: 0)

    final class ResultBox: @unchecked Sendable {
        var error: String?
    }
    let box = ResultBox()

    Task.detached(priority: .userInitiated) {
        defer { semaphore.signal() }
        do {
            guard let locale = await resolveSupportedLocale(localeIdentifier) else {
                box.error = "Locale '\(localeIdentifier)' is not supported by Apple Speech"
                return
            }
            let transcriber = SpeechTranscriber(
                locale: locale,
                transcriptionOptions: [],
                reportingOptions: [],
                attributeOptions: []
            )
            // Ensure a reservation slot is available before asking the OS to
            // reserve/install this locale's assets (see makeRoomForReservation).
            await makeRoomForReservation(of: locale)
            if let request = try await AssetInventory.assetInstallationRequest(
                supporting: [transcriber])
            {
                // Best-effort: a simple blocking install with no per-percent
                // progress callback (per-plan, progress plumbing is optional
                // and not worth the C function-pointer complexity here).
                try await request.downloadAndInstall()
            }
        } catch {
            box.error = "Apple Speech asset install failed: \(error)"
        }
    }
    // Generous bound for a real download. On timeout, do NOT read `box` —
    // the detached Task may still be mutating it — just return a fresh
    // error result and let the abandoned Task finish (or keep running)
    // harmlessly in the background. This guarantees `load_model` always
    // resolves instead of hanging forever and wedging the load-in-progress
    // guard (see commands/models.rs try_start_loading).
    if semaphore.wait(timeout: .now() + 300) == .timedOut {
        return makeErrorResult("Apple Speech asset install timed out")
    }

    if let error = box.error {
        return makeErrorResult(error)
    }
    return makeResult(text: "")
}

@_cdecl("apple_speech_transcribe")
public func apple_speech_transcribe(
    _ samples: UnsafePointer<Float>?,
    _ len: Int,
    _ lang: UnsafePointer<CChar>?
) -> UnsafeMutablePointer<AppleSpeechResult>? {
    guard #available(macOS 26.0, *) else {
        return makeErrorResult("Apple Speech requires macOS 26 or newer.")
    }
    guard let samples = samples, let lang = lang else {
        return makeErrorResult("Apple Speech transcription received null arguments.")
    }
    if len == 0 {
        return makeResult(text: "")
    }

    let localeIdentifier = String(cString: lang)
    let input = Array(UnsafeBufferPointer(start: samples, count: len))

    // Bridge async->sync: apple_speech_transcribe is called from Handy's own
    // worker thread (not the Swift cooperative pool), so it is safe to block
    // this thread on a semaphore signaled from a detached task (Task 0
    // gotcha: never do this from a cooperative-pool thread).
    let semaphore = DispatchSemaphore(value: 0)

    final class ResultBox: @unchecked Sendable {
        var text: String?
        var error: String?
    }
    let box = ResultBox()

    Task.detached(priority: .userInitiated) {
        defer { semaphore.signal() }
        do {
            guard let locale = await resolveSupportedLocale(localeIdentifier) else {
                box.error = "Locale '\(localeIdentifier)' is not supported by Apple Speech"
                return
            }
            let transcriber = SpeechTranscriber(
                locale: locale,
                transcriptionOptions: [],
                reportingOptions: [],
                attributeOptions: []
            )
            let modules: [any SpeechModule] = [transcriber]

            guard
                let targetFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
                    compatibleWith: modules)
            else {
                box.error =
                    "Apple Speech could not determine a compatible audio format for locale '\(localeIdentifier)'."
                return
            }

            guard let sourceBuffer = makeSourceBuffer(from: input) else {
                box.error = "Apple Speech failed to build the source audio buffer."
                return
            }

            let convertedBuffer = try convert(sourceBuffer, to: targetFormat)

            let analyzer = SpeechAnalyzer(modules: modules)
            box.text = try await runAndCollect(
                analyzer: analyzer, transcriber: transcriber, buffer: convertedBuffer)
        } catch {
            box.error = "Apple Speech transcription failed: \(error)"
        }
    }
    semaphore.wait()

    if let text = box.text {
        return makeResult(text: text)
    }
    return makeErrorResult(box.error ?? "Apple Speech transcription failed: unknown error")
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
