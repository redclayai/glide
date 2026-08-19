import Foundation
import TokenProfiles

/// Errors raised by the `acpf-build` pipeline. Lives in `ProfileBuilderCore` so both
/// the CLI surface and the test target can match on the cases.
///
/// Conforms to `LocalizedError` (not just `CustomStringConvertible`) so that surfacing it through
/// `error.localizedDescription` — which the app's profile-generation path does — yields this
/// readable text instead of the generic Foundation bridge string
/// ("The operation couldn't be completed. (ProfileBuilderCore.ACPFCLIError error 1.)").
public enum ACPFCLIError: Error, CustomStringConvertible, LocalizedError {
    case outputExists(path: String)
    case selfCheckFailed(failures: [ProfileSelfCheck.Failure])

    public var description: String {
        switch self {
        case .outputExists(let path):
            return "Refusing to overwrite existing profile at \(path); pass --force to override."
        case .selfCheckFailed(let failures):
            return "Profile self-check failed:\n" + failures.map { "  - \($0)" }.joined(separator: "\n")
        }
    }

    public var errorDescription: String? { description }
}
