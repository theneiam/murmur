import Foundation

/// Every outbound link in one place. Murmur makes no network requests on its
/// own; these are opened in the browser only when the user clicks them.
enum SupportLinks {
    /// Change this if the project moves; everything else derives from it.
    static let repository = URL(string: "https://github.com/theneiam/murmur")!
    static let website = URL(string: "https://theneiam.github.io/murmur/")!

    static let latestRelease = repository.appending(path: "releases/latest")
    static let newIssue = repository.appending(path: "issues/new")
    static let privacyPolicy = repository.appending(path: "blob/main/PRIVACY.md")
}
