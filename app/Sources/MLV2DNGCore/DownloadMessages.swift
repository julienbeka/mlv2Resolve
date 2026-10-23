// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Maps a download failure to a localized, user-facing message (never exposes system error text).
public func downloadFailureMessage(error: Error? = nil, httpStatus: Int? = nil,
                                   received: Int64? = nil, expected: Int64? = nil) -> String {
    if let status = httpStatus, status != 200 {
        return String(localized: "Server unavailable (code \(status)). Try again later.", bundle: L10n.bundle)
    }
    if let error {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost,
                 NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed, NSURLErrorTimedOut,
                 NSURLErrorCannotConnectToHost, NSURLErrorDataNotAllowed:
                return String(localized: "You appear to be offline. Check your connection and try again.", bundle: L10n.bundle)
            case NSURLErrorBadServerResponse, NSURLErrorResourceUnavailable:
                return String(localized: "Server unavailable. Try again later.", bundle: L10n.bundle)
            default: break
            }
        }
        if (ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpaceError)
            || (ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOSPC)) {
            return String(localized: "Not enough disk space to download FUSE-T.", bundle: L10n.bundle)
        }
        return String(localized: "An unknown error occurred during the download.", bundle: L10n.bundle)
    }
    if let received, let expected, expected > 0, received != expected {
        return String(localized: "Download incomplete. Try again.", bundle: L10n.bundle)
    }
    return String(localized: "An unknown error occurred during the download.", bundle: L10n.bundle)
}
