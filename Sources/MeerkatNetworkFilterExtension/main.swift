import Foundation
import MeerkatNetworkFilter
import NetworkExtension
import os

// The network filter's system extension: macOS starts it as root from
// Meerkat.app/Contents/Library/SystemExtensions once the user allows it, and
// NetworkExtension makes the provider (FilterDataProvider) when the content
// filter is turned on (docs/design/network-filter.md).

do {
    try FilterServer.start()
} catch {
    // Without the service the totals cannot be read, but the filter must still
    // run: a provider that never starts would leave the configuration enabled
    // and the extension relaunching.
    Logger(subsystem: FilterService.extensionIdentifier, category: "main")
        .error("not serving totals: \(error, privacy: .public)")
}

autoreleasepool {
    NEProvider.startSystemExtensionMode()
}
dispatchMain()
