import AppKit
import Accelerate
import AVFoundation
import CoreGraphics
import CoreMedia
import ScreenCaptureKit
import Sparkle
import SwiftUI

struct AudioSource: Identifiable, Hashable {
    static let all = AudioSource(
        id: "all-system-audio",
        name: "All system audio",
        processID: nil
    )

    let id: String
    let name: String
    let processID: pid_t?
}

struct RecordedFile: Identifiable {
    let url: URL
    let transcriptURL: URL?
    let modifiedAt: Date
    let byteCount: Int

    var id: URL { url }
}

func sidecarTranscriptURL(for audioURL: URL) -> URL {
    audioURL.deletingPathExtension().appendingPathExtension("txt")
}

private let transcribableAudioExtensions: Set<String> = [
    "m4a", "mp4", "mp3", "wav", "aiff", "aif", "flac"
]

enum RecorderError: LocalizedError {
    case microphoneDenied
    case systemAudioDenied
    case noDisplay
    case appNoLongerRunning(String)
    case noAudioTrack
    case unexpectedAudioTrackCount(Int)
    case cannotCombineSegments(String)
    case emptyExport
    case recordingStartTimedOut
    case recordingFinalizationTimedOut
    case captureStoppedUnexpectedly

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            return "Microphone access is required. Enable it in System Settings → Privacy & Security → Microphone."
        case .systemAudioDenied:
            return "System Audio Recording access is required. Allow it, then quit and reopen Record."
        case .noDisplay:
            return "No display is available for system-audio capture."
        case .appNoLongerRunning(let name):
            return "\(name) is no longer running. Refresh the app list and try again."
        case .noAudioTrack:
            return "The recording contains no audio track."
        case .unexpectedAudioTrackCount(let count):
            return "The recording contains \(count) audio tracks instead of one mixed track."
        case .cannotCombineSegments(let reason):
            return "macOS could not finish the audio file (\(reason))."
        case .emptyExport:
            return "macOS created an empty audio file."
        case .recordingStartTimedOut:
            return "macOS did not start the recording in time."
        case .recordingFinalizationTimedOut:
            return "macOS did not finish closing the recording in time. The recovery file was kept."
        case .captureStoppedUnexpectedly:
            return "macOS stopped the audio capture unexpectedly."
        }
    }
}

enum AudioExporter {
    static func export(
        from inputURL: URL,
        excluding pausedRanges: [CMTimeRange] = [],
        to outputURL: URL
    ) async throws {
        let asset = AVURLAsset(url: inputURL)
        let track = try await audioTrack(in: asset)
        let trackTimeRange = try await track.load(.timeRange)
        let audioFormat = try await audioFormat(of: track)
        let composition = AVMutableComposition()
        guard let outputTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw RecorderError.cannotCombineSegments("could not create the audio track")
        }

        do {
            var outputCursor = CMTime.zero
            for includedRange in includedRanges(
                duration: trackTimeRange.duration,
                excluding: pausedRanges
            ) {
                let sourceRange = CMTimeRange(
                    start: CMTimeAdd(trackTimeRange.start, includedRange.start),
                    duration: includedRange.duration
                )
                try outputTrack.insertTimeRange(sourceRange, of: track, at: outputCursor)
                outputCursor = CMTimeAdd(outputCursor, sourceRange.duration)
            }
            guard CMTimeCompare(outputCursor, .zero) > 0 else {
                throw RecorderError.noAudioTrack
            }
            try await writeM4A(
                composition,
                track: outputTrack,
                sampleRate: audioFormat.sampleRate,
                channelCount: audioFormat.channelCount,
                to: outputURL
            )
            try await validateFile(at: outputURL)
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }

    private static func includedRanges(
        duration: CMTime,
        excluding pausedRanges: [CMTimeRange]
    ) -> [CMTimeRange] {
        guard duration.isNumeric, duration.seconds > 0 else { return [] }
        let total = duration.seconds
        let pauses = pausedRanges.compactMap { range -> Range<Double>? in
            guard range.start.isNumeric, range.end.isNumeric else { return nil }
            let start = max(0, range.start.seconds)
            let end = min(total, range.end.seconds)
            return start < end ? start..<end : nil
        }.sorted { $0.lowerBound < $1.lowerBound }

        var cursor = 0.0
        var included: [Range<Double>] = []
        for pause in pauses {
            if pause.lowerBound > cursor {
                included.append(cursor..<pause.lowerBound)
            }
            cursor = max(cursor, pause.upperBound)
        }
        if cursor < total {
            included.append(cursor..<total)
        }
        return included.map { range in
            CMTimeRange(
                start: CMTime(seconds: range.lowerBound, preferredTimescale: 48_000),
                end: CMTime(seconds: range.upperBound, preferredTimescale: 48_000)
            )
        }
    }

    private static func audioFormat(
        of track: AVAssetTrack
    ) async throws -> (sampleRate: Double, channelCount: Int) {
        let descriptions = try await track.load(.formatDescriptions)
        guard let description = descriptions.first,
              let stream = CMAudioFormatDescriptionGetStreamBasicDescription(description) else {
            throw RecorderError.cannotCombineSegments("could not read the audio format")
        }
        let format = stream.pointee
        guard format.mSampleRate > 0, format.mChannelsPerFrame > 0 else {
            throw RecorderError.cannotCombineSegments("the audio format is invalid")
        }
        return (format.mSampleRate, Int(format.mChannelsPerFrame))
    }

