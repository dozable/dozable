import Foundation

/// The skills doz carries for an agent that drives it (`doz skill show NAME`): each a `SKILL.md` in the package's resource
/// bundle, `DozableKit_DozableKit.bundle/skills/NAME/SKILL.md` — beside the executable in every layout (`make cli`'s
/// `.build/debug`, a release's and Homebrew's `libexec/doz`, `make install-cli`'s prefix), found the way the guest binaries
/// are (`DeckholdBinary.candidateBundleDirectories`, never SwiftPM's trapping `Bundle.module`). Read-only: doz never installs
/// a skill anywhere; whoever runs the agent points it at the path.
public enum ShippedSkills {
    /// The folder inside the resource bundle.
    public static let folder = "skills"
    public static let fileName = "SKILL.md"

    /// The `skills` folder of the first resource bundle that has one (nil: this build carries none).
    public static func directory() -> URL? {
        let fm = FileManager.default
        for bundle in DeckholdBinary.candidateBundleDirectories() {
            for rel in ["Contents/Resources/\(folder)", folder] {
                let url = bundle.appendingPathComponent(rel)
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue { return url.standardizedFileURL }
            }
        }
        return nil
    }

    /// Every skill this build carries, by name (sorted): the folders holding a `SKILL.md`.
    public static func names(in dir: URL? = directory()) -> [String] {
        guard let dir, let items = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return items.filter { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).appendingPathComponent(fileName).path) }.sorted()
    }

    /// The absolute path of skill `name`'s `SKILL.md`, or nil when this build has no such skill. A name is a plain folder
    /// name (a-z 0-9 -): never a path.
    public static func locate(_ name: String, in dir: URL? = directory()) -> URL? {
        guard !name.isEmpty, name.count <= 64,
              name.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }),
              let dir else { return nil }
        let url = dir.appendingPathComponent(name).appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
