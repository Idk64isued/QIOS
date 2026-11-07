// The Swift packages a build links, from their manifests (`swift package dump-package`): what the root packages'
// targets reach, product by product, but not through a macro or a plugin (they run in the compiler: swift-syntax,
// under swift-binary-parsing's macros, builds and never ships). A package resolved and checked out but not reached
// (swift-syntax) carries no license into the bundle.
import Foundation

enum SwiftPackageLinks {
    /// Identities (lowercased directory names) of what is linked: every non-test target of each of `roots`, and
    /// every product of each of `direct` (the remote packages the Xcode project names), followed through `manifests`
    /// (by identity: each package's dump-package JSON).
    static func linked(roots: [String], direct: [String], manifests: [String: [String: Any]]) -> Set<String> {
        var linked: Set<String> = []
        var seen: Set<String> = []
        func targets(_ m: [String: Any]) -> [[String: Any]] { m["targets"] as? [[String: Any]] ?? [] }
        func products(_ m: [String: Any]) -> [[String: Any]] { m["products"] as? [[String: Any]] ?? [] }
        func dependencies(_ m: [String: Any]) -> [String] {
            (m["dependencies"] as? [[String: Any]] ?? []).compactMap {
                (($0.values.first as? [[String: Any]])?.first?["identity"] as? String)?.lowercased()
            }
        }
        func product(_ package: String, _ name: String) {
            guard let m = manifests[package] else { return }
            for p in products(m) where p["name"] as? String == name {
                for t in p["targets"] as? [String] ?? [] { target(package, t) }
            }
        }
        func target(_ package: String, _ name: String) {
            guard seen.insert("\(package)\0\(name)").inserted, let m = manifests[package],
                let t = targets(m).first(where: { $0["name"] as? String == name }),
                !["macro", "plugin", "test"].contains(t["type"] as? String ?? "")
            else { return }
            linked.insert(package)
            for d in t["dependencies"] as? [[String: Any]] ?? [] {
                let args = d.values.first as? [Any] ?? []
                guard let n = args.first as? String else { continue }
                switch d.keys.first {
                case "target": target(package, n)
                case "product": product(((args.count > 1 ? args[1] : nil) as? String ?? package).lowercased(), n)
                default:  // byName: a target of this package, else a product of one it depends on
                    if targets(m).contains(where: { $0["name"] as? String == n }) {
                        target(package, n)
                    } else {
                        for q in dependencies(m)
                        where manifests[q].map({ products($0).contains { $0["name"] as? String == n } }) ?? false {
                            product(q, n)
                        }
                    }
                }
            }
        }
        for r in roots { for t in manifests[r].map(targets) ?? [] { target(r, t["name"] as? String ?? "") } }
        for d in direct { for p in manifests[d].map(products) ?? [] { product(d, p["name"] as? String ?? "") } }
        return linked
    }
}
