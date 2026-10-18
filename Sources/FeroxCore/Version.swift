/// The engine version, kept in step with `CHANGELOG.md`.
///
/// Tools (FeroxDiag, FeroxBenchmarks) embed it in their reports so results can be
/// traced back to the engine revision that produced them.
public enum FeroxVersion {
    public static let major = 0
    public static let minor = 1
    public static let patch = 0
    /// `major.minor.patch`, e.g. "0.1.0".
    public static let string = "\(major).\(minor).\(patch)"
}
