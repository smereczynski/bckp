import Foundation

// Version string embedded in the binary.
// In CI releases, this file is overwritten with the tag value before build.
// As a fallback in local/dev runs, we allow an env override and then a default literal.
public enum BckpVersion {
    public static let string: String = {
        if let v = ProcessInfo.processInfo.environment["BCKP_VERSION"], !v.isEmpty { return v }
        return "0.0.0+dev"
    }()
}
