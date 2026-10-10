import AVFoundation
import Foundation
import PareLibrary
import PareTranscode

/// How the pipeline should react to an error (docs/resilience.md §6).
public enum ErrorClass: String, Codable, Sendable, Equatable {
    case transient, waitNetwork, waitDisk, userDeclined, needsUser, permanent, cancelled
}

/// No progress for longer than the watchdog allows.
public struct StallError: Error, Sendable, Equatable, LocalizedError {
    public var step: String
    public init(step: String) { self.step = step }
    public var errorDescription: String? { "The \(step) step stopped making progress." }
}

/// Failures the pipeline itself detects.
public enum PipelineError: Error, Sendable, Equatable, LocalizedError {
    case invalidSource(String)
    case workspaceLocked
    case workspaceUnavailable(String)
    case copyMismatch(String)

    public var errorDescription: String? {
        switch self {
        case .invalidSource(let m): "The downloaded video is unusable: \(m)"
        case .workspaceLocked: "PixelPare is already working on this library in another window."
        case .workspaceUnavailable(let m): "Couldn't prepare a working folder: \(m)"
        case .copyMismatch(let m): "The new copy doesn't match the original: \(m)"
        }
    }
}

/// Test seam: simulates the process dying at the throw site. The pipeline rethrows it without touching any state
/// (no cleanup, no journal write), exactly as if the process had been killed.
public struct SimulatedCrash: Error, Sendable, Equatable {
    public init() {}
}

public enum ErrorClassifier {
    public static func classify(_ error: Error) -> ErrorClass {
        if error is CancellationError { return .cancelled }
        if error is StallError { return .transient }
        if let e = error as? PipelineError {
            switch e {
            case .invalidSource: return .transient
            case .workspaceLocked: return .needsUser
            case .workspaceUnavailable: return .transient
            case .copyMismatch: return .permanent
            }
        }
        if let e = error as? LibraryError {
            switch e {
            case .notFound, .thumbnailFailed: return .permanent
            case .accessDenied: return .needsUser
            case .exportFailed, .importFailed: return .transient
            }
        }
        if let e = error as? TranscodeError {
            switch e {
            case .noVideoTrack, .cannotConfigure: return .permanent
            case .readerFailed, .writerFailed: return .transient
            }
        }
        let ns = error as NSError
        switch ns.domain {
        case NSURLErrorDomain: return url(ns.code)
        case PhotosErrorCodes.domain: return photos(ns.code)
        case AVFoundationErrorDomain: return av(ns.code)
        case NSPOSIXErrorDomain: return posix(Int32(truncatingIfNeeded: ns.code))
        case NSCocoaErrorDomain: return cocoa(ns.code)
        default: return .transient
        }
    }

    /// A message fit for the UI.
    public static func message(for error: Error) -> String {
        if error is CancellationError { return "Stopped before finishing." }
        if let e = error as? LocalizedError, let d = e.errorDescription { return d }
        let ns = error as NSError
        switch classify(error) {
        case .waitNetwork: return "No internet connection."
        case .waitDisk: return "Not enough free storage."
        case .userDeclined: return "You chose not to continue."
        case .needsUser where ns.domain == PhotosErrorCodes.domain: return "PixelPare needs access to your photo library."
        default: return ns.localizedDescription
        }
    }

    private static func url(_ code: Int) -> ErrorClass {
        switch code {
        case NSURLErrorNotConnectedToInternet, NSURLErrorDataNotAllowed, NSURLErrorInternationalRoamingOff,
             NSURLErrorCallIsActive:
            .waitNetwork
        case NSURLErrorCancelled: .cancelled
        default: .transient   // timedOut, networkConnectionLost, cannotConnectToHost, dnsLookupFailed, …
        }
    }

    private static func photos(_ code: Int) -> ErrorClass {
        switch code {
        case PhotosErrorCodes.userCancelled: .userDeclined
        case PhotosErrorCodes.networkAccessRequired, PhotosErrorCodes.networkError: .waitNetwork
        case PhotosErrorCodes.notEnoughSpace: .waitDisk
        case PhotosErrorCodes.accessRestricted, PhotosErrorCodes.accessUserDenied,
             PhotosErrorCodes.libraryVolumeOffline: .needsUser
        case PhotosErrorCodes.invalidResource, PhotosErrorCodes.identifierNotFound,
             PhotosErrorCodes.multipleIdentifiersFound, PhotosErrorCodes.changeNotSupported: .permanent
        default: .transient   // operationInterrupted, relinquishing/switching library, unknown
        }
    }

    private static func av(_ code: Int) -> ErrorClass {
        switch AVError.Code(rawValue: code) {
        case .diskFull: .waitDisk
        case .decoderTemporarilyUnavailable: .transient
        case .decodeFailed, .fileFormatNotRecognized, .decoderNotFound, .noLongerPlayable,
             .failedToLoadMediaData, .fileFailedToParse, .unsupportedOutputSettings: .permanent
        default: .transient
        }
    }

    private static func posix(_ code: Int32) -> ErrorClass {
        switch code {
        case ENOSPC, EDQUOT: .waitDisk
        case EACCES, EPERM, EROFS: .needsUser
        default: .transient
        }
    }

    private static func cocoa(_ code: Int) -> ErrorClass {
        switch code {
        case 640: .waitDisk   // NSFileWriteOutOfSpaceError
        case CocoaError.fileWriteNoPermission.rawValue, CocoaError.fileReadNoPermission.rawValue,
             CocoaError.fileWriteVolumeReadOnly.rawValue: .needsUser
        default: .transient   // incl. NSFileLockingError and other file-coordination failures
        }
    }
}
