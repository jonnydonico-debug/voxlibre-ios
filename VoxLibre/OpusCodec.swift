import Foundation
import AVFoundation

/// Decodes the ring's raw-Opus recordings with Apple's built-in Opus decoder
/// (AVAudioConverter) → WAV cache → AVAudioPlayer.
///
/// Ring framing: [seq:u8][len:u8][opus packet]…, 48 kHz mono (60 ms packets).
enum OpusAudio {
    enum DecodeError: Error, LocalizedError {
        case noPackets, converter, failed(String)
        var errorDescription: String? {
            switch self {
            case .noPackets: return "no Opus packets in file"
            case .converter: return "Opus decoder unavailable"
            case .failed(let m): return m
            }
        }
    }

    static let sampleRate = 48_000.0

    static func packets(_ d: Data) -> [Data] {
        let b = [UInt8](d)
        var off = 0
        var out: [Data] = []
        while off + 2 <= b.count {
            let len = Int(b[off + 1])
            guard off + 2 + len <= b.count else { break }
            if len > 0 { out.append(Data(b[(off + 2)..<(off + 2 + len)])) }
            off += 2 + len
        }
        return out
    }

    /// Samples per packet from the Opus TOC byte (RFC 6716 §3.1).
    static func samplesPerPacket(_ p: Data) -> UInt32 {
        let toc = p[p.startIndex]
        let cfg = Int(toc >> 3)
        let frameUs: Int
        switch cfg {
        case 0...11: frameUs = [10_000, 20_000, 40_000, 60_000][cfg % 4]
        case 12...15: frameUs = [10_000, 20_000][cfg % 2]
        default: frameUs = [2_500, 5_000, 10_000, 20_000][cfg % 4]
        }
        var count = 1
        switch toc & 3 {
        case 1, 2: count = 2
        case 3: count = p.count > 1 ? max(Int(p[p.startIndex + 1] & 0x3F), 1) : 1
        default: count = 1
        }
        return UInt32(frameUs * count * 48 / 1000)
    }

    /// Decode a ring .opus file to mono Float32 samples at 48 kHz.
    static func decode(_ d: Data) throws -> [Float] {
        let pkts = packets(d)
        guard let first = pkts.first else { throw DecodeError.noPackets }
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatOpus, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: samplesPerPacket(first), mBytesPerFrame: 0,
            mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
        guard let inFmt = AVAudioFormat(streamDescription: &asbd),
              let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                         channels: 1, interleaved: false),
              let conv = AVAudioConverter(from: inFmt, to: outFmt) else { throw DecodeError.converter }

        let maxLen = pkts.map(\.count).max() ?? 1
        var idx = 0
        var samples: [Float] = []
        samples.reserveCapacity(pkts.count * 2880)
        let chunkCap: AVAudioFrameCount = 2880 * 64

        while true {
            guard let chunk = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: chunkCap) else {
                throw DecodeError.converter
            }
            var err: NSError?
            let st = conv.convert(to: chunk, error: &err) { _, status in
                guard idx < pkts.count else {
                    status.pointee = .endOfStream
                    return nil
                }
                let p = pkts[idx]
                idx += 1
                let cb = AVAudioCompressedBuffer(format: inFmt, packetCapacity: 1, maximumPacketSize: maxLen)
                p.withUnsafeBytes { cb.data.copyMemory(from: $0.baseAddress!, byteCount: p.count) }
                cb.byteLength = UInt32(p.count)
                cb.packetCount = 1
                cb.packetDescriptions?[0] = AudioStreamPacketDescription(
                    mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(p.count))
                status.pointee = .haveData
                return cb
            }
            if st == .error { throw DecodeError.failed(err?.localizedDescription ?? "decode error") }
            if chunk.frameLength > 0, let ch = chunk.floatChannelData?[0] {
                samples.append(contentsOf: UnsafeBufferPointer(start: ch, count: Int(chunk.frameLength)))
            }
            if st != .haveData { break }
        }
        return samples
    }

    static func writeWav(_ samples: [Float], to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                         frameCapacity: AVAudioFrameCount(max(samples.count, 1))) else { return }
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buf.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        try file.write(from: buf)
    }

    static func wavDurationMs(_ url: URL) -> Int? {
        guard FileManager.default.fileExists(atPath: url.path),
              let f = try? AVAudioFile(forReading: url), f.length > 0 else { return nil }
        return Int(Double(f.length) * 1000 / f.fileFormat.sampleRate)
    }
}

