//
//  FavoritesSettingsView.swift
//  MenuScores
//
//  Created by Daniyal Master on 2026-06-20.
//

import SwiftUI

struct FavoritesSettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var favoritesManager = FavoritesManager.shared

    @AppStorage("autoPinFavorites") private var autoPinFavorites = false
    @AppStorage("autoClearFavorites") private var autoClearFavorites = true
    @State private var favoriteTeamMessage: String?

    private let selectedLeague = "NBA"
    @State private var searchText = ""

    @State private var currentPage = 0
    private let teamsPerPage = 50

    private func fallbackLogo(for leagueKey: String) -> String {
        FavoriteTeams.fallbackLogoForLeague(leagueKey)
    }

    private var filteredTeams: [TeamInfo] {
        let teams = favoritesManager.availableTeams[selectedLeague] ?? []

        if searchText.isEmpty {
            return teams
        }

        return teams.filter {
            $0.displayName.localizedCaseInsensitiveContains(searchText) || NBAMenuPresentation.teamName($0.abbreviation, fallback: $0.displayName).localizedCaseInsensitiveContains(searchText)
        }
    }

    private var paginatedTeams: [TeamInfo] {
        let startIndex = currentPage * teamsPerPage
        let endIndex = min(startIndex + teamsPerPage, filteredTeams.count)

        guard startIndex < endIndex else {
            return []
        }

        return Array(filteredTeams[startIndex ..< endIndex])
    }

    private var totalPages: Int {
        max(1, Int(ceil(Double(filteredTeams.count) / Double(teamsPerPage))))
    }

    var body: some View {
        VStack(spacing: 4) {
            Form {
                Section("自动固定") {
                    Toggle(isOn: $autoPinFavorites) {
                        HStack {
                            Image(systemName: "pin")
                                .foregroundColor(.primary)
                            Text("自动固定关注球队的比赛")
                        }
                    }

                    Toggle(isOn: $autoClearFavorites) {
                        HStack {
                            Image(systemName: "checkmark.circle")
                                .foregroundColor(.primary)
                            Text("比赛结束后自动取消固定")
                        }
                    }
                    .disabled(!self.autoPinFavorites)


                }

                Section {
                    if favoritesManager.favorites.isEmpty {
                        Text("尚未关注球队")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(favoritesManager.favorites.enumerated()), id: \.element.uniqueID) { index, favorite in
                            HStack {
                                AsyncImage(
                                    url: URL(
                                        string: colorScheme == .dark
                                            ? darkFavoriteLogoURL(
                                                from: favorite.logo ?? fallbackLogo(for: favorite.leagueKey),
                                                teamID: favorite.id,
                                                league: favorite.leagueKey
                                            ) ?? fallbackLogo(for: favorite.leagueKey)
                                            : favorite.logo ?? fallbackLogo(for: favorite.leagueKey)
                                    )
                                ) { phase in
                                    if let image = phase.image {
                                        image
                                            .resizable()
                                            .interpolation(.high)
                                            .scaledToFit()
                                            .transition(.opacity)
                                            .frame(width: 18, height: 18)
                                    } else {
                                        Color.clear
                                            .transition(.opacity)
                                            .frame(width: 18, height: 18)
                                    }
                                }

                                VStack(alignment: .leading) {
                                    Text(NBAMenuPresentation.teamName(favorite.abbreviation, fallback: favorite.displayName))

                                    Text(FavoriteTeams.isLeagueOnly(favorite.leagueKey)
                                        ? (FavoriteTeams.mappings[favorite.leagueKey]?.sport.capitalized ?? favorite.leagueKey)
                                        : FavoriteTeams.displayName(for: favorite.leagueKey))
                                        .font(.caption)
                                        .foregroundStyle(.primary)
                                }

                                Spacer()

                                Button {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        if index > 0 {
                                            favoritesManager.favorites.swapAt(index, index - 1)
                                            favoritesManager.saveFavorites()
                                        }
                                    }
                                } label: {
                                    Image(systemName: "chevron.up")
                                }
                                .disabled(index == 0)
                                .buttonStyle(.plain)
                                .help("提高优先级")

                                Button {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        if index < favoritesManager.favorites.count - 1 {
                                            favoritesManager.favorites.swapAt(index, index + 1)
                                            favoritesManager.saveFavorites()
                                        }
                                    }
                                } label: {
                                    Image(systemName: "chevron.down")
                                }
                                .disabled(index == favoritesManager.favorites.count - 1)
                                .buttonStyle(.plain)
                                .help("降低优先级")

                                Button {
                                    favoritesManager.favorites.removeAll {
                                        $0.id == favorite.id && $0.leagueKey == favorite.leagueKey
                                    }
                                    favoritesManager.saveFavorites()
                                } label: {
                                    Image(systemName: "star.fill")
                                }
                                .buttonStyle(.plain)
                                .help("取消关注")
                            }
                        }
                    }
                } header: {
                    HStack(spacing: 4) {
                        HStack {
                            Text("已关注球队")
                                .font(.headline)
                            Spacer()

                            if let message = favoriteTeamMessage {
                                Text(message)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            Button(action: {
                                favoriteTeamMessage = "多场比赛同时进行时，优先显示排序靠前的球队。"
                            }) {
                                Image(systemName: "exclamationmark.circle")
                            }
                            .controlSize(.small)
                            .buttonStyle(.plain)
                            .foregroundColor(.secondary)
                            .help("优先级说明")
                        }
                    }
                } footer: {
                    if !favoritesManager.favorites.isEmpty {
                        Text("使用箭头调整优先级；多场比赛同时进行时，优先固定排序靠前的球队。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Section {
                    TextField("搜索球队（中文或英文）", text: $searchText)
                        .textFieldStyle(.roundedBorder)

                    ZStack {
                        if favoritesManager.isLoadingTeams {
                            ProgressView()
                                .transition(.opacity)
                        } else {
                            ScrollView {
                                LazyVStack {
                                    ForEach(Array(paginatedTeams.indices), id: \.self) { index in
                                        let team = paginatedTeams[index]

                                        FavoriteTeamRow(
                                            team: team,
                                            leagueKey: selectedLeague
                                        )

                                        if index != paginatedTeams.count - 1 {
                                            Divider()
                                        }
                                    }
                                }
                            }
                            .transition(.opacity)
                        }
                    }
                    .animation(
                        .easeInOut(duration: 0.2),
                        value: favoritesManager.isLoadingTeams ||
                            favoritesManager.availableTeams[selectedLeague] == nil
                    )
                } header: {
                    Text("NBA 球队")
                } footer: {
                    if totalPages > 1 {
                        HStack {
                            Button {
                                currentPage -= 1
                            } label: {
                                Image(systemName: "chevron.left")
                            }
                            .buttonStyle(.bordered)
                            .disabled(currentPage == 0)

                            Spacer()

                            Text("第 \(currentPage + 1) / \(totalPages) 页")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Spacer()

                            Button {
                                currentPage += 1
                            } label: {
                                Image(systemName: "chevron.right")
                            }
                            .buttonStyle(.bordered)
                            .disabled(currentPage >= totalPages - 1)
                        }
                    }
                }
                .task(id: selectedLeague) {
                    if let url = FavoriteTeams.teamsUrl(for: selectedLeague) {
                        await favoritesManager.loadTeams(
                            for: selectedLeague,
                            url: url
                        )
                    }
                }
            }
            .formStyle(.grouped)
        }
    }
}

