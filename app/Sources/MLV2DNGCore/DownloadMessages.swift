// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Maps a download failure to a French, user-facing message (never exposes English system text).
public func downloadFailureMessage(error: Error? = nil, httpStatus: Int? = nil,
                                   received: Int64? = nil, expected: Int64? = nil) -> String {
    if let status = httpStatus, status != 200 {
        return "Serveur indisponible (code \(status)). Réessayez plus tard."
    }
    if let error {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost,
                 NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed, NSURLErrorTimedOut,
                 NSURLErrorCannotConnectToHost, NSURLErrorDataNotAllowed:
                return "Vous semblez hors ligne. Vérifiez votre connexion et réessayez."
            case NSURLErrorBadServerResponse, NSURLErrorResourceUnavailable:
                return "Serveur indisponible. Réessayez plus tard."
            default: break
            }
        }
        if (ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpaceError)
            || (ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOSPC)) {
            return "Espace disque insuffisant pour télécharger FUSE-T."
        }
        return "Une erreur inconnue est survenue pendant le téléchargement."
    }
    if let received, let expected, expected > 0, received != expected {
        return "Téléchargement incomplet. Réessayez."
    }
    return "Une erreur inconnue est survenue pendant le téléchargement."
}
