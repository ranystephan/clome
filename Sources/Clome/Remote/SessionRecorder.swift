// SessionRecorder.swift
// Clome — Records terminal sessions as JSONL for playback from iOS.

import Foundation

@MainActor
final class SessionRecorder {

    private(set) var isRecording = false
    private(set) var currentRecordingId: String?
    private var recordingStartTime: Date?
    private var frameCount = 0
    private var fileHandle: FileHandle?
    private var keyframeCounter = 0
    private let keyframeInterval = 900 // ~30s at 30fps

    private let encoder = JSONEncoder()

    private var recordingsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Clome/recordings", isDirectory: true)
    }

    // MARK: - Recording Lifecycle

    func startRecording(name: String?) -> String {
        let id = UUID().uuidString
        currentRecordingId = id
        recordingStartTime = Date()
        frameCount = 0
        keyframeCounter = 0
        isRecording = true

        // Ensure directory exists
        try? FileManager.default.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)

        let filePath = recordingsDirectory.appendingPathComponent("\(id).jsonl")

        // Write metadata as first line
        let meta = RecordingMeta(id: id, name: name ?? "Recording \(formattedDate())", startedAt: Date())
        if let metaLine = try? encoder.encode(meta) {
            FileManager.default.createFile(atPath: filePath.path, contents: metaLine)
            fileHandle = try? FileHandle(forWritingTo: filePath)
            fileHandle?.seekToEndOfFile()
            fileHandle?.write("\n".data(using: .utf8)!)
        }

        return id
    }

    func stopRecording() {
        isRecording = false
        fileHandle?.closeFile()
        fileHandle = nil

        // Update metadata with duration
        if let id = currentRecordingId, let start = recordingStartTime {
            let metaPath = recordingsDirectory.appendingPathComponent("\(id).meta.json")
            let meta = RecordingMeta(id: id, name: "Recording", startedAt: start, duration: Date().timeIntervalSince(start), frameCount: frameCount)
            if let data = try? encoder.encode(meta) {
                try? data.write(to: metaPath)
            }
        }

        currentRecordingId = nil
        recordingStartTime = nil
    }

    // MARK: - Frame Capture

    func captureScreen(_ screen: TerminalScreenState) {
        guard isRecording, let start = recordingStartTime else { return }
        let frame = RecordingFrame(
            timestamp: Date().timeIntervalSince(start),
            screen: screen,
            delta: nil
        )
        writeFrame(frame)
        keyframeCounter = 0
    }

    func captureDelta(_ delta: TerminalDelta) {
        guard isRecording, let start = recordingStartTime else { return }
        keyframeCounter += 1
        let frame = RecordingFrame(
            timestamp: Date().timeIntervalSince(start),
            screen: nil,
            delta: delta
        )
        writeFrame(frame)
    }

    private func writeFrame(_ frame: RecordingFrame) {
        guard let data = try? encoder.encode(frame) else { return }
        fileHandle?.write(data)
        fileHandle?.write("\n".data(using: .utf8)!)
        frameCount += 1
    }

    // MARK: - Listing

    func listRecordings() -> [RecordingInfo] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: recordingsDirectory, includingPropertiesForKeys: nil) else {
            return []
        }

        var recordings: [RecordingInfo] = []

        for metaFile in files where metaFile.pathExtension == "json" && metaFile.lastPathComponent.hasSuffix(".meta.json") {
            guard let data = try? Data(contentsOf: metaFile),
                  let meta = try? JSONDecoder().decode(RecordingMeta.self, from: data) else { continue }

            recordings.append(RecordingInfo(
                id: meta.id,
                name: meta.name,
                startedAt: meta.startedAt,
                duration: meta.duration,
                frameCount: meta.frameCount ?? 0
            ))
        }

        return recordings.sorted { $0.startedAt > $1.startedAt }
    }

    // MARK: - Playback

    func playback(recordingId: String, from: TimeInterval?) -> RecordingDataChunk {
        let filePath = recordingsDirectory.appendingPathComponent("\(recordingId).jsonl")

        guard let data = try? String(contentsOf: filePath, encoding: .utf8) else {
            return RecordingDataChunk(recordingId: recordingId, frames: [], isComplete: true)
        }

        let lines = data.components(separatedBy: "\n")
        var frames: [RecordingFrame] = []
        let decoder = JSONDecoder()

        for line in lines.dropFirst() { // skip metadata line
            guard !line.isEmpty,
                  let lineData = line.data(using: .utf8),
                  let frame = try? decoder.decode(RecordingFrame.self, from: lineData) else { continue }

            if let fromTs = from, frame.timestamp < fromTs { continue }
            frames.append(frame)

            // Send in chunks of 200 frames max
            if frames.count >= 200 { break }
        }

        return RecordingDataChunk(recordingId: recordingId, frames: frames, isComplete: true)
    }

    // MARK: - Helpers

    private func formattedDate() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: Date())
    }
}

private struct RecordingMeta: Codable {
    let id: String
    let name: String
    let startedAt: Date
    var duration: TimeInterval?
    var frameCount: Int?
}
