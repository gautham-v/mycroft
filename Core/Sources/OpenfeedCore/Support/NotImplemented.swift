import Foundation

/// Thrown by the placeholder Default* services until their owning agent replaces them.
public struct NotImplementedError: Error, LocalizedError, Equatable {
    public var what: String
    public init(_ what: String) { self.what = what }
    public var errorDescription: String? { "\(what) is not implemented yet" }
}
