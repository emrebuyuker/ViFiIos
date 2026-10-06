import Foundation

/// The state of a screen's asynchronous content.
enum Loadable<Value> {
    case loading
    case loaded(Value)
    case failed(message: String)

    var value: Value? {
        if case let .loaded(value) = self { value } else { nil }
    }

    var isLoading: Bool {
        if case .loading = self { true } else { false }
    }
}

extension Loadable: Equatable where Value: Equatable {}

extension Error {
    /// A user-facing message for any error thrown by the data layer.
    var userMessage: String {
        (self as? LocalizedError)?.errorDescription ?? localizedDescription
    }
}
