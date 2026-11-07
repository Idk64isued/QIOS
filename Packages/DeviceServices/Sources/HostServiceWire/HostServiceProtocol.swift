import Foundation

public nonisolated enum HostServiceFailure: Codable, Sendable {
    case device(DeviceError)
    case tools(DeviceToolsError)
    case posix(Int32)
    case message(String)
    public init(_ error: Error) {
        if let value = error as? DeviceError {
            self = .device(value)
        } else if let value = error as? DeviceToolsError {
            self = .tools(value)
        } else if let value = error as? POSIXError {
            self = .posix(value.code.rawValue)
        } else {
            self = .message(error.localizedDescription)
        }
    }
    public var error: Error {
        switch self {
        case .device(let value): value
        case .tools(let value): value
        case .posix(let value): POSIXError(POSIXErrorCode(rawValue: value) ?? .EIO)
        case .message(let value): DeviceToolsError.failed(value)
        }
    }
}

public nonisolated struct HostServiceRequest: Codable, Sendable {
    public static let version = 6
    public var version = Self.version
    public let id: UUID
    public let session: UUID
    public let operation: HostServiceOperation
    public init(id: UUID, session: UUID, operation: HostServiceOperation) {
        self.id = id
        self.session = session
        self.operation = operation
    }
}

public nonisolated struct HostServiceEvent: Codable, Sendable {
    public enum Payload: Codable, Sendable {
        case result(HostServiceValue)
        case failure(HostServiceFailure)
        case progress(HostServiceProgress)
    }
    public let id: UUID
    public let session: UUID
    public let payload: Payload
    public init(id: UUID, session: UUID, payload: Payload) {
        self.id = id
        self.session = session
        self.payload = payload
    }
}
