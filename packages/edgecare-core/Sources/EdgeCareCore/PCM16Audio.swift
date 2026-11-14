import Foundation

public enum PCM16Audio {
    /// Mono, signed little-endian PCM power. Empty or partial samples are invalid.
    public static func power(_ data: Data) -> Float? {
        guard !data.isEmpty, data.count.isMultiple(of: 2) else { return nil }
        return data.withUnsafeBytes { bytes in
            var sum: Double = 0
            for offset in stride(from: 0, to: data.count, by: 2) {
                let sample = Double(Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: Int16.self))) / 32768
                sum += sample * sample
            }
            return Float(10 * log10(max(sum / Double(data.count / 2), 0.000000001)))
        }
    }
    public static func wave(_ pcm: Data) throws -> Data {
        guard power(pcm) != nil, pcm.count <= 2 * 1024 * 1024 else { throw CoreError.invalidResponse }
        var data = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        append(UInt32(pcm.count + 36)); data.append(Data("WAVEfmt ".utf8)); append(UInt32(16))
        append(UInt16(1)); append(UInt16(1)); append(UInt32(24000)); append(UInt32(48000))
        append(UInt16(2)); append(UInt16(16)); data.append(Data("data".utf8)); append(UInt32(pcm.count)); data.append(pcm)
        return data
    }
}
