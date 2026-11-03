/// The name a received item publishes under, which the receiver chooses: never the container's own.
public enum PublishName: Equatable, Sendable {
    /// Exactly this name; the publish fails `EEXIST` when anything has it.
    case exactly([UInt8])
    /// This name, or when anything has it, the first free one `KeepBothName` counts up to.
    case keepingBoth([UInt8])

    /// The name asked for.
    var base: [UInt8] {
        switch self {
        case .exactly(let name), .keepingBoth(let name): name
        }
    }

    /// Whether a taken name moves to the next Keep Both name.
    var keepsBoth: Bool {
        if case .keepingBoth = self { true } else { false }
    }
}
