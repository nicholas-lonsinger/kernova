import Cocoa

extension NSView {

    /// Adds a subview and pins it to all four edges of the receiver using Auto Layout constraints.
    func addFullSizeSubview(_ subview: NSView) {
        subview.translatesAutoresizingMaskIntoConstraints = false
        addSubview(subview)
        NSLayoutConstraint.activate([
            subview.leadingAnchor.constraint(equalTo: leadingAnchor),
            subview.trailingAnchor.constraint(equalTo: trailingAnchor),
            subview.topAnchor.constraint(equalTo: topAnchor),
            subview.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}