    private static func writeM4A(
        _ asset: AVAsset,
        track: AVAssetTrack,
        sampleRate: Double,
        channelCount: Int,
        to outputURL: URL
    ) async throws {
        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: Int(kAudioFormatLinearPCM),
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channelCount,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
        )
        readerOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(readerOutput) else {
            throw RecorderError.cannotCombineSegments("could not decode the audio")
        }
        reader.add(readerOutput)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
        let outputSettings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVEncoderBitRateKey: channelCount == 1 ? 96_000 : 128_000
        ]
        guard writer.canApply(outputSettings: outputSettings, forMediaType: .audio) else {
            throw RecorderError.cannotCombineSegments("the audio encoder is unavailable")
        }
        let writerInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: outputSettings
        )
        guard writer.canAdd(writerInput) else {
            throw RecorderError.cannotCombineSegments("could not encode the audio")
        }
        writer.add(writerInput)

        guard writer.startWriting() else {
            throw RecorderError.cannotCombineSegments(
                writer.error?.localizedDescription ?? "could not start the audio encoder"
            )
        }
        writer.startSession(atSourceTime: .zero)
        guard reader.startReading() else {
            writer.cancelWriting()
            throw RecorderError.cannotCombineSegments(
                reader.error?.localizedDescription ?? "could not start reading the recording"
            )
        }

        do {
            while let sampleBuffer = readerOutput.copyNextSampleBuffer() {
                while !writerInput.isReadyForMoreMediaData {
                    guard writer.status == .writing else {
                        throw RecorderError.cannotCombineSegments(
                            writer.error?.localizedDescription ?? "could not write the audio"
                        )
                    }
                    try await Task.sleep(nanoseconds: 2_000_000)
                }
                guard writerInput.append(sampleBuffer) else {
                    throw RecorderError.cannotCombineSegments(
                        writer.error?.localizedDescription ?? "could not write the audio"
                    )
                }
            }
            guard reader.status == .completed else {
                throw RecorderError.cannotCombineSegments(
                    reader.error?.localizedDescription ?? "could not read the recording"
                )
            }
        } catch {
            reader.cancelReading()
            writer.cancelWriting()
            throw error
        }

        writerInput.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else {
            throw RecorderError.cannotCombineSegments(
                writer.error?.localizedDescription ?? "could not finish the audio file"
            )
        }
    }

    private static func validateFile(at outputURL: URL) async throws {
        let size = try outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0 else { throw RecorderError.emptyExport }

        let asset = AVURLAsset(url: outputURL)
        let track = try await audioTrack(in: asset)
        let timeRange = try await track.load(.timeRange)
        guard timeRange.duration.isNumeric,
              CMTimeCompare(timeRange.duration, .zero) > 0 else {
            throw RecorderError.emptyExport
        }
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard videoTracks.isEmpty else {
            throw RecorderError.cannotCombineSegments("the final file contains video")
        }
    }

    private static func audioTrack(in asset: AVAsset) async throws -> AVAssetTrack {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw RecorderError.noAudioTrack }
        guard tracks.count == 1 else {
            throw RecorderError.unexpectedAudioTrackCount(tracks.count)
        }
        return tracks[0]
    }
}

enum MeterSource {
    case meetingAudio
    case microphone
}

struct AudioMeasurement: Sendable {
    let rms: Float
}

enum AudioLevelAnalyzer {
    static func measure(_ buffer: AVAudioPCMBuffer) -> AudioMeasurement? {
        guard buffer.frameLength > 0,
              let channelData = buffer.floatChannelData else { return nil }

        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard channelCount > 0 else { return nil }

        var squareSum: Float = 0
        for channel in 0..<channelCount {
            let samples = UnsafeBufferPointer(
                start: channelData[channel],
                count: frameCount
            )
            squareSum += vDSP.sumOfSquares(samples)
        }

        return AudioMeasurement(
            rms: unit(sqrt(squareSum / Float(frameCount * channelCount)))
        )
    }

    static func visualLevel(_ linearLevel: Float) -> Float {
        guard linearLevel.isFinite, linearLevel > 0 else { return 0 }
        let decibels = 20 * log10(min(linearLevel, 1))
        return min(max((decibels + 60) / 60, 0), 1)
    }

    private static func unit(_ value: Float) -> Float {
        value.isFinite ? min(max(value, 0), 1) : 0
    }
}

final class AudioLevelMeter {
    private var inputFormat: AVAudioFormat?
    private var converter: AVAudioConverter?

    func measure(_ sampleBuffer: CMSampleBuffer) -> AudioMeasurement? {
        guard sampleBuffer.isValid,
              sampleBuffer.numSamples > 0,
              let description = sampleBuffer.formatDescription else { return nil }

        let format = AVAudioFormat(cmAudioFormatDescription: description)
        guard format.streamDescription.pointee.mFormatID == kAudioFormatLinearPCM else {
            return nil
        }

        if inputFormat?.isEqual(format) != true {
            guard let outputFormat = AVAudioFormat(
                standardFormatWithSampleRate: format.sampleRate,
                channels: format.channelCount
            ), let newConverter = AVAudioConverter(from: format, to: outputFormat) else {
                return nil
            }
            inputFormat = format
            converter = newConverter
        }
        guard let converter else { return nil }

        return try? sampleBuffer.withAudioBufferList(
            flags: [.audioBufferListAssure16ByteAlignment]
        ) { buffers, _ in
            guard let input = AVAudioPCMBuffer(
                pcmFormat: format,
                bufferListNoCopy: buffers.unsafePointer,
                deallocator: nil
            ), let output = AVAudioPCMBuffer(
                pcmFormat: converter.outputFormat,
                frameCapacity: input.frameLength
            ) else { return nil }

            try converter.convert(to: output, from: input)
            return AudioLevelAnalyzer.measure(output)
        }
    }
}

final class RecordingSession: NSObject, SCRecordingOutputDelegate, SCStreamDelegate, SCStreamOutput {
    let stagingURL: URL
    let finalURL: URL
    private(set) var isMeteringAvailable = false

    private var stream: SCStream!
    private var recordingOutput: SCRecordingOutput?
    private var pauseStartedAt: CMTime?
    private var pausedRanges: [CMTimeRange] = []
    private let meterQueue = DispatchQueue(label: "MeetingAudio.level-meter")
    private let systemMeter = AudioLevelMeter()
    private let microphoneMeter = AudioLevelMeter()
    private let minimumMeterInterval = 1.0 / 15.0
    private var lastSystemMeterTime = 0.0
    private var lastMicrophoneMeterTime = 0.0
    private var meterOutputsAttached = false
    private let completionLock = NSLock()
    private var startResult: Result<Void, Error>?
    private var startWaiter: CheckedContinuation<Void, Error>?
    private var completionResult: Result<Void, Error>?
    private var completionWaiter: CheckedContinuation<Void, Error>?
    private var streamStopped = false
    private var recordingOutputIsAttached = true
    private let failureHandler: (Error) -> Void
    private let levelHandler: (MeterSource, Float) -> Void

