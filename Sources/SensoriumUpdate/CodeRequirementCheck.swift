#if os(macOS)
import Foundation
import Security

/// Whether a bundle on disk is signed the way an update must be. Behind a
/// protocol so tests can pass a requirement compiled from text against
/// bundles they sign ad hoc.
public protocol UpdateRequirementChecking: Sendable {
    func isSatisfied(byBundleAt url: URL) -> Bool
}

/// A code signing requirement checked with `SecStaticCodeCheckValidity`.
///
/// The running app's designated requirement names its bundle identifier and
/// the release certificate. macOS ties Screen Recording and Accessibility
/// grants to that same requirement, so a new version that satisfies it keeps
/// them.
public struct CodeRequirementCheck: UpdateRequirementChecking, @unchecked Sendable {
    // A `SecRequirement` is immutable once created.
    private let requirement: SecRequirement

    /// Every slice of a universal binary is checked, not only the one this
    /// machine would run, as is any code nested in the bundle.
    static let validityFlags = SecCSFlags(
        rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode
    )

    /// The designated requirement of the code running this process.
    ///
    /// It is read through the app's path, which a swap gives to the new
    /// version, so it is read once, on the first call, and every later call
    /// returns that same value whatever is on disk by then. The first call
    /// must happen at launch, before any update is staged or swapped in.
    public static func runningApp() -> CodeRequirementCheck? {
        runningAppAtFirstCall
    }

    // A static stored property is initialized once, on first access, and
    // safely across threads.
    private static let runningAppAtFirstCall: CodeRequirementCheck? = readRunningApp()

    private static func readRunningApp() -> CodeRequirementCheck? {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else {
            return nil
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess, let staticCode else {
            return nil
        }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(staticCode, SecCSFlags(), &requirement) == errSecSuccess,
              let requirement else {
            return nil
        }
        return CodeRequirementCheck(requirement: requirement)
    }

    /// A requirement in the code signing requirement language, such as
    /// `identifier "com.example.app"`.
    public init?(requirementText: String) {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementText as CFString, SecCSFlags(), &requirement) == errSecSuccess,
              let requirement else {
            return nil
        }
        self.init(requirement: requirement)
    }

    private init(requirement: SecRequirement) {
        self.requirement = requirement
    }

    public func isSatisfied(byBundleAt url: URL) -> Bool {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode else {
            return false
        }
        return SecStaticCodeCheckValidity(staticCode, Self.validityFlags, requirement) == errSecSuccess
    }
}
#endif
