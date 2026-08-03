import Foundation

/// Detects single-sample spikes that survived frame validation.
///
/// The 0x55/0x61 frame carries no checksum, so a corrupted frame whose bytes
/// happen to look plausible is accepted. Observed live at roughly 1 sample in
/// 4000: a lone reading of 6.05 g and 789 °/s sitting between two neighbours
/// that were at rest and identical to each other.
///
/// The discriminator is **isolation**, not magnitude. During real motion each
/// sample differs from the one before *and* the one after, because the body has
/// inertia. A corrupt sample differs from both neighbours while those neighbours
/// agree closely with each other — a shape real physics cannot produce at 200 Hz.
/// That keeps genuine cast transients, however violent, out of the net.
public struct GlitchFilter {

    /// A sample must differ from both neighbours by more than this to qualify.
    public static let accStepG = 1.0
    public static let gyroStepDPS = 100.0
    /// ...while the neighbours themselves agree within this much.
    public static let neighbourAgreementRatio = 0.25

    /// Drop detected glitches instead of only counting them.
    public var dropsGlitches: Bool

    public private(set) var glitchCount = 0
    public private(set) var totalCount = 0

    private var window: [SensorReading] = []

    public init(dropsGlitches: Bool = false) {
        self.dropsGlitches = dropsGlitches
    }

    /// Feeds one sample, returning whichever samples are now settled.
    ///
    /// Output lags input by one sample, since judging a reading needs the one
    /// after it.
    public mutating func push(_ reading: SensorReading) -> [SensorReading] {
        totalCount += 1
        window.append(reading)

        guard window.count >= 3 else {
            // The very first sample has no left neighbour; release it once a
            // second arrives so nothing is held indefinitely.
            return window.count == 2 ? [window[0]] : []
        }

        let candidate = window[1]
        let isGlitch = Self.isIsolatedSpike(previous: window[0],
                                            candidate: candidate,
                                            next: window[2])
        window.removeFirst()

        if isGlitch {
            glitchCount += 1
            return dropsGlitches ? [] : [candidate]
        }
        return [candidate]
    }

    public mutating func push(_ readings: [SensorReading]) -> [SensorReading] {
        readings.flatMap { push($0) }
    }

    /// Releases the final buffered sample at end of session.
    public mutating func flush() -> [SensorReading] {
        let tail = window.count > 1 ? [window[window.count - 1]] : window
        window.removeAll()
        return tail
    }

    public var glitchPercent: Double {
        totalCount == 0 ? 0 : Double(glitchCount) / Double(totalCount) * 100
    }

    // MARK: - Detection

    static func isIsolatedSpike(previous: SensorReading,
                                candidate: SensorReading,
                                next: SensorReading) -> Bool {
        spikes(previous.accX, candidate.accX, next.accX, step: accStepG)
            || spikes(previous.accY, candidate.accY, next.accY, step: accStepG)
            || spikes(previous.accZ, candidate.accZ, next.accZ, step: accStepG)
            || spikes(previous.gyroX, candidate.gyroX, next.gyroX, step: gyroStepDPS)
            || spikes(previous.gyroY, candidate.gyroY, next.gyroY, step: gyroStepDPS)
            || spikes(previous.gyroZ, candidate.gyroZ, next.gyroZ, step: gyroStepDPS)
    }

    private static func spikes(_ a: Double, _ b: Double, _ c: Double, step: Double) -> Bool {
        abs(b - a) > step
            && abs(b - c) > step
            && abs(a - c) < step * neighbourAgreementRatio
    }
}
