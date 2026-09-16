import Foundation

/// SplitMix64: a small, fast, fully deterministic generator used for template instantiation so that the same
/// seed always yields the same question instance.
public struct SeededRandom: RandomNumberGenerator, Sendable {
    private var state: UInt64

    /// Creates a generator from a raw 64-bit state.
    public init(state: UInt64) {
        self.state = state
    }

    /// Creates a generator from a seed string. Hex strings (the app's 8-character seeds) are decoded directly;
    /// anything else is hashed (FNV-1a) so arbitrary strings still seed deterministically.
    public init(seed: String) {
        self.init(state: Self.state(fromSeed: seed))
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform double in `[0, 1)`.
    public mutating func nextUnit() -> Double {
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }

    /// Uniform integer in the closed range.
    public mutating func nextInt(in range: ClosedRange<Int>) -> Int {
        Int.random(in: range, using: &self)
    }

    /// Uniform double in the closed range.
    public mutating func nextDouble(in range: ClosedRange<Double>) -> Double {
        range.lowerBound + nextUnit() * (range.upperBound - range.lowerBound)
    }

    /// The 64-bit state a seed string maps to.
    public static func state(fromSeed seed: String) -> UInt64 {
        let trimmed = seed.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed.count <= 16, let value = UInt64(trimmed, radix: 16) {
            return value
        }
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in trimmed.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0100_0000_01B3
        }
        return hash
    }

    /// A fresh 8-character lowercase hex seed from the system generator.
    public static func newSeedString() -> String {
        let value = UInt32.random(in: UInt32.min...UInt32.max)
        return String(format: "%08x", value)
    }
}