    init(
        filter: SCContentFilter,
        stagingURL: URL,
        finalURL: URL,
        failureHandler: @escaping (Error) -> Void,
        levelHandler: @escaping (MeterSource, Float) -> Void
    ) throws {
        self.stagingURL = stagingURL
        self.finalURL = finalURL
        self.failureHandler = failureHandler
        self.levelHandler = levelHandler

        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.captureMicrophone = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 1

        // SCRecordingOutput currently requires video, so make it negligible.
        configuration.width = 64
        configuration.height = 64
        configuration.minimumFrameInterval = CMTime(seconds: 1, preferredTimescale: 600)
        configuration.queueDepth = 1
        configuration.showsCursor = false

        super.init()
        stream = SCStream(filter: filter, configuration: configuration, delegate: self)

        let output = makeRecordingOutput(for: stagingURL)
        recordingOutput = output
        try stream.addRecordingOutput(output)
        attachMeterOutputs()
    }

    func start() async throws {
        var captureStarted = false
        do {
            try await stream.startCapture()
            captureStarted = true
            try await waitForRecordingToStart()
            guard !captureIsStopped else {
                throw RecorderError.captureStoppedUnexpectedly
            }
        } catch {
            if captureStarted {
                do {
                    try await stopStream()
                    detachMeterOutputs()
                    try await finalizeCurrentOutput()
                } catch {
                    // The controller keeps this session when stopping or closing is unconfirmed.
                }
            } else {
                markStreamStopped()
                recordingOutput = nil
                recordingOutputIsAttached = false
                detachMeterOutputs()
            }
            throw error
        }
    }

    func stopAndExport() async throws -> URL {
        try await stopStream()
        detachMeterOutputs()
        try await finalizeCurrentOutput()
        return try await exportRecording()
    }

    func recoverAfterFailure() async -> URL? {
        do {
            try await stopStream()
        } catch {
            return nil
        }
        detachMeterOutputs()
        do {
            try await finalizeCurrentOutput()
        } catch {
            return nil
        }
        return try? await exportRecording()
    }

    func pause() -> Bool {
        guard pauseStartedAt == nil,
              let duration = currentRecordingDuration() else { return false }
        pauseStartedAt = duration
        return true
    }

    func resume() -> Bool {
        guard let duration = currentRecordingDuration() else { return false }
        return closePause(at: duration)
    }

    var captureIsStopped: Bool {
        completionLock.lock()
        let stopped = streamStopped
        completionLock.unlock()
        return stopped
    }

    var canSafelyRelease: Bool {
        guard captureIsStopped else { return false }
        return recordingOutput == nil || recordingHasFinished()
    }

    private func stopStream() async throws {
        guard !captureIsStopped else {
            recordingOutputIsAttached = false
            return
        }

        var lastError: Error?
        for attempt in 0..<2 {
            do {
                try await stream.stopCapture()
                markStreamStopped()
                recordingOutputIsAttached = false
                return
            } catch {
                lastError = error
                if captureIsStopped {
                    recordingOutputIsAttached = false
                    return
                }

                if attempt == 0,
                   recordingOutputIsAttached,
                   let output = recordingOutput {
                    do {
                        try stream.removeRecordingOutput(output)
                        recordingOutputIsAttached = false
                    } catch {
                        // A second stop attempt can still succeed with the output attached.
                    }
                }
            }
        }

        if captureIsStopped {
            recordingOutputIsAttached = false
            return
        }
        throw lastError ?? RecorderError.cannotCombineSegments("capture did not stop")
    }

    private func finalizeCurrentOutput() async throws {
        guard let output = recordingOutput else { return }
        do {
            try await waitForRecordingToFinish()
        } catch RecorderError.recordingFinalizationTimedOut {
            throw RecorderError.recordingFinalizationTimedOut
        } catch {
            // A recording-output failure is terminal, so the file is safe to inspect.
        }
        _ = closePause(at: output.recordedDuration)
        recordingOutput = nil
        recordingOutputIsAttached = false
    }

    private func currentRecordingDuration() -> CMTime? {
        guard let duration = recordingOutput?.recordedDuration,
              duration.isNumeric,
              CMTimeCompare(duration, .zero) >= 0 else { return nil }
        return duration
    }

    private func closePause(at end: CMTime) -> Bool {
        guard let start = pauseStartedAt,
              end.isNumeric,
              CMTimeCompare(end, start) > 0 else { return false }
        pausedRanges.append(CMTimeRange(start: start, end: end))
        pauseStartedAt = nil
        return true
    }

