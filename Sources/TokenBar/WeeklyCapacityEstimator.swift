import Foundation

struct WeeklyCapacityEstimator {
    static func update(
        history: inout WeeklyCapacityHistory,
        window: LimitWindow,
        observedTokens: Int64,
        observedCostUSD: Double,
        observedAt: Date,
        source: String
    ) -> WeeklyTokenCapacityEstimate? {
        guard let minutes = window.windowMinutes,
              let resetsAt = window.resetsAt,
              minutes == 7 * 24 * 60,
              window.usedPercent.isFinite,
              window.usedPercent >= 0,
              observedCostUSD.isFinite, observedCostUSD > 0, observedTokens > 0
        else {
            return nil
        }

        let startedAt = resetsAt.addingTimeInterval(-Double(minutes) * 60)
        let windowKey = "\(window.id):\(Int(startedAt.timeIntervalSince1970.rounded()))"
        let sample = WeeklyCapacitySample(
            windowKey: windowKey,
            windowStartedAt: startedAt,
            resetsAt: resetsAt,
            observedAt: observedAt,
            usedPercent: window.usedPercent,
            observedTokens: observedTokens,
            equivalentTokens: window.usedPercent > 0
                ? Double(observedTokens) * 100 / window.usedPercent : 0,
            source: source,
            equivalentValueUSD: window.usedPercent > 0 ? observedCostUSD * 100 / window.usedPercent : nil
        )

        // Match the account baseline's two-second tolerance. Exact timestamp keys
        // can split one quota window into several priors, including in saved history.
        var uniqueSamples: [WeeklyCapacitySample] = []
        for existing in history.samples.sorted(by: { $0.observedAt > $1.observedAt }) {
            if !uniqueSamples.contains(where: { sameWindow($0, existing) }) {
                uniqueSamples.append(existing)
            }
        }
        history.samples = uniqueSamples

        if observedTokens > 0, window.usedPercent > 0 {
            if sample.equivalentTokens.isFinite, sample.equivalentTokens > 0 {
                if let index = history.samples.firstIndex(where: {
                    sameWindow($0, sample)
                }) {
                    history.samples[index] = sample
                } else {
                    history.samples.append(sample)
                }
            }
        }

        history.samples = history.samples
            .filter { observedAt.timeIntervalSince($0.resetsAt) < 70 * 24 * 60 * 60 }
            .sorted { $0.observedAt > $1.observedAt }
        if history.samples.count > 12 {
            history.samples.removeLast(history.samples.count - 12)
        }

        let priorValues = history.samples.compactMap { prior -> Double? in
            guard !sameWindow(prior, sample),
                  prior.source == source,
                  prior.usedPercent >= 10,
                  let value = prior.equivalentValueUSD,
                  value.isFinite, value > 0
            else {
                return nil
            }
            return value
        }
        let prior = robustCenter(priorValues)
        let current = history.samples.first(where: {
            sameWindow($0, sample)
        }).flatMap { sample in
            sample.usedPercent >= 3 ? sample.equivalentValueUSD : nil
        }

        let equivalentValueUSD: Double?
        switch (prior, current) {
        case let (.some(prior), .some(current)):
            let currentWeight = min(1, max(0.1, window.usedPercent / 50))
            equivalentValueUSD = exp(
                log(prior) * (1 - currentWeight) + log(current) * currentWeight
            )
        case let (.some(prior), .none):
            equivalentValueUSD = prior
        case let (.none, .some(current)):
            equivalentValueUSD = current
        case (.none, .none):
            equivalentValueUSD = nil
        }

        guard let equivalentValueUSD,
              equivalentValueUSD.isFinite,
              equivalentValueUSD > 0
        else {
            return nil
        }
        return WeeklyTokenCapacityEstimate(
            usedPercent: window.usedPercent,
            observedTokens: observedTokens,
            equivalentTokens: equivalentValueUSD * Double(observedTokens) / observedCostUSD,
            equivalentValueUSD: equivalentValueUSD
        )
    }

    private static func sameWindow(_ lhs: WeeklyCapacitySample, _ rhs: WeeklyCapacitySample) -> Bool {
        let lhsID = lhs.windowKey.prefix(upTo: lhs.windowKey.lastIndex(of: ":") ?? lhs.windowKey.endIndex)
        let rhsID = rhs.windowKey.prefix(upTo: rhs.windowKey.lastIndex(of: ":") ?? rhs.windowKey.endIndex)
        return lhsID == rhsID
            && lhs.source == rhs.source
            && abs(lhs.windowStartedAt.timeIntervalSince(rhs.windowStartedAt)) < 2
            && abs(lhs.resetsAt.timeIntervalSince(rhs.resetsAt)) < 2
    }

    private static func robustCenter(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let center = median(values)
        guard values.count >= 4 else { return center }
        let mad = median(values.map { abs($0 - center) })
        let tolerance = max(center * 0.15, mad * 4.4478)
        let filtered = values.filter { abs($0 - center) <= tolerance }
        return filtered.isEmpty ? center : median(filtered)
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }
}
