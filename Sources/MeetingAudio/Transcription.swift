import AppKit
import AVFoundation
import CoreMedia
import CryptoKit
import Foundation
import SwiftUI
import whisper

struct TranscriptionLanguage: Identifiable, Hashable {
    static let automatic = TranscriptionLanguage(code: "auto", name: "Auto-detect")

    let code: String
    let name: String
    var id: String { code }

    static var available: [TranscriptionLanguage] {
        let languages = (0...whisper_lang_max_id()).compactMap { identifier -> TranscriptionLanguage? in
            guard let codePointer = whisper_lang_str(identifier) else { return nil }
            let code = String(cString: codePointer)
            let name = Locale.current.localizedString(forLanguageCode: code)
                ?? String(cString: whisper_lang_str_full(identifier))
            return TranscriptionLanguage(code: code, name: name)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return [.automatic] + languages
    }
}

struct WhisperModel: Identifiable, Hashable {
    static let available = [
        WhisperModel(
            id: "default",
            name: "Default",
            detail: "Quantized Turbo · recommended",
            fileName: "ggml-large-v3-turbo-q5_0.bin",
            bytes: 574_041_195,
            sha256: "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2"
        ),
        WhisperModel(
            id: "quality",
            name: "Best quality",
            detail: "Full Turbo · largest download",
            fileName: "ggml-large-v3-turbo.bin",
            bytes: 1_624_555_275,
            sha256: "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69"
        )
    ]

    let id: String
    let name: String
    let detail: String
    let fileName: String
    let bytes: Int
    let sha256: String

    var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    var downloadURL: URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(fileName)")!
    }
}

enum TranscriptionError: LocalizedError {
    case insufficientDiskSpace
    case invalidDownload
    case modelLoadFailed
    case audioConversionFailed(String)
    case transcriptionFailed
    case emptyTranscript
    case audioTooLong

    var errorDescription: String? {
        switch self {
        case .insufficientDiskSpace:
            return "There is not enough free space for the selected model."
        case .invalidDownload:
            return "The transcription model download could not be verified."
        case .modelLoadFailed:
            return "The local transcription model could not be loaded."
        case .audioConversionFailed(let reason):
            return "The audio could not be prepared for transcription (\(reason))."
        case .transcriptionFailed:
            return "Local transcription failed."
        case .emptyTranscript:
            return "Whisper did not find any speech in this audio."
        case .audioTooLong:
            return "This recording is too long to process in one pass."
        }
    }
}

final class TranscriptionControl: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    private let progressHandler: @Sendable (Double) -> Void

    init(progressHandler: @escaping @Sendable (Double) -> Void = { _ in }) {
        self.progressHandler = progressHandler
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func cancel() {
        lock.lock()
        value = true
        lock.unlock()
    }

    func checkCancellation() throws {
        if isCancelled { throw CancellationError() }
    }

    func reportProgress(_ percent: Int32) {
        progressHandler(min(max(Double(percent) / 100, 0), 1))
    }
}

private final class ModelDownload: NSObject, URLSessionDownloadDelegate {
    private let destinationURL: URL
    private let progressHandler: (Double) -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private var moveError: Error?
    private var task: URLSessionDownloadTask?
    private lazy var session = URLSession(
        configuration: .default,
        delegate: self,
        delegateQueue: nil
    )

    init(destinationURL: URL, progressHandler: @escaping (Double) -> Void) {
        self.destinationURL = destinationURL
        self.progressHandler = progressHandler
    }

    func start(url: URL) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let task = session.downloadTask(with: url)
                self.task = task
                task.resume()
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        task?.cancel()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progressHandler(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            try? FileManager.default.removeItem(at: destinationURL)
            try FileManager.default.moveItem(at: location, to: destinationURL)
        } catch {
            moveError = error
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        defer {
            continuation = nil
            self.task = nil
            session.finishTasksAndInvalidate()
        }
        if let error {
            continuation?.resume(throwing: error)
        } else if let moveError {
            continuation?.resume(throwing: moveError)
        } else {
            continuation?.resume()
        }
    }
}

