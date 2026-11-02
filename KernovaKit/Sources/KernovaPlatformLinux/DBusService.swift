#if os(Linux)
import KernovaDBus

/// Why a call to a service on a bus failed.
public enum DBusServiceError: Error, Hashable, Sendable {
    /// The call returned no reply, or the service answered with an ERROR.
    case call(DBusCallError)
    /// The reply or signal's body is not the signature the service documents.
    case unexpectedReply(DBusProtocolError)
    /// A property or field holds a value of another type than the service
    /// documents.
    case valueMismatch(DBusValueMismatch)
    /// `GetAll` left out a property the service documents.
    case missingProperty(String)

    /// The ERROR the service, or the bus on its behalf, answered with; nil
    /// for every other failure.
    public var remoteError: DBusRemoteError? {
        guard case .call(.remote(let error)) = self else { return nil }
        return error
    }

    /// Runs typed reads of a body whose signature was already checked, so a
    /// mismatch is a value of the wrong type inside a variant.
    static func read<T>(_ body: () throws(DBusValueMismatch) -> T) throws(DBusServiceError) -> T {
        do throws(DBusValueMismatch) {
            return try body()
        } catch {
            throw .valueMismatch(error)
        }
    }
}

extension DBusBusConnection {
    /// Calls `member` on `destination` and returns the reply's body, which
    /// must have `signature`.
    func callMethod(
        destination: String, path: DBusObjectPath, interface: String, member: String, body: [DBusValue] = [],
        expecting signature: DBusSignature, timeout: Duration = DBusBusConnection.defaultTimeout
    ) throws(DBusServiceError) -> [DBusValue] {
        let message = DBusMessage.methodCall(
            destination: destination, path: path, interface: interface, member: member, body: body)
        let reply: DBusReceivedMessage
        do throws(DBusCallError) {
            reply = try call(message, timeout: timeout)
        } catch {
            throw .call(error)
        }
        do throws(DBusProtocolError) {
            return try reply.decodeBody(expecting: signature)
        } catch {
            throw .unexpectedReply(error)
        }
    }
}
#endif