struct FavoriteTeamRow: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var favorites = FavoritesManager.shared

    let team: TeamInfo
    let leagueKey: String

    private var fallbackLogo: String {
        FavoriteTeams.fallbackLogoForLeague(leagueKey)
    }

    var body: some View {
        HStack {
            AsyncImage(
                url: URL(
                    string: colorScheme == .dark
                        ? darkFavoriteLogoURL(
                            from: team.logos?.first?.href ?? fallbackLogo,
                            teamID: team.id,
                            league: leagueKey
                        ) ?? fallbackLogo
                        : team.logos?.first?.href ?? fallbackLogo
                )
            ) { phase in
                if let image = phase.image {
                    image
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .transition(.opacity)
                        .frame(width: 18, height: 18)
                } else {
                    Color.clear
                        .transition(.opacity)
                        .frame(width: 18, height: 18)
                }
            }

            Text(NBAMenuPresentation.teamName(team.abbreviation, fallback: team.displayName))

            Spacer()

            Button {
                favorites.toggleFavorite(team, leagueKey: leagueKey)
            } label: {
                Image(systemName:
                    favorites.isFavorite(team, leagueKey: leagueKey)
                        ? "star.fill"
                        : "star"
                )
            }
            .padding(.trailing, 15)
            .buttonStyle(.plain)
            .help("关注球队")
        }
        .padding(.top, 5)
    }
}