enum LocalWhisper {
    static func transcribe(
        audioURL: URL,
        modelURL: URL,
        language: String,
        control: TranscriptionControl? = nil
    ) async throws -> String {
        try control?.checkCancellation()
        let samples = try await pcmSamples(from: audioURL, control: control)
        guard samples.count <= Int(Int32.max) else { throw TranscriptionError.audioTooLong }
        try control?.checkCancellation()

        var contextParameters = whisper_context_default_params()
        contextParameters.use_gpu = true
        contextParameters.flash_attn = true
        guard let context = modelURL.path.withCString({
            whisper_init_from_file_with_params($0, contextParameters)
        }) else {
            throw TranscriptionError.modelLoadFailed
        }
        defer { whisper_free(context) }

        var parameters = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        parameters.n_threads = Int32(max(1, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))
        parameters.print_progress = false
        parameters.print_realtime = false
        parameters.print_timestamps = false
        parameters.no_timestamps = true
        if let control {
            parameters.abort_callback = { pointer in
                guard let pointer else { return false }
                return Unmanaged<TranscriptionControl>
                    .fromOpaque(pointer)
                    .takeUnretainedValue()
                    .isCancelled
            }
            parameters.abort_callback_user_data = Unmanaged
                .passUnretained(control)
                .toOpaque()
            parameters.progress_callback = { _, _, progress, pointer in
                guard let pointer else { return }
                Unmanaged<TranscriptionControl>
                    .fromOpaque(pointer)
                    .takeUnretainedValue()
                    .reportProgress(progress)
            }
            parameters.progress_callback_user_data = Unmanaged
                .passUnretained(control)
                .toOpaque()
        }

        let result = language.withCString { languagePointer in
            parameters.language = languagePointer
            return samples.withUnsafeBufferPointer {
                whisper_full(context, parameters, $0.baseAddress, Int32($0.count))
            }
        }
        try control?.checkCancellation()
        guard result == 0 else { throw TranscriptionError.transcriptionFailed }

        let segmentCount = whisper_full_n_segments(context)
        let transcript = (0..<segmentCount).compactMap { index -> String? in
            guard let text = whisper_full_get_segment_text(context, index) else { return nil }
            return String(cString: text)
        }
        .joined()
        .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else { throw TranscriptionError.emptyTranscript }
        return transcript + "\n"
    }

    static func pcmSamples(
        from audioURL: URL,
        control: TranscriptionControl? = nil
    ) async throws -> [Float] {
        try control?.checkCancellation()
        let asset = AVURLAsset(url: audioURL)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else {
            throw TranscriptionError.audioConversionFailed("no audio track")
        }
        let duration = try await asset.load(.duration)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: Int(kAudioFormatLinearPCM),
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
        )
        guard reader.canAdd(output) else {
            throw TranscriptionError.audioConversionFailed("unsupported audio format")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw TranscriptionError.audioConversionFailed(
                reader.error?.localizedDescription ?? "could not start decoding"
            )
        }

        // ponytail: one in-memory float per 16 kHz sample; stream chunks if multi-hour recordings become common.
        var samples: [Float] = []
        if duration.isNumeric, duration.seconds > 0 {
            samples.reserveCapacity(Int(duration.seconds * 16_000))
        }
        while let sampleBuffer = output.copyNextSampleBuffer() {
            do {
                try control?.checkCancellation()
            } catch {
                reader.cancelReading()
                throw error
            }
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            let byteCount = CMBlockBufferGetDataLength(blockBuffer)
            guard byteCount > 0, byteCount.isMultiple(of: MemoryLayout<Float>.size) else {
                continue
            }
            let previousCount = samples.count
            let addedCount = byteCount / MemoryLayout<Float>.size
            samples.append(contentsOf: repeatElement(0, count: addedCount))
            let copyStatus = samples.withUnsafeMutableBytes { bytes in
                CMBlockBufferCopyDataBytes(
                    blockBuffer,
                    atOffset: 0,
                    dataLength: byteCount,
                    destination: bytes.baseAddress!.advanced(
                        by: previousCount * MemoryLayout<Float>.size
                    )
                )
            }
            guard copyStatus == kCMBlockBufferNoErr else {
                reader.cancelReading()
                throw TranscriptionError.audioConversionFailed("could not read decoded samples")
            }
        }
        guard reader.status == .completed else {
            throw TranscriptionError.audioConversionFailed(
                reader.error?.localizedDescription ?? "decoding stopped"
            )
        }
        guard !samples.isEmpty else {
            throw TranscriptionError.audioConversionFailed("the audio is empty")
        }
        return samples
    }
}