    private func attachMeterOutputs() {
        do {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: meterQueue)
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: meterQueue)
            meterOutputsAttached = true
            isMeteringAvailable = true
        } catch {
            try? stream.removeStreamOutput(self, type: .audio)
            try? stream.removeStreamOutput(self, type: .microphone)
        }
    }

    private func detachMeterOutputs() {
        guard meterOutputsAttached else { return }
        try? stream.removeStreamOutput(self, type: .audio)
        try? stream.removeStreamOutput(self, type: .microphone)
        meterOutputsAttached = false
        meterQueue.sync {}
    }

    private func exportRecording() async throws -> URL {
        do {
            // ponytail: recovery MP4 is untrimmed if export fails; write raw samples if strict pause privacy is required.
            try await AudioExporter.export(
                from: stagingURL,
                excluding: pausedRanges,
                to: finalURL
            )
        } catch {
            try? FileManager.default.removeItem(at: finalURL)
            throw error
        }
        try? FileManager.default.removeItem(at: stagingURL)
        return finalURL
    }

    func removeEmptyStagingFile() {
        guard let size = try? stagingURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size == 0 else { return }
        try? FileManager.default.removeItem(at: stagingURL)
    }

    var recoveryURL: URL? {
        FileManager.default.fileExists(atPath: stagingURL.path) ? stagingURL : nil
    }

    private func makeRecordingOutput(for url: URL) -> SCRecordingOutput {
        let configuration = SCRecordingOutputConfiguration()
        configuration.outputURL = url
        configuration.outputFileType = .mp4
        return SCRecordingOutput(configuration: configuration, delegate: self)
    }

    private func recordingHasFinished() -> Bool {
        completionLock.lock()
        let hasResult = completionResult != nil
        completionLock.unlock()
        return hasResult
    }

    func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        guard recordingOutput === self.recordingOutput else { return }
        finishStarting(with: .success(()))
    }

    func recordingOutput(
        _ recordingOutput: SCRecordingOutput,
        didFailWithError error: any Error
    ) {
        guard recordingOutput === self.recordingOutput else { return }
        finishStarting(with: .failure(error))
        finish(with: .failure(error))
        failureHandler(error)
    }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        guard recordingOutput === self.recordingOutput else { return }
        finish(with: .success(()))
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        markStreamStopped()
        finishStarting(with: .failure(error))
        failureHandler(error)
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        let now = ProcessInfo.processInfo.systemUptime
        switch outputType {
        case .audio:
            guard now - lastSystemMeterTime >= minimumMeterInterval else { return }
            lastSystemMeterTime = now
            guard let measurement = systemMeter.measure(sampleBuffer) else { return }
            levelHandler(.meetingAudio, AudioLevelAnalyzer.visualLevel(measurement.rms))
        case .microphone:
            guard now - lastMicrophoneMeterTime >= minimumMeterInterval else { return }
            lastMicrophoneMeterTime = now
            guard let measurement = microphoneMeter.measure(sampleBuffer) else { return }
            levelHandler(.microphone, AudioLevelAnalyzer.visualLevel(measurement.rms))
        default:
            break
        }
    }

    private func waitForRecordingToStart() async throws {
        try await withCheckedThrowingContinuation { continuation in
            completionLock.lock()
            if let result = startResult {
                completionLock.unlock()
                continuation.resume(with: result)
            } else {
                startWaiter = continuation
                completionLock.unlock()
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 15_000_000_000)
                    self?.timeOutRecordingStart()
                }
            }
        }
    }

    private func waitForRecordingToFinish() async throws {
        try await withCheckedThrowingContinuation { continuation in
            completionLock.lock()
            if let result = completionResult {
                completionLock.unlock()
                continuation.resume(with: result)
            } else {
                completionWaiter = continuation
                completionLock.unlock()
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 30_000_000_000)
                    self?.timeOutRecordingFinalization()
                }
            }
        }
    }

    private func finish(with result: Result<Void, Error>) {
        completionLock.lock()
        guard completionResult == nil else {
            completionLock.unlock()
            return
        }
        completionResult = result
        let waiter = completionWaiter
        completionWaiter = nil
        completionLock.unlock()
        waiter?.resume(with: result)
    }

    private func timeOutRecordingStart() {
        completionLock.lock()
        guard startResult == nil,
              let waiter = startWaiter else {
            completionLock.unlock()
            return
        }
        startWaiter = nil
        completionLock.unlock()
        waiter.resume(throwing: RecorderError.recordingStartTimedOut)
    }

    private func timeOutRecordingFinalization() {
        completionLock.lock()
        guard completionResult == nil,
              let waiter = completionWaiter else {
            completionLock.unlock()
            return
        }
        completionWaiter = nil
        completionLock.unlock()
        waiter.resume(throwing: RecorderError.recordingFinalizationTimedOut)
    }

    private func markStreamStopped() {
        completionLock.lock()
        streamStopped = true
        completionLock.unlock()
    }

    private func finishStarting(with result: Result<Void, Error>) {
        completionLock.lock()
        guard startResult == nil else {
            completionLock.unlock()
            return
        }
        startResult = result
        let waiter = startWaiter
        startWaiter = nil
        completionLock.unlock()
        waiter?.resume(with: result)
    }
}

@MainActor
final class MeetingRecorder: ObservableObject {
    @Published var sources: [AudioSource] = [.all]
    @Published var selectedSourceID = AudioSource.all.id
    @Published private(set) var isRecording = false
    @Published private(set) var isPaused = false
    @Published private(set) var isBusy = false
    @Published private(set) var stopNeedsRetry = false
    @Published private(set) var elapsedSeconds = 0
    @Published private(set) var status = "Ready to record."
    @Published private(set) var meetingWaveform = [Float](repeating: 0, count: 40)
    @Published private(set) var microphoneWaveform = [Float](repeating: 0, count: 40)
    @Published private(set) var isMeteringAvailable = true
    @Published private(set) var hasSystemAudioPermission = CGPreflightScreenCaptureAccess()
    @Published private(set) var systemAudioPermissionNeedsRestart = false
    @Published var recordingName = ""

    private var session: RecordingSession?
    private var timer: Timer?
    private var pendingFailure: Error?

    var selectedSource: AudioSource {
        sources.first { $0.id == selectedSourceID } ?? .all
    }

    var elapsedText: String {
        String(format: "%02d:%02d", elapsedSeconds / 60, elapsedSeconds % 60)
    }

    var systemAudioPermissionHint: String {
        if Bundle.main.object(forInfoDictionaryKey: "RecordAdHocSigned") as? Bool == true {
            return "Allow access. If Record is already enabled, remove its old row first."
        }
        return "System audio access is required."
    }

    func reloadSources() async {
        guard !isRecording, !isBusy else { return }
        guard hasSystemAudioPermission, !systemAudioPermissionNeedsRestart else {
            status = systemAudioPermissionNeedsRestart
                ? "Permission enabled. Quit and reopen Record."
                : "Allow System Audio Recording to get started."
            return
        }
        do {
            let content = try await shareableContent()
            let ownPID = ProcessInfo.processInfo.processIdentifier
            let apps = content.applications
                .filter { $0.processID != ownPID && !$0.applicationName.isEmpty }
                .map {
                    AudioSource(
                        id: "\($0.bundleIdentifier):\($0.processID)",
                        name: $0.applicationName,
                        processID: $0.processID
                    )
                }
                .sorted {
                    $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }

            sources = [.all] + apps
            if !sources.contains(where: { $0.id == selectedSourceID }) {
                selectedSourceID = AudioSource.all.id
            }
            status = "Ready to record."
        } catch {
            status = "Could not load apps: \(error.localizedDescription)"
        }
    }

