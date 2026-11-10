//
//  getGAmes.swift
//  MenuScores
//
//  Created by Daniyal Master on 2025-05-03.
//

import Foundation

enum NetworkError: Error {
    case invalidResponse
}

class getGames {
    func getTeamsArray(url: URL) async throws -> [TeamInfo] {
        let (data, response) = try await URLSession.shared.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200
        else {
            throw NetworkError.invalidResponse
        }

        let decoded = try JSONDecoder().decode(
            TeamsResponse.self, from: data
        )

        return decoded.sports.first?.leagues.first?.teams.map { $0.team } ?? []
    }
}
