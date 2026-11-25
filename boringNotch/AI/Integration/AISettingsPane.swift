//
//  AISettingsPane.swift
//  boringNotch
//
//  "AI Agents" settings pane: notch behavior for the AI tab, Claude Code /
//  Codex hook integration, notch theme and sound options ported from
//  Code Island.
//

import Defaults
import SwiftUI

struct AIAgentsSettings: View {
    @ObservedObject private var settingsStore = AIManager.shared.settingsStore
    @AppStorage(AISettingsStore.Keys.showRemainingUsage) private var showRemainingUsage = false

    @Default(.enableAITab) private var enableAITab
    @Default(.aiPopupOnFinished) private var popupOnFinished
    @Default(.aiFinishedAutoCloseSeconds) private var finishedAutoCloseSeconds

    @State private var claudeInstalled = false
    @State private var codexInstalled = false
    @State private var isInstallingHooks = false
    @State private var installResultText: String?
    @State private var installSucceeded = false

    var body: some View {
        Form {
            generalSection
            integrationsSection
            appearanceSection
            soundSection
        }
        .accentColor(.effectiveAccent)
        .navigationTitle("AI Agents")
        .onAppear {
            refreshInstallStatus()
        }
    }

    // MARK: - General

    @ViewBuilder
    private var generalSection: some View {
        Section {
            Defaults.Toggle(key: .enableAITab) {
                Text("Enable AI tab")
            }
            Defaults.Toggle(key: .aiAutoPopupOnRequest) {
                Text("Open notch on permission, plan or question requests")
            }
            .disabled(!enableAITab)
            Defaults.Toggle(key: .aiPopupOnFinished) {
                Text("Show a card when an agent finishes")
            }
            .disabled(!enableAITab)
            Slider(value: $finishedAutoCloseSeconds, in: 2...15, step: 1) {
                HStack {
                    Text("Auto-close finished card after")
                    Spacer()
                    Text("\(finishedAutoCloseSeconds, specifier: "%.0f")s")
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(!enableAITab || !popupOnFinished)
            Defaults.Toggle(key: .aiShowClosedActivity) {
                Text("Show agent activity in the closed notch")
            }
            .disabled(!enableAITab)
        } header: {
            Text("General")
        } footer: {
            Text("While an agent is waiting for your decision, the notch stays open until you respond.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Integrations

    @ViewBuilder
    private var integrationsSection: some View {
        Section {
            integrationRow(
                title: "Claude Code",
                detail: "Hooks in ~/.claude/settings.json",
                installed: claudeInstalled
            )
            integrationRow(
                title: "Codex",
                detail: "Hooks in ~/.codex/hooks.json and config.toml",
                installed: codexInstalled
            )
            HStack(spacing: 8) {
                Button {
                    Task { await reinstallHooks() }
                } label: {
                    Text(claudeInstalled || codexInstalled ? "Reinstall hooks" : "Install hooks")
                }
                .disabled(isInstallingHooks)
                if isInstallingHooks {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
                if let installResultText, !isInstallingHooks {
                    Label(
                        installResultText,
                        systemImage: installSucceeded
                            ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(installSucceeded ? Color.green : Color.orange)
                }
            }
            Toggle("Install hooks automatically on launch", isOn: $settingsStore.autoInstallHooks)
        } header: {
            Text("Integrations")
        } footer: {
            Text("SuperNotch shares its hooks and the /tmp/code-island.sock socket with the Code Island app. Do not run both apps at the same time.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func integrationRow(title: String, detail: String, installed: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                Circle()
                    .fill(installed ? Color.green : Color.secondary.opacity(0.5))
                    .frame(width: 7, height: 7)
                Text(installed ? "Installed" : "Not installed")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func refreshInstallStatus() {
        claudeInstalled = AIManager.shared.claudeHooksInstalled()
        codexInstalled = AIManager.shared.codexHooksInstalled()
    }

    private func reinstallHooks() async {
        guard !isInstallingHooks else { return }
        isInstallingHooks = true
        installResultText = nil
        let result = await AIManager.shared.reinstallHooks()
        isInstallingHooks = false
        refreshInstallStatus()
        installSucceeded = result.claude && result.codex
        switch (result.claude, result.codex) {
        case (true, true):
            installResultText = "Hooks installed for Claude Code and Codex"
        case (true, false):
            installResultText = "Claude Code installed, Codex failed"
        case (false, true):
            installResultText = "Codex installed, Claude Code failed"
        case (false, false):
            installResultText = "Hook installation failed"
        }
    }

    // MARK: - Appearance

    @ViewBuilder
    private var appearanceSection: some View {
        Section {
            Picker("Notch theme", selection: $settingsStore.notchThemeID) {
                ForEach(NotchThemeID.allCases) { themeID in
                    Text(themeID.displayName).tag(themeID)
                }
            }
            Toggle(isOn: $showRemainingUsage) {
                Text("Show remaining usage instead of used")
                Text("Usage limits show what's left, e.g. \"5h 72% left\" instead of \"5h 28%\".")
            }
        } header: {
            Text("Appearance")
        } footer: {
            Text(settingsStore.notchThemeID.blurb)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Sound

    @ViewBuilder
    private var soundSection: some View {
        Section {
            Toggle("Enable sounds", isOn: $settingsStore.soundEnabled)
            Slider(value: $settingsStore.soundVolume, in: 0...1) {
                HStack {
                    Text("Volume")
                    Spacer()
                    Text("\(Int((settingsStore.soundVolume * 100).rounded()))%")
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(!settingsStore.soundEnabled)
            ForEach(Self.soundEventRows, id: \.event) { row in
                HStack {
                    Toggle(row.label, isOn: soundEventBinding(row.event))
                    Button {
                        AIManager.shared.previewSound(row.event)
                    } label: {
                        Image(systemName: "play.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Preview")
                }
                .disabled(!settingsStore.soundEnabled)
            }
        } header: {
            Text("Sound")
        } footer: {
            Text("Session start/end sounds play only for real sessions (after your first prompt), not for background probes.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Events shown in Settings, in display order. `.error` is omitted: nothing
    /// currently emits it.
    private static let soundEventRows: [(event: SoundEvent, label: String)] = [
        (.approvalNeeded, "Needs your approval"),
        (.completion, "Task finished"),
        (.approvalGranted, "Approved"),
        (.approvalDenied, "Denied"),
        (.sessionStart, "Session started"),
        (.sessionEnd, "Session ended"),
        (.toolUse, "Every tool call"),
    ]

    private func soundEventBinding(_ event: SoundEvent) -> Binding<Bool> {
        Binding(
            get: { settingsStore.soundChoice(for: event.rawValue) != "off" },
            set: { on in settingsStore.setSoundChoice(on ? "default" : "off", for: event.rawValue) }
        )
    }
}