    func start() async {
        guard !isRecording, !isBusy else { return }
        isBusy = true
        stopNeedsRetry = false
        status = "Checking permissions…"
        resetWaveforms()
        isMeteringAvailable = true

        var newSession: RecordingSession?
        var started = false
        do {
            guard CGPreflightScreenCaptureAccess() else {
                hasSystemAudioPermission = false
                throw RecorderError.systemAudioDenied
            }
            guard await requestMicrophoneAccess() else {
                throw RecorderError.microphoneDenied
            }

            let source = selectedSource
            let content = try await shareableContent()
            guard let display = content.displays.first(where: {
                $0.displayID == CGMainDisplayID()
            }) ?? content.displays.first else {
                throw RecorderError.noDisplay
            }

            let filter: SCContentFilter
            if let processID = source.processID {
                guard let app = content.applications.first(where: {
                    $0.processID == processID
                }) else {
                    throw RecorderError.appNoLongerRunning(source.name)
                }
                filter = SCContentFilter(
                    display: display,
                    including: [app],
                    exceptingWindows: []
                )
            } else {
                let ownApps = content.applications.filter {
                    $0.processID == ProcessInfo.processInfo.processIdentifier
                }
                filter = SCContentFilter(
                    display: display,
                    excludingApplications: ownApps,
                    exceptingWindows: []
                )
            }

            let urls = try makeRecordingURLs(sourceName: source.name)
            recordingName = urls.final.deletingPathExtension().lastPathComponent
            newSession = try RecordingSession(
                filter: filter,
                stagingURL: urls.staging,
                finalURL: urls.final,
                failureHandler: { [weak self] error in
                    Task { @MainActor in
                        await self?.handleUnexpectedFailure(error)
                    }
                },
                levelHandler: { [weak self] source, level in
                    Task { @MainActor in
                        self?.receiveLevel(level, from: source)
                    }
                }
            )
            session = newSession
            isMeteringAvailable = newSession?.isMeteringAvailable ?? false
            try await newSession?.start()

            elapsedSeconds = 0
            isRecording = true
            isPaused = false
            started = true
            status = isMeteringAvailable
                ? "Recording \(source.name)…"
                : "Recording \(source.name)… Level preview is unavailable."
            startTimer()
        } catch {
            if let newSession, !newSession.canSafelyRelease {
                session = newSession
                isRecording = true
                isPaused = false
                stopNeedsRetry = true
                status = "Could not finish cancelling the failed start: \(error.localizedDescription) Press Stop again."
            } else {
                newSession?.removeEmptyStagingFile()
                session = nil
                isRecording = false
                isPaused = false
                stopNeedsRetry = false
                isMeteringAvailable = true
                status = error.localizedDescription
            }
        }
        await finishBusyOperation(checkForStoppedCapture: started)
    }

    @discardableResult
    func stop() async -> Bool {
        guard isRecording, !isBusy, let currentSession = session else {
            return !isRecording
        }
        isBusy = true
        timer?.invalidate()
        timer = nil
        status = "Finishing audio file…"

        do {
            let outputURL = try await currentSession.stopAndExport()
            do {
                let namedURL = try applyRecordingName(to: outputURL)
                status = "Saved \(namedURL.lastPathComponent)"
            } catch {
                status = "Saved \(outputURL.lastPathComponent), but could not apply the name: \(error.localizedDescription)"
            }
        } catch {
            if !currentSession.canSafelyRelease {
                stopNeedsRetry = true
                status = currentSession.captureIsStopped
                    ? "The audio file is still closing. Press Stop again in a moment."
                    : "Could not stop capture: \(error.localizedDescription) Press Stop again."
                await finishBusyOperation(checkForStoppedCapture: false)
                return !isRecording
            }
            if currentSession.recoveryURL != nil {
                status = "Could not finish the audio file: \(error.localizedDescription) Recovery files were kept."
            } else {
                status = "Could not finish recording: \(error.localizedDescription)"
            }
        }

        isRecording = false
        isPaused = false
        stopNeedsRetry = false
        isBusy = false
        pendingFailure = nil
        session = nil
        return true
    }

    func pause() {
        guard isRecording, !isPaused, !isBusy, !stopNeedsRetry,
              let currentSession = session else { return }
        guard currentSession.pause() else {
            status = "Could not pause yet. Try again."
            return
        }
        timer?.invalidate()
        timer = nil
        isPaused = true
        status = "Paused"
    }

    func resume() {
        guard isRecording, isPaused, !isBusy, !stopNeedsRetry,
              let currentSession = session else { return }
        guard currentSession.resume() else {
            status = "Could not resume yet. Try again."
            return
        }
        isPaused = false
        status = "Recording \(selectedSource.name)…"
        startTimer()
    }

    func openRecordingsFolder() {
        do {
            let directory = try recordingsDirectory()
            if !NSWorkspace.shared.open(directory) {
                status = "Could not open the recordings folder."
            }
        } catch {
            status = "Could not open the recordings folder: \(error.localizedDescription)"
        }
    }

    func recordedFiles(in directory: URL? = nil) throws -> [RecordedFile] {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .contentModificationDateKey,
            .fileSizeKey
        ]
        return try FileManager.default.contentsOfDirectory(
            at: try directory ?? recordingsDirectory(),
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )
        .compactMap { url in
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  transcribableAudioExtensions.contains(url.pathExtension.lowercased()) else {
                return nil
            }
            let transcriptURL = sidecarTranscriptURL(for: url)
            let legacyTranscriptURL = url.deletingLastPathComponent()
                .appendingPathComponent(
                    url.deletingPathExtension().lastPathComponent + " transcript"
                )
                .appendingPathExtension("txt")
            return RecordedFile(
                url: url,
                transcriptURL: FileManager.default.fileExists(atPath: transcriptURL.path)
                    ? transcriptURL
                    : (FileManager.default.fileExists(atPath: legacyTranscriptURL.path)
                        ? legacyTranscriptURL
                        : nil),
                modifiedAt: values.contentModificationDate ?? .distantPast,
                byteCount: values.fileSize ?? 0
            )
        }
        .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    func openRecordingFile(_ url: URL) {
        if !NSWorkspace.shared.open(url) {
            status = "Could not open \(url.lastPathComponent)."
        }
    }

