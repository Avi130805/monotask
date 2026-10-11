import AppKit
import SwiftUI

/// The open notch: a header beside the camera, then Do Now, Do Next and the capture field.
struct PanelView: View {
    let namespace: Namespace.ID
    @Environment(NotchModel.self) var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HeaderBand()
            ZStack(alignment: .top) {
                if model.page == .main {
                    MainPage(namespace: namespace).transition(.softSwap)
                } else {
                    LogPage().transition(.softSwap)
                }
            }
            .padding(.top, 8)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
        .frame(width: Layout.panelWidth)
    }
}

struct MainPage: View {
    let namespace: Namespace.ID

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            DoNowSection(namespace: namespace)
            DoNextSection(namespace: namespace)
            CaptureField()
        }
    }
}

/// The strip either side of the camera: this week's count on the left, settings on the right.
struct HeaderBand: View {
    @Environment(Store.self) var store
    @Environment(NotchModel.self) var model

    var body: some View {
        HStack(spacing: 0) {
            Button {
                withAnimation(Motion.content) { model.page = model.page == .main ? .log : .main }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: model.page == .main ? "checkmark.circle.fill" : "chevron.left")
                        .foregroundStyle(model.page == .main ? Palette.done : Palette.secondary)
                        .contentTransition(.symbolEffect(.replace))
                    Text(model.page == .main ? "\(store.finishedThisWeek) done this week" : "Back")
                        .contentTransition(.numericText())
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressScale())
            .help("Everything you've finished")

            Spacer(minLength: model.notchSize.width + 16)
            SettingsMenu()
        }
        .padding(.horizontal, 4)
        .frame(height: model.notchSize.height)
    }
}

struct SettingsMenu: View {
    @Environment(NotchModel.self) var model
    @AppStorage(Prefs.openOnHover) var openOnHover = false
    @AppStorage(Prefs.showWings) var showWings = true
    @AppStorage(Prefs.haptics) var haptics = true
    @State var launchAtLogin = LaunchAtLogin.isEnabled

    var body: some View {
        Menu {
            Button("Insights…") { model.onOpenInsights() }
            Button("Prompter…") { model.onOpenScript() }
            Button(model.prompterHotKeyLabel.isEmpty ? "Start Prompter" : "Start Prompter (\(model.prompterHotKeyLabel))") {
                model.onStartPrompter()
            }
            Divider()
            Toggle("Open on hover", isOn: $openOnHover)
            Toggle("Show the timer beside the notch", isOn: $showWings)
            Toggle("Haptic feedback", isOn: $haptics)
            Divider()
            Toggle("Launch at login", isOn: Binding(
                get: { launchAtLogin },
                set: { launchAtLogin = LaunchAtLogin.set($0) }
            ))
            Divider()
            Button("Quit Next") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Palette.secondary)
                .frame(width: 28, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onAppear { launchAtLogin = LaunchAtLogin.isEnabled }
    }
}
