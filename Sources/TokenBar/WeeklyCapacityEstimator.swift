import Foundation

struct WeeklyCapacityEstimator {
    static func update(
        history: inout WeeklyCapacityHistory,
        window: LimitWindow,
        observedTokens: Int64,
        observedAt: Date,
        source: String
    ) -> WeeklyTokenCapacityEstimate? {
        guard let minutes = window.windowMinutes,
              let resetsAt = window.resetsAt,
              minutes == 7 * 24 * 60,
              window.usedPercent.isFinite,
              window.usedPercent >= 0
        else {
            return nil
        }

        let startedAt = resetsAt.addingTimeInterval(-Double(minutes) * 60)
        let windowKey = "\(window.id):\(Int(startedAt.timeIntervalSince1970.rounded()))"
        if observedTokens > 0, window.usedPercent > 0 {
            let implied = Double(observedTokens) * 100 / window.usedPercent
            if implied.isFinite, implied > 0 {
                let sample = WeeklyCapacitySample(
                    windowKey: windowKey,
                    windowStartedAt: startedAt,
                    resetsAt: resetsAt,
                    observedAt: observedAt,
                    usedPercent: window.usedPercent,
                    observedTokens: observedTokens,
                    equivalentTokens: implied,
                    source: source
                )
                if let index = history.samples.firstIndex(where: {
                    $0.windowKey == windowKey && $0.source == source
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

        let priorValues = history.samples.compactMap { sample -> Double? in
            guard sample.windowKey != windowKey,
                  sample.source == source,
                  sample.usedPercent >= 10,
                  sample.equivalentTokens.isFinite,
                  sample.equivalentTokens > 0
            else {
                return nil
            }
            return sample.equivalentTokens
        }
        let prior = robustCenter(priorValues)
        let current = history.samples.first(where: {
            $0.windowKey == windowKey && $0.source == source
        }).flatMap { sample in
            sample.usedPercent >= 3 ? sample.equivalentTokens : nil
        }

        let equivalentTokens: Double?
        switch (prior, current) {
        case let (.some(prior), .some(current)):
            let currentWeight = min(1, max(0.1, window.usedPercent / 50))
            equivalentTokens = exp(
                log(prior) * (1 - currentWeight) + log(current) * currentWeight
            )
        case let (.some(prior), .none):
            equivalentTokens = prior
        case let (.none, .some(current)):
            equivalentTokens = current
        case (.none, .none):
            equivalentTokens = nil
        }

        guard let equivalentTokens,
              equivalentTokens.isFinite,
              equivalentTokens > 0
        else {
            return nil
        }
        return WeeklyTokenCapacityEstimate(
            usedPercent: window.usedPercent,
            observedTokens: observedTokens,
            equivalentTokens: equivalentTokens
        )
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
