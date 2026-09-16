import Foundation

/// `base` raised to `exponent`, modulo `modulus`, over big-endian byte arrays.
/// Native Swift with no dependency on any external process or big-integer
/// library: the Apple screen-sharing authentication needs a Diffie-Hellman
/// modular exponentiation, and the whole project is clean-room and
/// dependency-free. Correctness over speed -- it runs once per unlock.
///
/// Inputs are big-endian, unsigned, and may carry leading zero bytes. The
/// result is normalised to minimal big-endian form (no leading zero bytes; a
/// zero result is the empty array). A caller that needs a fixed width -- the
/// RFB client needs exactly `keyLen` bytes -- left-pads it itself.
///
/// A modulus of zero or one reduces everything to zero.
public func modularExponentiation(base: [UInt8], exponent: [UInt8], modulus: [UInt8]) -> [UInt8] {
    let m = BigEndianInt.normalized(modulus)
    guard BigEndianInt.compare(m, [1]) == .orderedDescending else {
        return []
    }
    // Reduce the base first: it may be larger than the modulus, and every
    // step below assumes its operands are already below it.
    var result: [UInt8] = [1]
    let reducedBase = BigEndianInt.reduce(BigEndianInt.normalized(base), modulus: m)
    let exp = BigEndianInt.normalized(exponent)
    for bit in BigEndianInt.bitsHighToLow(exp) {
        result = BigEndianInt.mulMod(result, result, m)
        if bit {
            result = BigEndianInt.mulMod(result, reducedBase, m)
        }
    }
    return BigEndianInt.normalized(result)
}

/// Big-endian unsigned integer arithmetic, only what the exponentiation above
/// needs: normalisation, comparison, add, subtract, reduce, and a
/// double-and-add modular multiply that never divides.
enum BigEndianInt {
    /// Strips leading zero bytes. Zero becomes the empty array, so every value
    /// has exactly one representation and comparisons need no special cases.
    static func normalized(_ value: [UInt8]) -> [UInt8] {
        var start = 0
        while start < value.count && value[start] == 0 {
            start += 1
        }
        return Array(value[start...])
    }

    /// Both inputs must already be normalised.
    static func compare(_ a: [UInt8], _ b: [UInt8]) -> ComparisonResult {
        let a = normalized(a)
        let b = normalized(b)
        if a.count != b.count {
            return a.count < b.count ? .orderedAscending : .orderedDescending
        }
        for (x, y) in zip(a, b) where x != y {
            return x < y ? .orderedAscending : .orderedDescending
        }
        return .orderedSame
    }

    static func add(_ a: [UInt8], _ b: [UInt8]) -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(Swift.max(a.count, b.count) + 1)
        var carry = 0
        var i = a.count - 1
        var j = b.count - 1
        while i >= 0 || j >= 0 || carry != 0 {
            let x = i >= 0 ? Int(a[i]) : 0
            let y = j >= 0 ? Int(b[j]) : 0
            let sum = x + y + carry
            result.append(UInt8(sum & 0xFF))
            carry = sum >> 8
            i -= 1
            j -= 1
        }
        return normalized(result.reversed())
    }

    /// `a - b`, and the caller guarantees `a >= b`.
    static func subtract(_ a: [UInt8], _ b: [UInt8]) -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(a.count)
        var borrow = 0
        var i = a.count - 1
        var j = b.count - 1
        while i >= 0 {
            let x = Int(a[i])
            let y = j >= 0 ? Int(b[j]) : 0
            var diff = x - y - borrow
            if diff < 0 {
                diff += 256
                borrow = 1
            } else {
                borrow = 0
            }
            result.append(UInt8(diff))
            i -= 1
            j -= 1
        }
        return normalized(result.reversed())
    }

    /// `value` mod `modulus`, by Horner over the value's own bytes: the running
    /// remainder is shifted up one byte, the next byte folded in, and the
    /// modulus subtracted until it fits again. No division, and every subtract
    /// is on numbers already below the modulus.
    static func reduce(_ value: [UInt8], modulus: [UInt8]) -> [UInt8] {
        var remainder: [UInt8] = []
        for byte in normalized(value) {
            // remainder = remainder * 256 + byte
            if remainder.isEmpty {
                remainder = byte == 0 ? [] : [byte]
            } else {
                remainder.append(byte)
                remainder = normalized(remainder)
            }
            while compare(remainder, modulus) != .orderedAscending {
                remainder = subtract(remainder, modulus)
            }
        }
        return remainder
    }

    /// `(a * b) mod m`, with `a` and `b` already below `m`. Double-and-add over
    /// the bits of `b`, keeping the accumulator reduced the whole way, so no
    /// long division is ever needed.
    static func mulMod(_ a: [UInt8], _ b: [UInt8], _ m: [UInt8]) -> [UInt8] {
        var result: [UInt8] = []
        let addend = normalized(a)
        for bit in bitsHighToLow(normalized(b)) {
            result = addMod(result, result, m)
            if bit {
                result = addMod(result, addend, m)
            }
        }
        return result
    }

    /// `(a + b) mod m`, with `a` and `b` already below `m`, so at most one
    /// subtraction brings the sum back below it.
    static func addMod(_ a: [UInt8], _ b: [UInt8], _ m: [UInt8]) -> [UInt8] {
        var sum = add(a, b)
        if compare(sum, m) != .orderedAscending {
            sum = subtract(sum, m)
        }
        return sum
    }

    /// The bits of a normalised big-endian value, most significant first. An
    /// empty value (zero) yields no bits.
    static func bitsHighToLow(_ value: [UInt8]) -> [Bool] {
        let value = normalized(value)
        guard let first = value.first else {
            return []
        }
        var bits: [Bool] = []
        bits.reserveCapacity(value.count * 8)
        // Skip the leading zero bits of the most significant byte so the walk
        // starts at the true high bit.
        var started = false
        for shift in stride(from: 7, through: 0, by: -1) {
            let bit = (first >> UInt8(shift)) & 1 == 1
            if bit { started = true }
            if started { bits.append(bit) }
        }
        for byte in value.dropFirst() {
            for shift in stride(from: 7, through: 0, by: -1) {
                bits.append((byte >> UInt8(shift)) & 1 == 1)
            }
        }
        return bits
    }
}
