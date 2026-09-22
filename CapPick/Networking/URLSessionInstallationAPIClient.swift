import Foundation

final class URLSessionInstallationAPIClient: InstallationAPIClient {
    private let session: URLSession
    private let baseURL: URL

    init(session: URLSession = .shared, baseURL: URL) {
        self.session = session
        self.baseURL = baseURL
    }

    func requestChallenge() async throws -> ChallengeIssued {
        let request = makeRequest(path: "/v1/installations/challenges")
        let dto: ChallengeResponseDTO = try await send(request)
        return ChallengeIssued(challengeId: dto.challengeId, challenge: dto.challenge, expiresAt: dto.expiresAt)
    }

    func register(challengeId: String, keyId: String, attestationObject: Data) async throws -> InstallationRegistered {
        let body = InstallationRegisterRequestDTO(
            challengeId: challengeId,
            keyId: keyId,
            attestationObject: attestationObject.base64EncodedString()
        )
        let request = try makeRequest(path: "/v1/installations", body: body)
        let dto: InstallationRegisterResponseDTO = try await send(request)
        return InstallationRegistered(installationId: dto.installationId, credential: dto.credential, expiresAt: dto.expiresAt)
    }

    func renewCredential(currentCredential: String, challengeId: String, assertionObject: Data) async throws -> CredentialRenewed {
        let body = CredentialRenewRequestDTO(challengeId: challengeId, assertionObject: assertionObject.base64EncodedString())
        let request = try makeRequest(
            path: "/v1/installations/credentials/renew",
            body: body,
            authorization: currentCredential
        )
        let dto: CredentialRenewResponseDTO = try await send(request)
        return CredentialRenewed(credential: dto.credential, expiresAt: dto.expiresAt)
    }

    private func makeRequest(path: String, authorization: String? = nil) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        if let authorization {
            request.setValue("Bearer \(authorization)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func makeRequest<Body: Encodable>(path: String, body: Body, authorization: String? = nil) throws -> URLRequest {
        var request = makeRequest(path: path, authorization: authorization)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try CapPickJSON.encoder.encode(body)
        } catch {
            throw CapPickAPIError.decoding("request encoding failed: \(error)")
        }
        return request
    }

    private func send<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        try await CapPickHTTP.send(request, session: session)
    }
}

private struct ChallengeResponseDTO: Decodable {
    let challengeId: String
    let challenge: String
    let expiresAt: Date
}

private struct InstallationRegisterRequestDTO: Encodable {
    let challengeId: String
    let keyId: String
    let attestationObject: String
}

private struct InstallationRegisterResponseDTO: Decodable {
    let installationId: String
    let credential: String
    let expiresAt: Date
}

private struct CredentialRenewRequestDTO: Encodable {
    let challengeId: String
    let assertionObject: String
}

private struct CredentialRenewResponseDTO: Decodable {
    let credential: String
    let expiresAt: Date
}