    func revealRecordingFile(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func requestSystemAudioPermission() {
        guard !isRecording, !isBusy else { return }
        let granted = CGRequestScreenCaptureAccess() || CGPreflightScreenCaptureAccess()
        hasSystemAudioPermission = granted
        if granted {
            systemAudioPermissionNeedsRestart = true
            status = "Permission enabled. Quit and reopen Record."
        } else {
            status = "Allow Record in System Settings, then quit and reopen it."
            openSystemAudioSettings()
        }
    }

    func refreshSystemAudioPermission() {
        let granted = CGPreflightScreenCaptureAccess()
        if !hasSystemAudioPermission, granted {
            systemAudioPermissionNeedsRestart = true
            status = "Permission enabled. Quit and reopen Record."
        } else if hasSystemAudioPermission, !granted {
            systemAudioPermissionNeedsRestart = false
            status = "System Audio Recording permission was turned off."
        }
        hasSystemAudioPermission = granted
    }

    func openSystemAudioSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    func quitAfterPermissionChange() {
        guard !isRecording, !isBusy else { return }
        NSApp.terminate(nil)
    }

    private func handleUnexpectedFailure(_ error: Error) async {
        guard let currentSession = session else { return }
        if isBusy {
            pendingFailure = error
            return
        }
        guard isRecording else { return }
        isBusy = true
        timer?.invalidate()
        timer = nil
        await finishAfterFailure(error, session: currentSession)
        await finishBusyOperation(checkForStoppedCapture: false)
    }

    private func finishAfterFailure(_ error: Error, session currentSession: RecordingSession) async {
        let recoveredURL = await currentSession.recoverAfterFailure()
        if !currentSession.canSafelyRelease {
            stopNeedsRetry = true
            status = currentSession.captureIsStopped
                ? "Recording stopped, but the audio file is still closing. Press Stop again in a moment."
                : "Recording error: \(error.localizedDescription) Could not stop capture; press Stop again."
            return
        }
        if let recoveredURL {
            let namedURL = (try? applyRecordingName(to: recoveredURL)) ?? recoveredURL
            status = "Recording stopped: \(error.localizedDescription) Saved \(namedURL.lastPathComponent)."
        } else if currentSession.recoveryURL != nil {
            status = "Recording stopped: \(error.localizedDescription) Recovery files were kept."
        } else {
            status = "Recording stopped: \(error.localizedDescription)"
        }
        isRecording = false
        isPaused = false
        stopNeedsRetry = false
        session = nil
    }

    private func finishBusyOperation(checkForStoppedCapture: Bool) async {
        isBusy = false
        if let error = pendingFailure {
            pendingFailure = nil
            await handleUnexpectedFailure(error)
            return
        }
        if checkForStoppedCapture,
           isRecording,
           let currentSession = session,
           currentSession.captureIsStopped {
            await handleUnexpectedFailure(RecorderError.captureStoppedUnexpectedly)
        }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.elapsedSeconds += 1
            }
        }
    }

    private func resetWaveforms() {
        meetingWaveform = [Float](repeating: 0, count: meetingWaveform.count)
        microphoneWaveform = [Float](repeating: 0, count: microphoneWaveform.count)
    }

    private func receiveLevel(_ level: Float, from source: MeterSource) {
        switch source {
        case .meetingAudio:
            meetingWaveform.removeFirst()
            meetingWaveform.append(level)
        case .microphone:
            microphoneWaveform.removeFirst()
            microphoneWaveform.append(level)
        }
    }

    private func shareableContent() async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        )
    }

    private func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        default:
            return false
        }
    }

    private func recordingsDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base
            .appendingPathComponent("Meeting Audio", isDirectory: true)
            .appendingPathComponent("Recordings", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private func makeRecordingURLs(sourceName: String) throws -> (staging: URL, final: URL) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let safeSource = sourceName.replacingOccurrences(of: "/", with: "-")
        let baseName = "Recording \(formatter.string(from: Date())) – \(safeSource)"
        let directory = try recordingsDirectory()
        var finalURL = directory.appendingPathComponent(baseName).appendingPathExtension("m4a")
        var stagingURL = finalURL
            .deletingPathExtension()
            .appendingPathExtension("recording.mp4")
        var suffix = 2
        while FileManager.default.fileExists(atPath: finalURL.path)
            || FileManager.default.fileExists(atPath: stagingURL.path) {
            finalURL = directory
                .appendingPathComponent("\(baseName) \(suffix)")
                .appendingPathExtension("m4a")
            stagingURL = finalURL
                .deletingPathExtension()
                .appendingPathExtension("recording.mp4")
            suffix += 1
        }
        return (stagingURL, finalURL)
    }

    nonisolated static func sanitizedRecordingName(
        _ proposedName: String,
        fallback: String
    ) -> String {
        var name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.lowercased().hasSuffix(".m4a") {
            name.removeLast(4)
        }
        let invalidCharacters = CharacterSet.controlCharacters
            .union(CharacterSet(charactersIn: "/:"))
        name = name.unicodeScalars.map {
            invalidCharacters.contains($0) ? "-" : String($0)
        }.joined()
        name = name.trimmingCharacters(
            in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "."))
        )
        name = String(name.prefix(120))
        return name.isEmpty ? fallback : name
    }

    private func applyRecordingName(to outputURL: URL) throws -> URL {
        let fallback = outputURL.deletingPathExtension().lastPathComponent
        let baseName = Self.sanitizedRecordingName(recordingName, fallback: fallback)
        let directory = outputURL.deletingLastPathComponent()
        var destination = directory
            .appendingPathComponent(baseName)
            .appendingPathExtension("m4a")
        if destination.standardizedFileURL == outputURL.standardizedFileURL {
            return outputURL
        }

        var suffix = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = directory
                .appendingPathComponent("\(baseName) \(suffix)")
                .appendingPathExtension("m4a")
            suffix += 1
        }
        try FileManager.default.moveItem(at: outputURL, to: destination)
        recordingName = destination.deletingPathExtension().lastPathComponent
        return destination
    }
}

struct WaveformView: View {
    let samples: [Float]
    let color: Color

    var body: some View {
        Canvas { context, size in
            guard !samples.isEmpty else { return }
            let spacing: CGFloat = 2
            let totalSpacing = spacing * CGFloat(samples.count - 1)
            let barWidth = max(1, (size.width - totalSpacing) / CGFloat(samples.count))

            for (index, sample) in samples.enumerated() {
                let level = min(max(CGFloat(sample), 0), 1)
                let height = max(3, level * size.height)
                let rect = CGRect(
                    x: CGFloat(index) * (barWidth + spacing),
                    y: (size.height - height) / 2,
                    width: barWidth,
                    height: height
                )
                context.fill(
                    Path(roundedRect: rect, cornerRadius: min(2, barWidth / 2)),
                    with: .color(color.opacity(level > 0 ? 0.9 : 0.2))
                )
            }
        }
        .frame(height: 28)
        .padding(.horizontal, 6)
        .background(
            Color.primary.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 6)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(color.opacity(0.18), lineWidth: 1)
        }
    }
}

