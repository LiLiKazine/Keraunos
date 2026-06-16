import Foundation

/// One HTTP cookie, decoupled from WebKit so the serializer is testable in Core.
/// `expires == nil` means a session cookie. `includeSubdomains` is true when the
/// cookie applies to subdomains (its domain has a leading dot).
public struct Cookie: Equatable, Sendable {
    public let name: String
    public let value: String
    public let domain: String
    public let path: String
    public let isSecure: Bool
    public let expires: Date?
    public let includeSubdomains: Bool

    public init(name: String, value: String, domain: String, path: String,
                isSecure: Bool, expires: Date?, includeSubdomains: Bool) {
        self.name = name
        self.value = value
        self.domain = domain
        self.path = path
        self.isSecure = isSecure
        self.expires = expires
        self.includeSubdomains = includeSubdomains
    }
}
