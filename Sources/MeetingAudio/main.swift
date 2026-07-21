import AVFoundation
import Darwin
import Foundation

enum SelfCheckError: Error {
    case silentAudio
    case pauseNotTrimmed(String)
    case unexpectedVideo
}

if CommandLine.arguments.contains("--self-check") {
    Task {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
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
            print("Audio-only export, pause-trim, and level-meter self-check passed")
            exit(EXIT_SUCCESS)
        } catch {
            FileHandle.standardError.write(Data("Audio export self-check failed: \(error)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }
    dispatchMain()
} else {
    MeetingAudioApp.main()
}