struct AudioMeterRow: View {
    let label: String
    let samples: [Float]
    let color: Color
    let isRecording: Bool
    let isPaused: Bool
    let isAvailable: Bool

    private var state: String {
        guard isRecording else { return "Idle" }
        guard !isPaused else { return "Paused" }
        guard isAvailable else { return "Unavailable" }
        return samples.suffix(8).max() ?? 0 > 0.08 ? "Signal" : "Quiet"
    }

    private var isActive: Bool {
        isRecording && !isPaused && isAvailable
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(state)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            WaveformView(
                samples: samples,
                color: isActive ? color : .gray
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(state)
    }
}

struct RecordingsView: View {
    @ObservedObject var recorder: MeetingRecorder
    @ObservedObject var transcription: LocalTranscription
    let onBack: () -> Void
    let onTranscribe: (URL) -> Void
    @State private var files: [RecordedFile] = []
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button {
                    onBack()
                } label: {
                    Label("Record", systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)

                Text("Recordings")
                    .font(.headline)
                Spacer()
                Button {
                    reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh files")
                .accessibilityLabel("Refresh files")

                Button("Open in Finder") { recorder.openRecordingsFolder() }
            }

            Text("Drag an audio row or its blue transcript row to share the file.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let errorMessage {
                ContentUnavailableView(
                    "Could not load recordings",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
            } else if files.isEmpty {
                ContentUnavailableView(
                    "No recordings yet",
                    systemImage: "waveform",
                    description: Text("Your recordings and transcripts will appear here.")
                )
            } else {
                List(files) { file in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 10) {
                            Image(systemName: iconName(for: file.url))
                                .font(.title3)
                                .foregroundStyle(.secondary)
                                .frame(width: 24)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(file.url.lastPathComponent)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text("\(file.modifiedAt.formatted(date: .abbreviated, time: .shortened)) · \(ByteCountFormatter.string(fromByteCount: Int64(file.byteCount), countStyle: .file))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Button {
                                requestTranscription(file.url)
                            } label: {
                                Image(
                                    systemName: file.transcriptURL == nil
                                        ? "text.bubble"
                                        : "arrow.triangle.2.circlepath"
                                )
                            }
                            .buttonStyle(.borderless)
                            .disabled(transcription.isTranscribing)
                            .help(
                                file.transcriptURL != nil
                                    ? "Transcribe again"
                                    : (transcription.isReady
                                        ? "Transcribe locally"
                                        : "Set up local transcription")
                            )
                            .accessibilityLabel(
                                file.transcriptURL == nil
                                    ? "Transcribe \(file.url.lastPathComponent)"
                                    : "Transcribe \(file.url.lastPathComponent) again"
                            )

                            Button {
                                recorder.revealRecordingFile(file.url)
                            } label: {
                                Image(systemName: "magnifyingglass")
                            }
                            .buttonStyle(.borderless)
                            .help("Show in Finder")
                            .accessibilityLabel("Show \(file.url.lastPathComponent) in Finder")
                        }
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            recorder.openRecordingFile(file.url)
                        }
                        .onDrag {
                            itemProvider(for: file.url)
                        }
                        .contextMenu {
                            Button("Open") { recorder.openRecordingFile(file.url) }
                            if let transcriptURL = file.transcriptURL {
                                Button("Open transcript") {
                                    recorder.openRecordingFile(transcriptURL)
                                }
                                Button("Transcribe again") { requestTranscription(file.url) }
                                    .disabled(transcription.isTranscribing)
                            } else {
                                Button("Transcribe") { requestTranscription(file.url) }
                                    .disabled(transcription.isTranscribing)
                            }
                            Button("Show in Finder") { recorder.revealRecordingFile(file.url) }
                        }

                        if let transcriptURL = file.transcriptURL {
                            HStack(spacing: 7) {
                                Image(systemName: "doc.text.fill")
                                Text(transcriptURL.lastPathComponent)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Text("Drag")
                                Image(systemName: "arrow.up.forward.square")
                            }
                            .font(.caption)
                            .foregroundStyle(.blue)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.blue.opacity(0.09))
                            )
                            .padding(.leading, 34)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) {
                                recorder.openRecordingFile(transcriptURL)
                            }
                            .onDrag { itemProvider(for: transcriptURL) }
                            .contextMenu {
                                Button("Open transcript") {
                                    recorder.openRecordingFile(transcriptURL)
                                }
                                Button("Show in Finder") {
                                    recorder.revealRecordingFile(transcriptURL)
                                }
                                Button("Transcribe again") { requestTranscription(file.url) }
                                    .disabled(transcription.isTranscribing)
                            }
                            .help("Double-click to open or drag this transcript to another app")
                            .accessibilityLabel("Transcript \(transcriptURL.lastPathComponent), draggable")
                        }
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.inset)
            }

            if transcription.isTranscribing {
                VStack(alignment: .leading, spacing: 5) {
                    ProgressView(value: transcription.transcriptionProgress)
                    HStack {
                        Text(transcription.status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int(transcription.transcriptionProgress * 100))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Button("Cancel") { transcription.cancelTranscription() }
                            .controlSize(.small)
                            .disabled(transcription.isCancellingTranscription)
                    }
                }
            } else if transcription.lastOutputURL != nil {
                Text(transcription.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 520, height: 360)
        .onAppear { reload() }
        .onChange(of: transcription.isTranscribing) { wasTranscribing, isTranscribing in
            if wasTranscribing, !isTranscribing { reload() }
        }
    }

    private func reload() {
        do {
            files = try recorder.recordedFiles()
            errorMessage = nil
        } catch {
            files = []
            errorMessage = error.localizedDescription
        }
    }

    private func iconName(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "mp4":
            return "lifepreserver"
        default:
            return "waveform"
        }
    }

    private func itemProvider(for url: URL) -> NSItemProvider {
        NSItemProvider(contentsOf: url) ?? NSItemProvider(object: url as NSURL)
    }

    private func requestTranscription(_ url: URL) {
        onTranscribe(url)
    }
}

