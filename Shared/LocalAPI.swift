import Foundation

/// Do not cross gomobile's nullable NSData/NSError bridge for HTTP responses
/// that cannot contain a body. Real body-read failures must still propagate.
func localAPIResponseBody(statusCode: Int, method: String, readBody: Bool,
                          read: () throws -> Data) rethrows -> Data {
    guard readBody, method.uppercased() != "HEAD",
          statusCode != 204, statusCode != 205, statusCode != 304,
          !(100..<200).contains(statusCode) else { return Data() }
    return try read()
}

/// Only trusted labels and numeric status codes reach the login UI. Raw
/// backend descriptions, response bodies and NSError userInfo may contain keys.
func authKeyLoginFailureMessage(_ error: Error, activating: Bool) -> String {
    let stage = activating ? "Could not start device registration" : "Could not submit the auth key to the app backend"
    if let local = error as? LocalAPIError {
        switch local {
        case .unsuccessfulStatus(let status, _, _):
            return "\(stage) (LocalAPI HTTP \(status)). This does not necessarily mean the key is invalid."
        case .backend:
            return "\(stage): the app backend could not complete the request."
        case .missingBody, .invalidBodyEncoding, .decoding:
            return "\(stage): an invalid local response was received."
        }
    }
    let nsError = error as NSError
    if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut {
        return "\(stage): the request timed out. Check connectivity and retry."
    }
    if error is CancellationError {
        return "\(stage): the request was cancelled."
    }
    return "\(stage): a local bridge or transport error occurred (code \(nsError.code))."
}

enum LocalAPIError: Error, LocalizedError {
    case backend(String)
    case unsuccessfulStatus(statusCode: Int, endpoint: String, bodyPreview: String?)
    case missingBody(endpoint: String)
    case invalidBodyEncoding(endpoint: String)
    case decoding(endpoint: String, underlying: Error, bodyPreview: String?)

    var errorDescription: String? {
        switch self {
        case .backend(let message):
            return message
        case .unsuccessfulStatus(let statusCode, let endpoint, let bodyPreview):
            if let bodyPreview, !bodyPreview.isEmpty {
                return "LocalAPI \(endpoint) returned HTTP \(statusCode): \(bodyPreview)"
            }
            return "LocalAPI \(endpoint) returned HTTP \(statusCode)"
        case .missingBody(let endpoint):
            return "LocalAPI \(endpoint) returned no response body"
        case .invalidBodyEncoding(let endpoint):
            return "LocalAPI \(endpoint) returned an invalid response body"
        case .decoding(let endpoint, let underlying, let bodyPreview):
            if let bodyPreview, !bodyPreview.isEmpty {
                return "LocalAPI \(endpoint) decode failed: \(underlying.localizedDescription); body=\(bodyPreview)"
            }
            return "LocalAPI \(endpoint) decode failed: \(underlying.localizedDescription)"
        }
    }
}

extension IPCResponse {
    func requireSuccess(endpoint: String) throws {
        if let error {
            throw LocalAPIError.backend(error)
        }
        guard (200..<300).contains(statusCode) else {
            throw LocalAPIError.unsuccessfulStatus(
                statusCode: statusCode,
                endpoint: endpoint,
                bodyPreview: bodyPreview()
            )
        }
    }

    func bodyData(endpoint: String) throws -> Data {
        try requireSuccess(endpoint: endpoint)
        guard let bodyBase64 else {
            throw LocalAPIError.missingBody(endpoint: endpoint)
        }
        guard let data = Data(base64Encoded: bodyBase64) else {
            throw LocalAPIError.invalidBodyEncoding(endpoint: endpoint)
        }
        return data
    }

    func decodedBody<T: Decodable>(_ type: T.Type, endpoint: String, decoder: JSONDecoder = JSONDecoder()) throws -> T {
        let data = try bodyData(endpoint: endpoint)
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw LocalAPIError.decoding(endpoint: endpoint, underlying: error, bodyPreview: bodyPreview())
        }
    }

    func bodyPreview(limit: Int = 512) -> String? {
        guard let bodyBase64,
              let data = Data(base64Encoded: bodyBase64),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count <= limit { return trimmed }
        return String(trimmed.prefix(limit))
    }
}