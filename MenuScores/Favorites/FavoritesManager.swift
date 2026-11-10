// Created by Daniyal Master on 2026-06-20.
// Local customization: persistent menu-bar selection; legacy favorites remain readable.
import Foundation
import SwiftUI

class FavoritesManager: ObservableObject {
    static let shared = FavoritesManager()
    @Published var favorites: [FavoriteTeam] = []
    @Published var availableTeams: [String: [TeamInfo]] = [:]
    @Published var isLoadingTeams = false
    private let favoritesKey = "favoriteTeams"
    private let defaults: UserDefaults
    private var nbaViewModel: GamesListView?
    private var dismissedGameID = ""

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        loadFavorites()
    }

    @MainActor
    func loadTeams(for leagueKey: String, url: URL) async {
        if availableTeams[leagueKey] != nil {
            return
        }

        isLoadingTeams = true
        defer { isLoadingTeams = false }

        do {
            let teams = try await getGames().getTeamsArray(url: url)
            availableTeams[leagueKey] = teams.sorted {
                $0.displayName < $1.displayName
            }
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch {
            print("Failed to load teams: \(error)")
        }
    }

    // Favorites Management

    func loadFavorites() {
        guard let data = defaults.data(forKey: favoritesKey) else {
            favorites = []
            return
        }

        do {
            favorites = try JSONDecoder().decode([FavoriteTeam].self, from: data)
        } catch {
            print("Failed to fetch favorites:", error)
            favorites = []
        }
    }

    func saveFavorites() {
        do {
            let data = try JSONEncoder().encode(favorites)
            defaults.set(data, forKey: favoritesKey)
        } catch {
            print("Failed to save favorites:", error)
        }
    }

    func isFavorite(_ team: TeamInfo, leagueKey: String) -> Bool {
        favorites.contains {
            $0.id == team.id && $0.leagueKey == leagueKey
        }
    }

    func toggleFavorite(_ team: TeamInfo, leagueKey: String) {
        if let index = favorites.firstIndex(where: {
            $0.id == team.id && $0.leagueKey == leagueKey
        }) {
            favorites.remove(at: index)
        } else {
            let fallbackLogo = FavoriteTeams.fallbackLogoForLeague(leagueKey)

            favorites.append(
                FavoriteTeam(
                    id: team.id,
                    leagueKey: leagueKey,
                    displayName: team.displayName,
                    abbreviation: team.abbreviation ?? "",
                    logo: team.logos?.first?.href ?? fallbackLogo
                )
            )
        }

        saveFavorites()
    }

    @MainActor
    func registerNBA(_ viewModel: GamesListView) { nbaViewModel = viewModel }

    @MainActor
    func updateNBASelection(_ store: NBAPinnedSelectionStore) {
        guard store.selection?.source != .manual, defaults.bool(forKey: "autoPinFavorites") else { return }
        guard let game = liveFavoriteGame() else {
            if defaults.object(forKey: "autoClearFavorites") as? Bool ?? true { store.clearAutomaticSelection() }
            return
        }
        guard dismissedGameID != game.id else { return }
        _ = store.pinAutomatically(game)
    }

    @MainActor
    private func liveFavoriteGame() -> Event? {
        for favorite in favorites where favorite.leagueKey.uppercased() == "NBA" {
            if let game = nbaViewModel?.games.first(where: { game in
                game.status.type.state == "in" &&
                (favorite.id.hasPrefix("league-") ||
                 game.competitions.first?.competitors?.contains(where: { $0.team?.id == favorite.id }) == true)
            }) { return game }
        }
        return nil
    }

    @MainActor
    func dismissAutoPinnedGame(_ gameID: String) {
        guard !gameID.isEmpty else { return }
        dismissedGameID = gameID
    }
}