struct ContentView: View {
    private enum Screen {
        case recorder
        case recordings
        case transcription(URL)
    }

    @ObservedObject var recorder: MeetingRecorder
    let checkForUpdates: () -> Void
    @StateObject private var transcription = LocalTranscription()
    @State private var screen = Screen.recorder

    var body: some View {
        Group {
            switch screen {
            case .recorder:
                recorderView
            case .recordings:
                RecordingsView(
                    recorder: recorder,
                    transcription: transcription,
                    onBack: { screen = .recorder },
                    onTranscribe: { screen = .transcription($0) }
                )
            case .transcription(let audioURL):
                TranscriptionView(
                    transcription: transcription,
                    audioURL: audioURL,
                    onBack: { screen = .recordings },
                    onFinished: {
                        if case .transcription = screen {
                            screen = .recordings
                        }
                    }
                )
            }
        }
        .task {
            await recorder.reloadSources()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            recorder.refreshSystemAudioPermission()
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: checkForUpdates) {
                    Image(systemName: "arrow.down.app")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .controlSize(.mini)
                .help("Check for updates")
                .accessibilityLabel("Check for updates")
            }
        }
    }

    private var recorderView: some View {
        VStack(alignment: .leading, spacing: 8) {
            if recorder.systemAudioPermissionNeedsRestart {
                HStack(spacing: 8) {
                    Label("Permission enabled", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                    Spacer()
                    Button("Quit Record") { recorder.quitAfterPermissionChange() }
                        .controlSize(.small)
                }
            } else if !recorder.hasSystemAudioPermission {
                HStack(spacing: 8) {
                    Text(recorder.systemAudioPermissionHint)
                        .font(.caption)
                    Spacer()
                    Button("Allow") { recorder.requestSystemAudioPermission() }
                        .controlSize(.small)
                    Button {
                        recorder.openSystemAudioSettings()
                    } label: {
                        Image(systemName: "gear")
                    }
                    .buttonStyle(.borderless)
                    .help("Open System Settings")
                    .accessibilityLabel("Open System Settings")
                }
            }

            VStack(spacing: 8) {
                AudioMeterRow(
                    label: "Audio",
                    samples: recorder.meetingWaveform,
                    color: .green,
                    isRecording: recorder.isRecording,
                    isPaused: recorder.isPaused,
                    isAvailable: recorder.isMeteringAvailable
                )
                AudioMeterRow(
                    label: "Microphone",
                    samples: recorder.microphoneWaveform,
                    color: .blue,
                    isRecording: recorder.isRecording,
                    isPaused: recorder.isPaused,
                    isAvailable: recorder.isMeteringAvailable
                )
            }

            HStack(spacing: 8) {
                Picker("Source", selection: $recorder.selectedSourceID) {
                    ForEach(recorder.sources) { source in
                        Text(source.name).tag(source.id)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity)
                .help(
                    recorder.selectedSource.processID == nil
                        ? "Record all system audio"
                        : "Records all audio from this app; browser tabs cannot be separated"
                )
                .disabled(
                    recorder.isRecording
                        || recorder.isBusy
                        || !recorder.hasSystemAudioPermission
                        || recorder.systemAudioPermissionNeedsRestart
                )

                Button {
                    Task { await recorder.reloadSources() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh running apps")
                .accessibilityLabel("Refresh audio sources")
                .disabled(
                    recorder.isRecording
                        || recorder.isBusy
                        || !recorder.hasSystemAudioPermission
                        || recorder.systemAudioPermissionNeedsRestart
                )
            }

            if recorder.isRecording {
                HStack(spacing: 6) {
                    Label("Name", systemImage: "pencil")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Recording name", text: $recorder.recordingName)
                        .textFieldStyle(.roundedBorder)
                        .disabled(recorder.isBusy)
                        .accessibilityLabel("Recording name")
                }

                HStack(spacing: 8) {
                    Text(recorder.elapsedText)
                        .font(.system(.callout, design: .monospaced).weight(.medium))
                        .foregroundStyle(recorder.isPaused ? .secondary : .primary)
                        .accessibilityLabel("Recorded time")
                        .accessibilityValue(recorder.elapsedText)

                    Spacer()

                    Button {
                        if recorder.isPaused {
                            recorder.resume()
                        } else {
                            recorder.pause()
                        }
                    } label: {
                        Label(
                            recorder.isPaused ? "Resume" : "Pause",
                            systemImage: recorder.isPaused ? "play.fill" : "pause.fill"
                        )
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(recorder.isBusy || recorder.stopNeedsRetry)

                    Button {
                        Task { await recorder.stop() }
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.red)
                    .disabled(recorder.isBusy)
                }
            } else {
                HStack {
                    Spacer()
                    Button {
                        Task { await recorder.start() }
                    } label: {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(.red)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(
                        recorder.isBusy
                            || !recorder.hasSystemAudioPermission
                            || recorder.systemAudioPermissionNeedsRestart
                    )
                    .keyboardShortcut(.space, modifiers: [])
                    .help("Start recording")
                    .accessibilityLabel("Record")
                    Spacer()
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(recorder.status)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    screen = .recordings
                } label: {
                    Image(systemName: "folder")
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("Open recordings folder")
                .accessibilityLabel("Open recordings folder")
            }
        }
        .padding(12)
        .frame(width: 300)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var recorder: MeetingRecorder?
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag {
            sender.windows.first?.makeKeyAndOrderFront(nil)
        }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let recorder, recorder.isRecording else { return .terminateNow }
        guard !recorder.isBusy else { return .terminateCancel }
        Task {
            let stopped = await recorder.stop()
            sender.reply(toApplicationShouldTerminate: stopped)
        }
        return .terminateLater
    }
}

struct MeetingAudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var recorder = MeetingRecorder()

    var body: some Scene {
        WindowGroup {
            ContentView(
                recorder: recorder,
                checkForUpdates: appDelegate.checkForUpdates
            )
                .onAppear { appDelegate.recorder = recorder }
        }
        .windowResizability(.contentSize)
        .windowToolbarStyle(.unifiedCompact)
    }
}
