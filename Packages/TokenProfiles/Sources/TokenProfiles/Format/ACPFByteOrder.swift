import Foundation

/// Endianness helpers used by the ACPF reader/writer. On-disk integers are always
/// little-endian; Apple's targets (Apple Silicon, Intel) are also little-endian, so the
/// on-the-wire bytes match host order and the explicit `littleEndian` conversions below
/// compile to no-ops on supported hardware. We still funnel through them so the format
/// stays correct if KeyType ever runs on a big-endian host.
extension Data {
    @inline(__always)
    mutating func appendLE(_ value: UInt8) {
        append(value)
    }

    @inline(__always)
    mutating func appendLE(_ value: UInt16) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { self.append(contentsOf: $0) }
    }

    @inline(__always)
    mutating func appendLE(_ value: UInt32) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { self.append(contentsOf: $0) }
    }

    @inline(__always)
    mutating func appendLE(_ value: UInt64) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { self.append(contentsOf: $0) }
    }

    @inline(__always)
    mutating func appendLE(_ value: Int32) {
        appendLE(UInt32(bitPattern: value))
    }

    /// Pad the data with zeros until its length is a multiple of `alignment`.
    @inline(__always)
    mutating func padToMultiple(of alignment: Int) {
        let remainder = count % alignment
        guard remainder != 0 else { return }
        append(contentsOf: Array(repeating: UInt8(0), count: alignment - remainder))
    }
}

extension UnsafeRawBufferPointer {
    @inline(__always)
    func loadLEUInt16(at offset: Int) -> UInt16 {
        UInt16(littleEndian: loadUnaligned(fromByteOffset: offset, as: UInt16.self))
    }

    @inline(__always)
    func loadLEUInt32(at offset: Int) -> UInt32 {
        UInt32(littleEndian: loadUnaligned(fromByteOffset: offset, as: UInt32.self))
    }

    @inline(__always)
    func loadLEUInt64(at offset: Int) -> UInt64 {
        UInt64(littleEndian: loadUnaligned(fromByteOffset: offset, as: UInt64.self))
    }

    @inline(__always)
    func loadLEInt32(at offset: Int) -> Int32 {
        Int32(bitPattern: loadLEUInt32(at: offset))
    }
}
