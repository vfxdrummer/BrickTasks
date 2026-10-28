internal import Domain
internal import Foundation
internal import OpenAPIRuntime

enum ErrorMapper {
    static func error(status: Int, body: Components.Schemas.APIError?) -> APIError {
        let message = body?.message ?? HTTPURLResponse.localizedString(forStatusCode: status)
        return switch status {
        case 400: .badRequest(message: message)
        case 404: .notFound(message: message)
        case 409: .actionNotAllowed(message: message)
        case 429: .rateLimited(retryAfter: nil)
        default: .server(status: status, message: body?.message)
        }
    }

    /// Errors thrown by the generated client: transport failures and responses it couldn't decode.
    static func error(from error: any Error) -> APIError {
        switch error {
        case let apiError as APIError:
            return apiError
        case let clientError as ClientError:
            // A response came back but didn't match the contract, e.g. an HTML 502 from the CDN.
            if let status = clientError.response?.status.code, status >= 500 {
                return .server(status: status, message: nil)
            }
            return Self.error(from: clientError.underlyingError)
        case let urlError as URLError:
            return transport(urlError)
        case is DecodingError:
            return .invalidResponse(String(describing: error))
        case is CancellationError:
            return .connectionInterrupted
        default:
            return .invalidResponse(String(describing: error))
        }
    }

    /// Splits failures where the request certainly never reached the server from ones where it might
    /// have. The difference decides whether a failed action needs reconciling.
    static func transport(_ error: URLError) -> APIError {
        switch error.code {
        case .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
             .dataNotAllowed, .internationalRoamingOff, .callIsActive, .secureConnectionFailed:
            .notConnected
        default:
            .connectionInterrupted
        }
    }
}
