/// The middle of a set of samples and its interquartile spread, nearest rank.
struct Spread {
    var median: Double
    var lowerQuartile: Double
    var upperQuartile: Double

    init?(_ samples: [Double]) {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        func rank(_ fraction: Double) -> Double {
            sorted[min(sorted.count - 1, Int((fraction * Double(sorted.count - 1)).rounded()))]
        }
        median = rank(0.5)
        lowerQuartile = rank(0.25)
        upperQuartile = rank(0.75)
    }

    /// `median [lower–upper]` at `digits` decimals.
    func formatted(_ digits: Int) -> String {
        "\(fixed(median, digits)) [\(fixed(lowerQuartile, digits))–\(fixed(upperQuartile, digits))]"
    }
}

/// `value` rounded to `digits` decimals, written out without a locale.
func fixed(_ value: Double, _ digits: Int) -> String {
    guard value.isFinite else { return "–" }
    var scale = 1.0
    for _ in 0..<digits { scale *= 10 }
    let scaled = Int((abs(value) * scale).rounded())
    let whole = scaled / Int(scale)
    let fraction = scaled % Int(scale)
    var text = (value < 0 && scaled != 0 ? "-" : "") + String(whole)
    if digits > 0 {
        let digitsText = String(fraction)
        text += "." + String(repeating: "0", count: digits - digitsText.count) + digitsText
    }
    return text
}
