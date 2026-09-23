import Foundation

/// Field values keyed by ``ListingField`` — `nil` entries are simply absent from the dictionary.
public typealias FieldValues = [ListingField: String]

/// A normalized listing state: localized values per locale, plus shared (unlocalized) values.
/// `ListingPuller` builds one from App Store Connect; `MetadataStore` builds one from the
/// fastlane-layout directory; `ListingDiff` compares the two.
public struct ListingSnapshot: Sendable {
    public var localized: [String: FieldValues]
    public var shared: FieldValues

    public init(localized: [String: FieldValues] = [:], shared: FieldValues = [:]) {
        self.localized = localized
        self.shared = shared
    }

    public var locales: [String] { localized.keys.sorted() }

    public func value(_ field: ListingField, locale: String?) -> String? {
        if let locale { localized[locale]?[field] } else { shared[field] }
    }
}
