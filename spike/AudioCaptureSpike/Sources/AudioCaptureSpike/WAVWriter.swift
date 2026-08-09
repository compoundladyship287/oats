import AVFoundation
import Accelerate
import Foundation

/// Accumulates PCM in memory and writes a WAV on close, while tracking peak and
/// RMS so callers can prove the stream carried real audio.
///
/// Spike-grade on purpose: the real app needs a lock-free ring buffer drained by
/// a writer thread, because `AVAudioFile.write` allocates and must never be
/// called from a Core Audio IOProc.
final class WAVWriter {
    let url: URL
    private let format: AVAudioFormat
    private let lock = NSLock()
    private var samples: [[Float]]
    private(set) var frameCount: AVAudioFrameCount = 0
    private(set) var peak: Float = 0
    private var sumOfSquares: Double = 0
    private var sampleCount: Double = 0
    /// Reusable de-interleave destination, so the audio thread never allocates.
    private var scratch: [Float] = []

    /// `expectedSeconds` preallocates storage so the audio thread never triggers
    /// an array reallocation mid-capture.
    init(url: URL, format: AVAudioFormat, expectedSeconds: Double = 120) {
        self.url = url
        self.format = format
        let capacity = Int(format.sampleRate * expectedSeconds)
        self.samples = (0..<Int(format.channelCount)).map { _ in
            var storage = [Float]()
            storage.reserveCapacity(capacity)
            return storage
        }
    }

    /// Called from a Core Audio IOProc, so everything here is a bulk operation:
    /// per-sample Swift loops are slow enough to risk stalling the audio thread.
    ///
    /// Handles both memory layouts. The system-audio tap hands back *interleaved*
    /// stereo, where `floatChannelData` is a single pointer to be read with
    /// `buffer.stride`; the microphone hands back non-interleaved, one pointer
    /// per channel. Assuming non-interleaved for both silently captured every
    /// other sample at half speed and produced transcripts that looked like a
    /// bad ASR model rather than a layout bug.
    func append(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        let channels = min(Int(buffer.format.channelCount), samples.count)

        lock.lock()
        defer { lock.unlock() }

        if buffer.format.isInterleaved {
            if scratch.count < frames { scratch = [Float](repeating: 0, count: frames) }
            let stride = buffer.stride
            for channel in 0..<channels {
                scratch.withUnsafeMutableBufferPointer { destination in
                    cblas_scopy(
                        Int32(frames),
                        channelData[0].advanced(by: channel), Int32(stride),
                        destination.baseAddress!, 1)
                }
                scratch.withUnsafeBufferPointer { source in
                    accumulate(channel: channel, from: source.baseAddress!, frames: frames)
                }
            }
        } else {
            for channel in 0..<channels {
                accumulate(channel: channel, from: channelData[channel], frames: frames)
            }
        }
        frameCount += AVAudioFrameCount(frames)
    }

    /// Caller must hold `lock`.
    private func accumulate(channel: Int, from pointer: UnsafePointer<Float>, frames: Int) {
        var channelPeak: Float = 0
        vDSP_maxmgv(pointer, 1, &channelPeak, vDSP_Length(frames))
        if channelPeak > peak { peak = channelPeak }

        var meanSquare: Float = 0
        vDSP_measqv(pointer, 1, &meanSquare, vDSP_Length(frames))
        sumOfSquares += Double(meanSquare) * Double(frames)
        sampleCount += Double(frames)

        samples[channel].append(contentsOf: UnsafeBufferPointer(start: pointer, count: frames))
    }

    var rms: Float {
        lock.lock()
        defer { lock.unlock() }
        guard sampleCount > 0 else { return 0 }
        return Float((sumOfSquares / sampleCount).squareRoot())
    }

    var durationSeconds: Double {
        Double(frameCount) / format.sampleRate
    }

    /// dBFS is the useful number here: real speech lands around -40…-10 dBFS,
    /// while a broken tap sits at -inf.
    static func dBFS(_ amplitude: Float) -> String {
        guard amplitude > 0 else { return "-inf" }
        return String(format: "%.1f", 20 * log10(amplitude))
    }

    /// Writes a standard 16-bit PCM RIFF/WAVE file by hand.
    ///
    /// `AVAudioFile` was the obvious choice and it failed with a bare `-50`
    /// paramErr converting our non-interleaved float32 capture format into a
    /// WAV container. Hand-rolling the header removes the format negotiation
    /// entirely, and 16-bit interleaved is both universally playable and the
    /// shape ASR wants downstream anyway.
    func close() throws {
        lock.lock()
        let captured = samples
        let frames = Int(frameCount)
        lock.unlock()

        guard frames > 0 else {
            throw CaptureError.message("Nothing captured for \(url.lastPathComponent)")
        }

        let channels = max(1, min(captured.count, Int(format.channelCount)))
        let sampleRate = UInt32(format.sampleRate)
        let bitsPerSample: UInt16 = 16
        let bytesPerFrame = Int(bitsPerSample / 8) * channels
        let dataBytes = frames * bytesPerFrame

        var output = Data(capacity: 44 + dataBytes)
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { output.append(contentsOf: $0) }
        }

        output.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + dataBytes))
        output.append(contentsOf: Array("WAVE".utf8))
        output.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16))  // PCM chunk size
        append(UInt16(1))  // format: PCM integer
        append(UInt16(channels))
        append(sampleRate)
        append(UInt32(Int(sampleRate) * bytesPerFrame))  // byte rate
        append(UInt16(bytesPerFrame))  // block align
        append(bitsPerSample)
        output.append(contentsOf: Array("data".utf8))
        append(UInt32(dataBytes))

        for frame in 0..<frames {
            for channel in 0..<channels {
                let source = captured[channel]
                let value = frame < source.count ? source[frame] : 0
                let clamped = max(-1, min(1, value))
                append(Int16(clamped * 32767))
            }
        }

        try output.write(to: url)
    }
}
