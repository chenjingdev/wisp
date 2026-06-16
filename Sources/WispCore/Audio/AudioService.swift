import AVFoundation

final class AudioService: AudioServicing {
    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "dev.chenjing.wisp.audio")
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private var startedAt: Date?

    static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false
    )!

    func startRecording(onLevel: @escaping (AudioLevel) -> Void) throws {
        guard !engine.isRunning else { throw WispError.audioSetupFailed }
        queue.sync { samples.removeAll() }
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0,
              let converter = AVAudioConverter(from: inputFormat, to: Self.targetFormat)
        else { throw WispError.audioSetupFailed }
        queue.sync { self.converter = converter }

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.consume(buffer: buffer, onLevel: onLevel)
        }
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            throw WispError.audioSetupFailed
        }
        startedAt = Date()
    }

    private func consume(buffer: AVAudioPCMBuffer, onLevel: @escaping (AudioLevel) -> Void) {
        let converter = queue.sync { self.converter }
        guard let converter else { return }
        let ratio = Self.targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.targetFormat, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0, let ch = out.floatChannelData else { return }
        let chunk = Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
        queue.sync { samples.append(contentsOf: chunk) }
        onLevel(AudioLevel(rms: AudioMath.rms(chunk), peak: AudioMath.peak(chunk)))
    }

    func stopRecording() throws -> RecordingResult {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        queue.sync { converter = nil }
        let captured = queue.sync { samples }
        let duration = Date().timeIntervalSince(startedAt ?? Date())
        return RecordingResult(samples: captured, duration: duration)
    }

    func cancelRecording() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        queue.sync { converter = nil }
        queue.sync { samples.removeAll() }
    }
}