@MainActor
final class LocalTranscription: ObservableObject {
    @Published private(set) var isReady = false
    @Published private(set) var isDownloading = false
    @Published private(set) var downloadProgress = 0.0
    @Published private(set) var isTranscribing = false
    @Published private(set) var isCancellingTranscription = false
    @Published private(set) var transcriptionProgress = 0.0
    @Published private(set) var status = "Local transcription is not set up."
    @Published private(set) var lastOutputURL: URL?
    @Published var selectedLanguageCode: String {
        didSet { UserDefaults.standard.set(selectedLanguageCode, forKey: "transcriptionLanguage") }
    }
    @Published var selectedModelID: String {
        didSet {
            UserDefaults.standard.set(selectedModelID, forKey: "transcriptionModel")
            refreshModelStatus()
        }
    }

    let languages = TranscriptionLanguage.available
    let models = WhisperModel.available
    private var downloader: ModelDownload?
    private var transcriptionControl: TranscriptionControl?

    var selectedModel: WhisperModel {
        models.first { $0.id == selectedModelID }
            ?? models.first { $0.id == "default" }!
    }

    init() {
        let savedLanguage = UserDefaults.standard.string(forKey: "transcriptionLanguage") ?? "auto"
        selectedLanguageCode = TranscriptionLanguage.available.contains { $0.code == savedLanguage }
            ? savedLanguage
            : "auto"
        let savedModel = UserDefaults.standard.string(forKey: "transcriptionModel") ?? "default"
        selectedModelID = WhisperModel.available.contains { $0.id == savedModel }
            ? savedModel
            : "default"
        refreshModelStatus()
    }

    func setup() async {
        guard !isReady, !isDownloading else { return }
        isDownloading = true
        downloadProgress = 0
        status = "Preparing download…"

        do {
            let model = selectedModel
            let directory = try transcriptionDirectory()
            let capacity = try directory.resourceValues(
                forKeys: [.volumeAvailableCapacityForImportantUsageKey]
            ).volumeAvailableCapacityForImportantUsage ?? 0
            guard capacity >= Int64(model.bytes + 100_000_000) else {
                throw TranscriptionError.insufficientDiskSpace
            }

            let partialURL = directory.appendingPathComponent(model.fileName + ".download")
            let download = ModelDownload(destinationURL: partialURL) { [weak self] progress in
                Task { @MainActor in
                    self?.downloadProgress = progress
                    self?.status = "Downloading model… \(Int(progress * 100))%"
                }
            }
            downloader = download
            try await download.start(url: model.downloadURL)
            downloader = nil

            status = "Verifying model…"
            let digest = try await Task.detached(priority: .utility) {
                try Self.sha256(of: partialURL)
            }.value
            let size = try partialURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
            guard size == model.bytes, digest == model.sha256 else {
                throw TranscriptionError.invalidDownload
            }

            let finalURL = directory.appendingPathComponent(model.fileName)
            try? FileManager.default.removeItem(at: finalURL)
            try FileManager.default.moveItem(at: partialURL, to: finalURL)
            for otherModel in models where otherModel.id != model.id {
                try? FileManager.default.removeItem(
                    at: directory.appendingPathComponent(otherModel.fileName)
                )
            }
            isReady = true
            downloadProgress = 1
            status = "\(model.name) model is ready."
        } catch {
            if let partialURL = try? transcriptionDirectory()
                .appendingPathComponent(selectedModel.fileName + ".download") {
                try? FileManager.default.removeItem(at: partialURL)
            }
            let wasCancelled = (error as? CancellationError) != nil
                || (error as NSError).code == NSURLErrorCancelled
            status = wasCancelled
                ? "Download cancelled."
                : "Setup failed: \(error.localizedDescription)"
        }
        downloader = nil
        isDownloading = false
    }

    func cancelSetup() {
        downloader?.cancel()
    }

    func removeModel() {
        guard !isDownloading, !isTranscribing else { return }
        if let url = try? modelURL(for: selectedModel) {
            try? FileManager.default.removeItem(at: url)
        }
        isReady = false
        downloadProgress = 0
        lastOutputURL = nil
        status = "Local transcription is not set up."
    }

