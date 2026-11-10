import AppKit
import Combine
import DynamicNotchKit
import SwiftUI

@MainActor
protocol NBAMilestoneOverlay: AnyObject {
    var wantsMilestones: Bool { get }
    func present(_ reminder: NBAGameReminder) -> Bool
}

@MainActor
final class NBANotchController: NBAMilestoneOverlay {
    static let shared = NBANotchController()
    private typealias Surface = DynamicNotch<NBANotchExpanded, NBANotchCompactSide, NBANotchCompactSide>
    private var surface: Surface?
    private let model = NBANotchViewModel()
    private var session = NBANotchSession()
    private var options = NBANotchOptions()
    private var subscriptions: Set<AnyCancellable> = []
    private var expiration: Task<Void, Never>?
    private var freshness: Task<Void, Never>?
    private var presentation: Task<Void, Never>?
    private var receipt: [String: Date] = [:]
    private var screenID: String?
    private var scheduleFailed = false
    private var sleeping = false
    private(set) var active = false

    static func identifier(_ screen: NSScreen) -> String {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return "" }
        return CFUUIDCreateString(nil, uuid) as String
    }
    static var screens: [(id: String, name: String)] {
        NSScreen.screens.map { (identifier($0), $0.localizedName) }.filter { !$0.id.isEmpty }
    }
    private var target: NSScreen? {
        let screens = NSScreen.screens
        let choice = NBANotchOptions.screen(preferred: options.screenID, available: screens.map(Self.identifier), main: screens.first.map(Self.identifier))
        return screens.first { Self.identifier($0) == choice }
    }
    var wantsMilestones: Bool { options.enabled && options.milestones && active && !sleeping && target != nil }

    func configure() {
        let next = NBANotchOptions.read()
        guard next.enabled else { options = next; stop(); return }
        let moved = options.screenID != next.screenID
        options = next
        if !active {
            active = true
            NBAPinnedSelectionStore.shared.$selection.receive(on: RunLoop.main).sink { [weak self] selection in
                guard let self else { return }
                self.session.pinned = selection?.game
                self.render()
            }.store(in: &subscriptions)
            NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification).receive(on: RunLoop.main).sink { [weak self] _ in
                self?.relocate()
            }.store(in: &subscriptions)
            NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification).receive(on: RunLoop.main).sink { [weak self] _ in
                guard let self else { return }
                self.sleeping = true; self.expiration?.cancel(); self.session.cancelMoment(); self.destroySurface()
            }.store(in: &subscriptions)
            NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification).receive(on: RunLoop.main).sink { [weak self] _ in
                guard let self else { return }
                self.sleeping = false; self.receipt = [:]; self.relocate()
            }.store(in: &subscriptions)
        }
        if !options.milestones { session.cancelMoment(); expiration?.cancel() }
        if moved { relocate() } else { render() }
    }

    func observe(_ observations: [NBAGameObservation], refreshFailed: Bool = false) {
        guard active else { return }
        scheduleFailed = refreshFailed
        let now = Date()
        for observation in observations where (-5...60).contains(now.timeIntervalSince(observation.fetchedAt)) {
            receipt[observation.game.id] = observation.fetchedAt
        }
        receipt = receipt.filter { now.timeIntervalSince($0.value) <= 900 }
        render()
        freshness?.cancel()
        freshness = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(61)) } catch { return }
            self?.render()
        }
    }

    func present(_ reminder: NBAGameReminder) -> Bool {
        guard wantsMilestones else { return false }
        // Do not replace the match underneath an ongoing hover/interaction.
        guard surface?.isHovering != true else { return false }
        session.present(reminder, now: Date()); receipt[reminder.eventID] = Date()
        render()
        guard surface != nil else { session.cancelMoment(); return false }
        expiration?.cancel()
        let deadline = session.moment?.expires ?? Date()
        expiration = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            while let self, !Task.isCancelled {
                // The display timeout is monotonic even if the system clock moves backward.
                if self.session.finishIfDue(now: max(Date(), deadline), interacting: self.surface?.isHovering == true) {
                    self.render(); return
                }
                do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            }
        }
        return true
    }

    private func render() {
        guard active, !sleeping, let screen = target, let game = session.game else { destroySurface(); return }
        if screenID != Self.identifier(screen) { destroySurface() }
        model.game = game; model.momentTitle = session.moment?.title
        model.stale = scheduleFailed || (receipt[game.id].map { Date().timeIntervalSince($0) > 60 } ?? true)
        model.openDetails = { NBANotificationDetailWindow.shared.open(eventID: game.id) }
        if surface == nil {
            let viewModel = model
            surface = Surface(hoverBehavior: [.keepVisible], style: .auto, observeScreens: false) {
                NBANotchExpanded(model: viewModel)
            } compactLeading: {
                NBANotchCompactSide(model: viewModel, away: true)
            } compactTrailing: {
                NBANotchCompactSide(model: viewModel, away: false)
            }
            surface?.transitionConfiguration = .init(skipIntermediateHides: true)
            screenID = Self.identifier(screen)
        }
        guard let surface else { return }
        surface.compactsOnHoverExit = session.moment == nil
        presentation?.cancel()
        let expanded = session.moment != nil
        presentation = Task {
            if expanded { await surface.expand(on: screen) }
            else if !surface.isHovering { await surface.compact(on: screen) }
        }
    }
    private func relocate() { destroySurface(); render() }
    private func destroySurface() {
        presentation?.cancel(); presentation = nil
        surface?.dispose(); surface = nil; screenID = nil
    }
    #if DEBUG
    /// Explicit developer-only rendering fixture. No defaults, pin writes,
    /// network calls, subscriptions or reminder delivery are started.
    func preview() {
        let status = Status(displayClock: "1:32", period: 4,
            type: type(name: "STATUS_IN_PROGRESS", state: "in", completed: false, detail: "", shortDetail: ""), clock: 92)
        let competitors = [("13", "LAL", "湖人", "away", "108"), ("9", "GS", "勇士", "home", "106")].map {
            Competitor(homeAway: $0.3, id: $0.0, score: $0.4, order: nil, winner: nil, athlete: nil,
                team: Team(id: $0.0, displayName: $0.2, abbreviation: $0.1, name: nil,
                    logo: nil, links: [], color: nil, alternateColor: nil))
        }
        let competition = Competition(competitors: competitors, status: status, situation: nil, highlights: nil,
                                      headlines: nil, details: nil, venue: nil, notes: nil)
        let game = Event(id: "401810123", date: "2026-10-31T02:00:00Z", endDate: nil, name: "浮层预览",
                         shortName: nil, competitions: [competition], weather: nil, status: status, links: nil, circuit: nil)
        options = NBANotchOptions(enabled: true, milestones: false, screenID: "")
        active = true; session.pinned = game; receipt[game.id] = Date()
        render()
        Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            self?.exportPreview("compact")
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard let self, let screen = self.target else { return }
            self.surface?.compactsOnHoverExit = false
            await self.surface?.expand(on: screen)
            self.exportPreview("expanded")
        }
        surface?.$isHovering.dropFirst().sink { [weak self] hovering in
            guard hovering else { return }
            Task { @MainActor in
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                self?.exportPreview("expanded")
            }
        }.store(in: &subscriptions)
    }
    func exportPreview(_ name: String) {
        guard AppRuntime.isNotchPreview, let view = surface?.windowController?.window?.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let data = bitmap.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: "/tmp/MenuScores-build/Logs/Cleanup/notch-" + name + ".png"))
        }
    }
    #endif

    func stop() {
        active = false; subscriptions.removeAll()
        expiration?.cancel(); expiration = nil; freshness?.cancel(); freshness = nil
        session = NBANotchSession(); receipt = [:]; destroySurface()
    }
}
