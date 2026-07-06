// RingBuffer.swift
// RunBotCore
import Foundation

/// Fixed-capacity circular buffer whose `values` property returns elements oldest-first.
public struct RingBuffer {
    /// Backing store; slots are overwritten in round-robin order.
    private var storage: [Double]
    /// Index of the oldest element (next write position).
    private var head = 0

    /// Creates a new ring buffer pre-filled with `fill`.
    /// - Parameters:
    ///   - capacity: Number of slots in the buffer.
    ///   - fill: Initial value for every slot (default `0`).
    public init(capacity: Int, fill: Double = 0) {
        precondition(capacity > 0, "RingBuffer capacity must be positive")
        self.storage = Array(repeating: fill, count: capacity)
    }

    /// Overwrites the oldest slot with `value` in O(1).
    /// - Parameter value: The new sample to insert.
    public mutating func append(_ value: Double) {
        storage[head] = value
        head = (head + 1) % storage.count
    }

    /// Elements in insertion order, oldest first.
    /// `head` is always in `[0, capacity)` — guaranteed by the modulo in `append()`.
    public var values: [Double] { Array(storage[head...] + storage[..<head]) }
}