    func transcribe(_ audioURL: URL) async -> URL? {
        guard isReady, !isTranscribing else { return nil }
        var completedURL: URL?
        let control = TranscriptionControl { [weak self] progress in
            Task { @MainActor [weak self] in
                self?.transcriptionProgress = progress
            }
        }
        transcriptionControl = control
        isTranscribing = true
        isCancellingTranscription = false
        transcriptionProgress = 0
        lastOutputURL = nil
        status = "Preparing \(audioURL.lastPathComponent)…"
        do {
            let modelURL = try modelURL(for: selectedModel)
            let language = selectedLanguageCode
            status = "Transcribing locally…"
            let transcript = try await Task.detached(priority: .userInitiated) {
                try await LocalWhisper.transcribe(
                    audioURL: audioURL,
                    modelURL: modelURL,
                    language: language,
                    control: control
                )
            }.value
            try control.checkCancellation()
            let outputURL = sidecarTranscriptURL(for: audioURL)
            try transcript.write(to: outputURL, atomically: true, encoding: .utf8)
            transcriptionProgress = 1
            lastOutputURL = outputURL
            completedURL = outputURL
            status = "Saved \(outputURL.lastPathComponent)"
        } catch is CancellationError {
            status = "Transcription cancelled."
        } catch {
            status = "Transcription failed: \(error.localizedDescription)"
        }
        transcriptionControl = nil
        isTranscribing = false
        isCancellingTranscription = false
        return completedURL
    }

    func cancelTranscription() {
        guard isTranscribing, !isCancellingTranscription else { return }
        isCancellingTranscription = true
        status = "Cancelling transcription…"
        transcriptionControl?.cancel()
    }

    func revealTranscript() {
        guard let lastOutputURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([lastOutputURL])
    }

    private func refreshModelStatus() {
        isReady = false
        guard let url = try? modelURL(for: selectedModel),
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size == selectedModel.bytes else {
            status = "\(selectedModel.name) model is not downloaded."
            return
        }
        isReady = true
        status = "\(selectedModel.name) model is ready."
    }

    private func modelURL(for model: WhisperModel) throws -> URL {
        try transcriptionDirectory().appendingPathComponent(model.fileName)
    }

    private func transcriptionDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base
            .appendingPathComponent("Meeting Audio", isDirectory: true)
            .appendingPathComponent("Transcription", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    nonisolated private static func sha256(of url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let data = try file.read(upToCount: 1_048_576), !data.isEmpty {
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

struct TranscriptionView: View {
    @ObservedObject var transcription: LocalTranscription
    let audioURL: URL
    let onBack: () -> Void
    let onFinished: () -> Void
    @State private var confirmsRemoval = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Button {
                    onBack()
                } label: {
                    Label("Recordings", systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)

                Text("Transcribe")
                    .font(.headline)
                Spacer()
            }

            Text(audioURL.lastPathComponent)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)

            Picker("Model", selection: $transcription.selectedModelID) {
                ForEach(transcription.models) { model in
                    Text("\(model.name) · \(model.sizeLabel)").tag(model.id)
                }
            }
            .disabled(transcription.isDownloading || transcription.isTranscribing)

            Text(transcription.selectedModel.detail)
                .font(.caption)
                .foregroundStyle(.secondary)

            if transcription.isReady {
                Label("Ready · runs privately on this Mac", systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)

                Picker("Language", selection: $transcription.selectedLanguageCode) {
                    ForEach(transcription.languages) { language in
                        Text(language.name).tag(language.code)
                    }
                }
                .disabled(transcription.isTranscribing)

                HStack {
                    Button("Transcribe") { startTranscription() }
                        .buttonStyle(.borderedProminent)
                        .disabled(transcription.isTranscribing)
                    Spacer()
                    Button("Remove model", role: .destructive) {
                        confirmsRemoval = true
                    }
                    .disabled(transcription.isTranscribing)
                }
            } else if transcription.isDownloading {
                Text("Downloading \(transcription.selectedModel.name) (\(transcription.selectedModel.sizeLabel))")
                    .font(.callout)
                ProgressView(value: transcription.downloadProgress)
                Button("Cancel") { transcription.cancelSetup() }
            } else {
                Text("Download this Whisper model once, then transcribe recordings offline without an API key.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Download & Transcribe") {
                    Task {
                        await transcription.setup()
                        if transcription.isReady {
                            startTranscription()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
            }

            if transcription.isTranscribing {
                VStack(alignment: .leading, spacing: 6) {
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
                            .disabled(transcription.isCancellingTranscription)
                    }
                }
            }

            if !transcription.isTranscribing {
                HStack(alignment: .firstTextBaseline) {
                    Text(transcription.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if transcription.lastOutputURL != nil {
                        Button("Show file") { transcription.revealTranscript() }
                            .controlSize(.small)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 390)
        .alert("Remove the local model?", isPresented: $confirmsRemoval) {
            Button("Remove", role: .destructive) { transcription.removeModel() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This frees \(transcription.selectedModel.sizeLabel). You can download it again later.")
        }
    }

    private func startTranscription() {
        Task {
            if await transcription.transcribe(audioURL) != nil {
                onFinished()
            }
        }
    }
}
