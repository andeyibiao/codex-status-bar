import Foundation

struct ResetCreditsSnapshot: Equatable {
    var availableCount: String?
    var expiresAt: Date?
}

enum CodexResetCreditsError: Error {
    case missingAuth
    case invalidResponse
    case httpStatus(Int)
}

final class CodexResetCreditsClient {
    private let authURL: URL
    private let endpoint = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!

    init(authURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex")
        .appendingPathComponent("auth.json")) {
        self.authURL = authURL
    }

    func fetch() async throws -> ResetCreditsSnapshot {
        let credentials = try readCredentials()
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 4
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(credentials.accountID, forHTTPHeaderField: "chatgpt-account-id")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CodexResetCreditsError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw CodexResetCreditsError.httpStatus(httpResponse.statusCode)
        }

        let decoded = try JSONDecoder().decode(ResetCreditsResponse.self, from: data)
        let availableCredits = decoded.credits.filter { credit in
            credit.status == nil || credit.status == "available"
        }
        let expiry = availableCredits
            .compactMap { Self.parseDate($0.expiresAt) }
            .min()

        return ResetCreditsSnapshot(
            availableCount: decoded.availableCount.map(String.init),
            expiresAt: expiry
        )
    }

    private func readCredentials() throws -> Credentials {
        let data = try Data(contentsOf: authURL)
        let auth = try JSONDecoder().decode(AuthFile.self, from: data)
        guard
            let accessToken = auth.tokens?.accessToken,
            let accountID = auth.tokens?.accountID,
            !accessToken.isEmpty,
            !accountID.isEmpty
        else {
            throw CodexResetCreditsError.missingAuth
        }

        return Credentials(accessToken: accessToken, accountID: accountID)
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }

        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: value)
    }
}

private struct Credentials {
    var accessToken: String
    var accountID: String
}

private struct AuthFile: Decodable {
    var tokens: AuthTokens?
}

private struct AuthTokens: Decodable {
    var accessToken: String?
    var accountID: String?

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case accountID = "account_id"
    }
}

private struct ResetCreditsResponse: Decodable {
    var credits: [ResetCredit]
    var availableCount: Int?

    private enum CodingKeys: String, CodingKey {
        case credits
        case availableCount = "available_count"
    }
}

private struct ResetCredit: Decodable {
    var status: String?
    var expiresAt: String?

    private enum CodingKeys: String, CodingKey {
        case status
        case expiresAt = "expires_at"
    }
}

extension CodexResetCreditsClient: @unchecked Sendable {}
