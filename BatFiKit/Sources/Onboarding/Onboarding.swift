//
//  Onboarding.swift
//
//
//  Created by Adam on 31/05/2023.
//

import AVKit
import Clients
import ConfettiSwiftUI
import Defaults
import DefaultsKeys
import Dependencies
import L10n
import ServiceManagement
import SwiftUI

private let loginItemsSettingsURL = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!

enum OnboardingScreen: Int, CaseIterable {
    case welcome
    case charging
    case helper

    func next() -> OnboardingScreen? {
        OnboardingScreen(rawValue: rawValue + 1)
    }

    func previous() -> OnboardingScreen? {
        OnboardingScreen(rawValue: rawValue - 1)
    }
}

struct Onboarding: View {
    @StateObject var model: Model
    @State private var confettiCounter = 0

    init(didInstallHelper: @escaping () -> Void) {
        _model = StateObject(wrappedValue: Model(didInstallHelper: didInstallHelper))
    }

    var body: some View {
        let l10n = L10n.Onboarding.self
        let alertL10n = L10n.Onboarding.Alert.self
        VStack {
            PageView(
                numberOfPages: OnboardingScreen.allCases.count,
                index: model.currentScreen.rawValue
            ) {
                WelcomeView().id(OnboardingScreen.welcome.rawValue)
                ChargingLimitView(model: model).id(OnboardingScreen.charging.rawValue)
                InstallHelperView(model: model).id(OnboardingScreen.helper.rawValue)
            }
            HStack {
                OnboardingButton(title: l10n.Button.Label.previous, isLoading: false, action: { model.previousAction() })
                    .opacity(model.currentScreen != .welcome && !model.onboardingIsFinished ? 1 : 0)
                    .animation(.spring(), value: model.currentScreen)
                    .disabled(model.isLoading)

                Spacer()
                OnboardingButton(
                    title: nextButtonTitle,
                    isLoading: model.isLoading,
                    action: { model.nextAction() }
                )
                .disabled(model.isLoading || model.isAwaitingApproval)
                .animation(.spring(), value: model.currentScreen)
            }.overlay(alignment: .center) {
                PageControl(
                    count: OnboardingScreen.allCases.count,
                    index: Binding(
                        get: { model.currentScreen.rawValue },
                        set: { index in
                            if let screen = OnboardingScreen(rawValue: index) {
                                model.currentScreen = screen
                            }
                        }
                    )
                )
            }
            .padding([.leading, .bottom, .trailing], 20)
        }
        .confettiCannon(
            counter: Binding(get: { model.onboardingIsFinished ? 1 : 0 }, set: { _ in }),
            confettiSize: 10,
            openingAngle: Angle(degrees: 30),
            closingAngle: Angle(degrees: 150),
            repetitions: 2,
            repetitionInterval: 0.7
        )
        .alert(
            alertL10n.Title.helperNotInstalled,
            isPresented: Binding<Bool>(
                get: { model.helperError != nil },
                set: { _ in model.helperError = nil }
            ),
            actions: {
                Button(alertL10n.Button.Label.openSystemSettings, role: .cancel) {
                    NSWorkspace.shared.open(loginItemsSettingsURL)
                }
            },
            message: {
                Text(alertL10n.Message.helperNotInstalled)
            }
        )
        .edgesIgnoringSafeArea(.top)
        .frame(width: 420, height: 620)
    }

    var nextButtonTitle: String {
        let l10n = L10n.Onboarding.Button.Label.self
        switch model.currentScreen {
        case .welcome:
            return l10n.getStarted
        case .helper:
            if model.onboardingIsFinished {
                return l10n.complete
            } else {
                return l10n.installHelper
            }
        default:
            return l10n.next
        }
    }
}

extension Onboarding {
    final class Model: ObservableObject {
        let didInstallHelper: () -> Void
        @MainActor @Published var currentScreen: OnboardingScreen = .welcome
        @MainActor @Published var helperError: NSError?
        @MainActor @Published var isLoading: Bool = false
        @MainActor @Published var isAwaitingApproval: Bool = false
        @MainActor @Published var onboardingIsFinished = false
        @Dependency(\.helperClient) private var helperManager
        @Dependency(\.launchAtLogin) private var launchAtLogin
        @Dependency(\.defaults) private var defaults
        var playerModel: OnboardingPlayerViewModel!

        init(didInstallHelper: @escaping () -> Void) {
            self.didInstallHelper = didInstallHelper
            playerModel = OnboardingPlayerViewModel($currentScreen.eraseToAnyPublisher())
        }

        @MainActor
        func nextAction() {
            switch currentScreen {
            case .helper:
                guard !onboardingIsFinished else {
                    completeOnboarding()
                    return
                }
                Task {
                    @MainActor
                    func observeHelperStatus(error: Error?) async {
                        var counter = 0
                        var openedSystemSettings = false
                        for await status in helperManager.observeHelperStatus() {
                            if status == .enabled {
                                isAwaitingApproval = false
                                self.helperError = nil
                                if let next = currentScreen.next() {
                                    currentScreen = next
                                }
                                didInstallHelper()
                                defaults.setValue(.onboardingIsDone, value: true)
                                onboardingIsFinished = true
                                NSSound(named: "Funk")?.play()
                                break
                            } else if status == .requiresApproval {
                                // The daemon is registered but the user must enable it in
                                // System Settings → General → Login Items.
                                // Stop the spinner and, on the first occurrence, open the
                                // relevant settings pane automatically so the user knows
                                // exactly where to look.
                                isLoading = false
                                isAwaitingApproval = true
                                if !openedSystemSettings {
                                    openedSystemSettings = true
                                    NSWorkspace.shared.open(loginItemsSettingsURL)
                                }
                                continue
                            } else if counter >= 20 {
                                isAwaitingApproval = false
                                self.helperError = (error.map { $0 as NSError })
                                    ?? NSError(
                                        domain: "BatFi",
                                        code: -1,
                                        userInfo: [NSLocalizedDescriptionKey: "Helper installation timed out. Please try again."]
                                    )
                                break
                            } else {
                                isAwaitingApproval = false
                                try? await helperManager.removeHelper()
                                try? await Task.sleep(for: .seconds(1))
                                try? await helperManager.installHelper()
                                counter += 1
                            }
                        }
                    }
                    isLoading = true
                    do {
                        try await helperManager.installHelper()
                        await observeHelperStatus(error: nil)
                    } catch {
                        await observeHelperStatus(error: error)
                    }
                    isLoading = false
                }

            default:
                if let next = currentScreen.next() {
                    currentScreen = next
                }
            }
        }

        @MainActor
        func previousAction() {
            if let previous = currentScreen.previous() {
                currentScreen = previous
            }
        }

        @MainActor
        func openLoginItemsSettings() {
            NSWorkspace.shared.open(loginItemsSettingsURL)
        }

        @MainActor
        func completeOnboarding() {
            launchAtLogin.launchAtLogin(Defaults[.launchAtLogin])
            NSApp.windows.first { $0.isKind(of: OnboardingWindow.self) }?.close()
        }

        var player: AVPlayer {
            playerModel.player
        }
    }
}

struct Onboarding_Previews: PreviewProvider {
    static var previews: some View {
        Onboarding(didInstallHelper: {})
            .frame(width: 420, height: 600)
    }
}
