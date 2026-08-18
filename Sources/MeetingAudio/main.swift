import AppKit
import AVFoundation
import Darwin
import Foundation

enum SingleInstanceLockError: Error {
    case held
    case system(Int32)
}

final class SingleInstanceLock {
    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    static func acquire(named name: String = "com.local.MeetingAudio.\(getuid()).lock") throws -> SingleInstanceLock {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent(name)
            .path
        let descriptor = path.withCString {
            Darwin.open($0, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else { throw SingleInstanceLockError.system(errno) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            if code == EWOULDBLOCK { throw SingleInstanceLockError.held }
            throw SingleInstanceLockError.system(code)
        }
        return SingleInstanceLock(descriptor: descriptor)
    }

    deinit {
        Darwin.close(descriptor)
    }
}

@discardableResult
func activateExistingRecord(waitingUpTo timeout: TimeInterval) -> Bool {
    guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return false }
    let deadline = Date().addingTimeInterval(timeout)
    var running: NSRunningApplication?

    repeat {
        running = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .first(where: {
                $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
            })
        if let running, running.isFinishedLaunching {
            running.activate(options: [.activateAllWindows])
            return true
        }
        guard Date() < deadline else { break }
        usleep(50_000)
    } while true

    guard let running else { return false }
    running.activate(options: [.activateAllWindows])
    return true
}

enum SelfCheckError: Error {
    case silentAudio
    case transcriptionAudio
    case transcriptionCancellation
    case recordingBrowser
    case recordingName
    case pauseNotTrimmed(String)
    case singleInstanceLock
    case unexpectedVideo
}

if let index = CommandLine.arguments.firstIndex(of: "--transcription-self-check"),
   CommandLine.arguments.indices.contains(index + 2) {
    let modelURL = URL(fileURLWithPath: CommandLine.arguments[index + 1])
    let audioURL = URL(fileURLWithPath: CommandLine.arguments[index + 2])
    Task {
        do {
            let transcript = try await LocalWhisper.transcribe(
                audioURL: audioURL,
                modelURL: modelURL,
                language: "auto"
            )
            print(transcript, terminator: "")
            exit(EXIT_SUCCESS)
        } catch {
            FileHandle.standardError.write(Data("Transcription self-check failed: \(error)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }
    dispatchMain()
} else if CommandLine.arguments.contains("--self-check") {
    Task {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            let lockName = "Record-self-check-\(UUID().uuidString).lock"
            let lock = try SingleInstanceLock.acquire(named: lockName)
            do {
                _ = try SingleInstanceLock.acquire(named: lockName)
                throw SelfCheckError.singleInstanceLock
            } catch SingleInstanceLockError.held {
                // Expected: a second launch cannot acquire the same lock.
            }
            withExtendedLifetime(lock) {}

            guard MeetingRecorder.sanitizedRecordingName(
                "  Team / Q3: Sync.m4a  ",
                fallback: "Recording"
            ) == "Team - Q3- Sync" else {
                throw SelfCheckError.recordingName
            }
            let transcriptionControl = TranscriptionControl()
            guard !transcriptionControl.isCancelled else {
                throw SelfCheckError.transcriptionCancellation
            }
            transcriptionControl.cancel()
            guard transcriptionControl.isCancelled else {
                throw SelfCheckError.transcriptionCancellation
            }

            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let input: URL
            if let index = CommandLine.arguments.firstIndex(of: "--self-check-input"),
               CommandLine.arguments.indices.contains(index + 1) {
                input = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            } else {
                input = URL(fileURLWithPath: "/System/Library/PrivateFrameworks/AccessibilitySupport.framework/Versions/A/Frameworks/AccessibilityKit.framework/Versions/A/Resources/Click.m4a")
            }
            let output = directory.appendingPathComponent("self-check.m4a")
            try await AudioExporter.export(from: input, to: output)
            let transcript = sidecarTranscriptURL(for: output)
            try "Self-check transcript\n".write(
                to: transcript,
                atomically: true,
                encoding: .utf8
            )
            let baselineAsset = AVURLAsset(url: output)
            let baselineDuration = try await baselineAsset.load(.duration).seconds
            let meterInput = URL(
                fileURLWithPath: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/telephony/ringback_tone_ansi.caf"
            )
            let audioFile = try AVAudioFile(
                forReading: meterInput,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: audioFile.processingFormat,
                frameCapacity: AVAudioFrameCount(audioFile.length)
            ) else { throw SelfCheckError.silentAudio }
            try audioFile.read(into: buffer)
            guard let measurement = AudioLevelAnalyzer.measure(buffer),
                  AudioLevelAnalyzer.visualLevel(measurement.rms) > 0 else {
                throw SelfCheckError.silentAudio
            }
            let transcriptionSamples = try await LocalWhisper.pcmSamples(from: input)
            guard !transcriptionSamples.isEmpty else {
                throw SelfCheckError.transcriptionAudio
            }

            let sourceAsset = AVURLAsset(url: input)
            let sourceTracks = try await sourceAsset.loadTracks(withMediaType: .audio)
            guard let sourceTrack = sourceTracks.first else { throw RecorderError.noAudioTrack }
            let singleDuration = try await sourceTrack.load(.timeRange).duration.seconds
            let pauses = [
                CMTimeRange(
                    start: CMTime(seconds: singleDuration * 0.2, preferredTimescale: 48_000),
                    duration: CMTime(seconds: singleDuration * 0.2, preferredTimescale: 48_000)
                ),
                CMTimeRange(
                    start: CMTime(seconds: singleDuration * 0.6, preferredTimescale: 48_000),
                    duration: CMTime(seconds: singleDuration * 0.2, preferredTimescale: 48_000)
                )
            ]
            let trimmedOutput = directory.appendingPathComponent("pause-trim-self-check.m4a")
            try await AudioExporter.export(from: input, excluding: pauses, to: trimmedOutput)

            let trimmedAsset = AVURLAsset(url: trimmedOutput)
            let trimmedDuration = try await trimmedAsset.load(.duration).seconds
            let expectedDuration = baselineDuration - singleDuration * 0.4
            guard trimmedDuration < baselineDuration,
                  abs(trimmedDuration - expectedDuration) < 0.05 else {
                throw SelfCheckError.pauseNotTrimmed(
                    "multiple pauses: baseline \(baselineDuration), got \(trimmedDuration)"
                )
            }

            let shortPause = CMTimeRange(
                start: CMTime(seconds: singleDuration * 0.3, preferredTimescale: 48_000),
                duration: CMTime(seconds: 0.005, preferredTimescale: 48_000)
            )
            let shortTrimmedOutput = directory.appendingPathComponent("short-pause-self-check.m4a")
            try await AudioExporter.export(
                from: input,
                excluding: [shortPause],
                to: shortTrimmedOutput
            )
            let shortTrimmedDuration = try await AVURLAsset(url: shortTrimmedOutput)
                .load(.duration).seconds
            guard shortTrimmedDuration < baselineDuration - 0.002,
                  abs(shortTrimmedDuration - (baselineDuration - 0.005)) < 0.02 else {
                throw SelfCheckError.pauseNotTrimmed(
                    "short pause: baseline \(baselineDuration), got \(shortTrimmedDuration)"
                )
            }
            let tracks = try await trimmedAsset.loadTracks(withMediaType: .audio)
            guard !tracks.isEmpty else { throw RecorderError.noAudioTrack }
            let videoTracks = try await trimmedAsset.loadTracks(withMediaType: .video)
            guard videoTracks.isEmpty else { throw SelfCheckError.unexpectedVideo }
            let browserFiles = try await MainActor.run {
                try MeetingRecorder().recordedFiles(in: directory)
            }
            guard browserFiles.contains(where: {
                $0.url.lastPathComponent == output.lastPathComponent
                    && $0.transcriptURL?.lastPathComponent == transcript.lastPathComponent
            }), browserFiles.contains(where: {
                $0.url.lastPathComponent == trimmedOutput.lastPathComponent
            }) else {
                throw SelfCheckError.recordingBrowser
            }
            print("Single-instance, audio-only export, pause-trim, level-meter, transcription-audio, and file-browser self-check passed")
            exit(EXIT_SUCCESS)
        } catch {
            FileHandle.standardError.write(Data("Audio export self-check failed: \(error)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }
    dispatchMain()
} else {
    if activateExistingRecord(waitingUpTo: 0) {
        exit(EXIT_SUCCESS)
    }

    do {
        let lock = try SingleInstanceLock.acquire()
        withExtendedLifetime(lock) {
            MeetingAudioApp.main()
        }
    } catch SingleInstanceLockError.held {
        activateExistingRecord(waitingUpTo: 2)
    } catch {
        FileHandle.standardError.write(Data("Single-instance lock failed: \(error)\n".utf8))
        MeetingAudioApp.main()
    }
}
