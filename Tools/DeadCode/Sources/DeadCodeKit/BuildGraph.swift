import Foundation

#if canImport(FoundationXML)
import FoundationXML
#endif

/// The parts of `swift package describe --type json` the build graph and a package's bundle read.
package struct PackageDescription: Decodable, Sendable {
    package struct Product: Decodable, Sendable {
        package var name: String
        package var isExecutable: Bool
        package var targets: [String]

        private enum CodingKeys: String, CodingKey { case name, type, targets }

        package init(name: String, isExecutable: Bool, targets: [String]) {
            self.name = name
            self.isExecutable = isExecutable
            self.targets = targets
        }

        package init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            targets = try container.decode([String].self, forKey: .targets)
            // `{"executable": null}` or `{"library": ["automatic"]}`.
            isExecutable = try container.decode([String: [String]?].self, forKey: .type).keys.contains("executable")
        }
    }

    /// A target; `describe` leaves out a dependency list that is empty.
    package struct Target: Decodable, Sendable {
        package var name: String
        /// Its sources' directory, relative to the package.
        package var path: String
        private var module_type: String
        private var target_dependencies: [String]?
        private var product_dependencies: [String]?

        package init(
            name: String, path: String? = nil, isSwift: Bool = true, targetDependencies: [String] = [],
            productDependencies: [String] = []
        ) {
            self.name = name
            self.path = path ?? "Sources/\(name)"
            module_type = isSwift ? "SwiftTarget" : "ClangTarget"
            target_dependencies = targetDependencies
            product_dependencies = productDependencies
        }

        package var isSwift: Bool { module_type == "SwiftTarget" }
        package var targetDependencies: [String] { target_dependencies ?? [] }
        package var productDependencies: [String] { product_dependencies ?? [] }
    }

    package var products: [Product]
    package var targets: [Target]

    package init(products: [Product], targets: [Target]) {
        self.products = products
        self.targets = targets
    }
}

/// A native or aggregate target of an Xcode project: the targets it depends on and the package products it links.
package struct XcodeTarget: Equatable, Sendable {
    package var name: String
    package var dependencies: [String]
    package var packageProducts: [String]

    package init(name: String, dependencies: [String] = [], packageProducts: [String] = []) {
        self.name = name
        self.dependencies = dependencies
        self.packageProducts = packageProducts
    }

    /// The targets of a `project.pbxproj`.
    package static func targets(pbxproj: Data) throws -> [XcodeTarget] {
        let plist = try PropertyListSerialization.propertyList(from: pbxproj, format: nil)
        guard let root = plist as? [String: Any], let objects = root["objects"] as? [String: [String: Any]],
            let rootID = root["rootObject"] as? String, let targetIDs = objects[rootID]?["targets"] as? [String]
        else { throw BuildGraphError.unreadableProject }

        func ids(_ object: [String: Any], _ key: String) -> [[String: Any]] {
            (object[key] as? [String] ?? []).compactMap { objects[$0] }
        }
        func productName(_ id: Any?) -> String? {
            (id as? String).flatMap { objects[$0]?["productName"] as? String }
        }

        return try targetIDs.map { id in
            guard let target = objects[id], let name = target["name"] as? String else {
                throw BuildGraphError.unreadableProject
            }
            var dependencies: [String] = []
            var products = ids(target, "packageProductDependencies").compactMap { $0["productName"] as? String }
            for dependency in ids(target, "dependencies") {
                if let targetID = dependency["target"] as? String, let name = objects[targetID]?["name"] as? String {
                    dependencies.append(name)
                } else if let product = productName(dependency["productRef"]) {
                    products.append(product)
                }
            }
            return XcodeTarget(name: name, dependencies: dependencies, packageProducts: products)
        }
    }
}

package enum BuildGraphError: Error, Equatable, CustomStringConvertible {
    case unreadableProject
    case unreadableScheme(String)
    case unknownSchemeTarget(scheme: String, target: String)

    package var description: String {
        switch self {
        case .unreadableProject: "the Xcode project's project.pbxproj does not read as a project"
        case .unreadableScheme(let scheme): "the scheme \(scheme) does not parse"
        case .unknownSchemeTarget(let scheme, let target):
            "the scheme \(scheme) builds \(target), which is neither a target of the project nor of its packages"
        }
    }
}

/// The targets a scheme builds to run or to archive — what a developer launches or ships — as opposed to the targets
/// it builds only to test.
package func schemeLaunchTargets(xml: Data, scheme: String) throws(BuildGraphError) -> [String] {
    let reader = SchemeReader()
    let parser = XMLParser(data: xml)
    parser.delegate = reader
    guard parser.parse() else { throw .unreadableScheme(scheme) }
    return reader.targets
}

private final class SchemeReader: NSObject, XMLParserDelegate {
    var targets: [String] = []
    private var inBuildAction = false
    private var entryLaunches = false

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?,
        attributes: [String: String] = [:]
    ) {
        switch elementName {
        case "BuildAction": inBuildAction = true
        case "BuildActionEntry" where inBuildAction:
            entryLaunches = attributes["buildForRunning"] == "YES" || attributes["buildForArchiving"] == "YES"
        case "BuildableReference" where inBuildAction && entryLaunches:
            if let name = attributes["BlueprintName"] { targets.append(name) }
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        switch elementName {
        case "BuildAction": inBuildAction = false
        case "BuildActionEntry": entryLaunches = false
        default: break
        }
    }
}

/// Every target, of the project and of its packages, that no product a user runs reaches: test bundles, the test
/// support libraries, and a test host.
///
/// A target is production when a scheme builds it to run or archive, or an executable product holds it, or such a
/// target reaches it through target dependencies, linked package products, or a product's targets.
package func testOnlyTargets(
    project: [XcodeTarget], packages: [PackageDescription], schemes: [String: [String]]
) throws(BuildGraphError) -> [String] {
    enum Node: Hashable {
        case xcode(String)
        case product(String)
        case target(String)
    }
    let xcodeTargets = Dictionary(project.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    let products = Dictionary(
        packages.flatMap(\.products).map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    let packageTargets = Dictionary(
        packages.flatMap(\.targets).map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })

    var roots: [Node] = products.values.filter(\.isExecutable).map { .product($0.name) }
    for (scheme, names) in schemes.sorted(by: { $0.key < $1.key }) {
        for name in names {
            if xcodeTargets[name] != nil {
                roots.append(.xcode(name))
            } else if products[name] != nil {
                roots.append(.product(name))
            } else if packageTargets[name] != nil {
                roots.append(.target(name))
            } else {
                throw .unknownSchemeTarget(scheme: scheme, target: name)
            }
        }
    }

    var reached = Set<Node>()
    var queue = roots
    while let node = queue.popLast() {
        guard reached.insert(node).inserted else { continue }
        switch node {
        case .xcode(let name):
            guard let target = xcodeTargets[name] else { continue }
            queue += target.dependencies.map(Node.xcode) + target.packageProducts.map(Node.product)
        case .product(let name):
            queue += products[name]?.targets.map(Node.target) ?? []
        case .target(let name):
            guard let target = packageTargets[name] else { continue }
            queue += target.targetDependencies.map(Node.target) + target.productDependencies.map(Node.product)
        }
    }

    let all = Set(xcodeTargets.keys).union(packageTargets.keys)
    return all.filter { !reached.contains(.xcode($0)) && !reached.contains(.target($0)) }.sorted()
}
