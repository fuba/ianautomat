import SwiftUI

@main
struct IanautomatApp: App {
    var body: some Scene {
        WindowGroup { ControlCenter() }
    }
}

struct ControlCenter: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var account = Account()
    @State private var controller = GoalController()
    @State private var showingSettings = false
    @State private var showingPlan = false
    @AppStorage("acknowledgedChatGPTPlan") private var acknowledgedChatGPTPlan = false
    @FocusState private var editing: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    composer
                    if !account.connected || account.models.isEmpty { connection }
                    if let error = controller.error {
                        Text(error).font(.footnote)
                    }
                    if let run = controller.current { runSummary(run) }
                    history
                }
                .padding(16)
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("ianautomat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings", systemImage: "gearshape") {
                        editing = false
                        showingSettings = true
                    }.labelStyle(.iconOnly)
                }
            }
            .sheet(isPresented: $showingSettings) { settings }
            .alert("You’re using your ChatGPT plan", isPresented: $showingPlan) {
                Button("Got it") { acknowledgedChatGPTPlan = true }
            } message: {
                Text("Eligible requests use your ChatGPT plan. You can manage usage in ChatGPT settings.")
            }
            .navigationDestination(for: UUID.self) { id in
                if let run = controller.history.first(where: { $0.id == id }) {
                    ScrollView {
                        runSummary(run)
                            .padding(16)
                            .frame(maxWidth: 620)
                            .frame(maxWidth: .infinity)
                    }
                    .navigationTitle("Goal run")
                    .navigationBarTitleDisplayMode(.inline)
                }
            }
            .navigationDestination(for: ToolRoute.self) { route in
                if let artifact = controller.history.first(where: { $0.id == route.run })?
                    .artifacts.first(where: { $0.id == route.artifact }) {
                    ToolView(artifact: artifact) { controller.update($0, in: route.run) }
                }
            }
        }
        .tint(.primary)
        .task {
            controller.load()
            account.load()
            await account.reloadModels()
        }
        .onChange(of: account.connected, initial: true) { _, connected in
            if connected && !acknowledgedChatGPTPlan { showingPlan = true }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { controller.pause() }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("GOAL").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            TextEditor(text: $controller.draft)
                .font(.body)
                .frame(minHeight: 108, maxHeight: 200)
                .padding(5)
                .scrollContentBackground(.hidden)
                .background(.background, in: .rect(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.secondary.opacity(0.35)))
                .accessibilityLabel("Goal")
                .accessibilityIdentifier("goal-editor")
                .disabled(controller.active)
                .focused($editing)
            if controller.draft.utf8.count > 16_000 {
                Text("The goal is too long.").font(.footnote)
            }
            if account.connected {
                HStack {
                    Text("Using ChatGPT plan").foregroundStyle(.secondary)
                    Spacer()
                    Link("Manage usage", destination: usageURL)
                }
                .font(.footnote)
            }
            HStack(spacing: 8) {
                Button {
                    editing = false
                    switch controller.current?.phase {
                    case .running: controller.pause()
                    case .paused, .limited: controller.resume(account: account)
                    default: controller.start(account: account)
                    }
                } label: {
                    Label(primaryTitle, systemImage: controller.current?.phase == .running ? "pause.fill" : "play.fill")
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(uiColor: .label))
                .foregroundStyle(primaryDisabled ? Color(uiColor: .secondaryLabel) : Color(uiColor: .systemBackground))
                .disabled(primaryDisabled)
                .accessibilityIdentifier("start-goal")

                Button {
                    controller.stop()
                } label: {
                    Label("Stop", systemImage: "stop.fill").labelStyle(.iconOnly)
                        .frame(minWidth: 36, minHeight: 36)
                }
                .buttonStyle(.bordered)
                .disabled(!controller.active)
                .accessibilityIdentifier("stop-goal")
            }
        }
    }

    private let usageURL = URL(string: "https://chatgpt.com/#settings/Usage")!

    private var primaryTitle: LocalizedStringKey {
        switch controller.current?.phase {
        case .running: "Pause"
        case .paused: "Resume"
        case .limited: "Continue"
        default: "Run goal"
        }
    }

    private var primaryDisabled: Bool {
        if controller.current?.phase == .running { return false }
        return !account.connected || account.models.isEmpty || account.busy ||
            (!controller.active && !controller.canStart)
    }

    private var connection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !account.connected {
                Text("Goal text and generated tool titles are sent to OpenAI using your ChatGPT plan.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if account.busy {
                    ProgressView("Connecting…")
                    if account.isSigningIn {
                        Button("Cancel sign-in") { account.cancelSignIn() }
                    }
                } else {
                    Button("Continue with ChatGPT") {
                        editing = false
                        Task { await account.signIn(profile: account.active) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .accessibilityIdentifier("connect-chatgpt")
                }
            } else if account.busy {
                ProgressView("Loading models…")
            } else {
                Button("Reload models") { Task { await account.reloadModels() } }
                    .buttonStyle(.bordered)
            }
            if let error = account.error { Text(error).font(.footnote) }
        }
    }

    private var settings: some View {
        NavigationStack {
            Form {
                Section("ChatGPT") {
                    if let profile = account.active, account.connected {
                        Text(profile.label).textSelection(.enabled)
                        Button("Reconnect ChatGPT") { Task { await account.signIn(profile: profile) } }
                        if !account.models.isEmpty {
                            Picker("Model", selection: $account.selectedModel) {
                                ForEach(account.models) { model in Text(model.displayName).tag(model.slug) }
                            }
                            Button("Reload models") { Task { await account.reloadModels() } }
                        }
                        Link("Manage usage", destination: usageURL)
                        Button("Sign out", role: .destructive) { Task { await account.signOut() } }
                            .disabled(controller.active)
                    }
                    if !account.connected || account.models.isEmpty { connection }
                    else if let error = account.error { Text(error).font(.footnote) }
                    ForEach(account.saved.profiles.filter { $0.id != account.active?.id }) { profile in
                        Button(profile.label) { Task { await account.activate(profile) } }
                            .disabled(controller.active)
                    }
                    if !account.saved.profiles.isEmpty {
                        Button("Add ChatGPT account") { Task { await account.signIn() } }
                            .disabled(controller.active)
                    }
                }
                .disabled(controller.current?.phase == .running || (account.busy && account.connected))

                Section("Goal") {
                    Stepper("Step limit \(controller.stepLimit)", value: $controller.stepLimit, in: 1...100)
                }
                .disabled(controller.active)
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { showingSettings = false } }
            }
        }
    }

    private func runSummary(_ run: GoalRun) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(run.phase.title).font(.headline)
                Spacer()
                Text("Steps \(run.steps) · Tokens \(run.tokens)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if !run.artifacts.isEmpty {
                VStack(spacing: 0) {
                    ForEach(run.artifacts) { artifact in
                        if artifact.id != run.artifacts.first?.id { Divider() }
                        NavigationLink(value: ToolRoute(run: run.id, artifact: artifact.id)) {
                            HStack(spacing: 12) {
                                Image(systemName: artifact.kind.icon).frame(width: 24)
                                VStack(alignment: .leading) {
                                    Text(artifact.title)
                                    Text(artifact.kind.title).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.forward").font(.caption).foregroundStyle(.secondary)
                            }.frame(minHeight: 50).padding(.horizontal, 12)
                        }.buttonStyle(.plain)
                    }
                }
                .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 12))
            }
            if !run.logs.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("LOG").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Spacer()
                        ShareLink(item: run.transcript) {
                            Label("Share log", systemImage: "square.and.arrow.up").labelStyle(.iconOnly)
                                .frame(minWidth: 44, minHeight: 44)
                        }
                    }
                    Text(run.logs.joined(separator: "\n"))
                        .font(.footnote)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    @ViewBuilder private var history: some View {
        let previous = controller.history.filter { $0.id != controller.current?.id }
        if !previous.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("History").font(.headline).padding(.bottom, 8)
                ForEach(previous) { run in
                    if run.id != previous.first?.id { Divider() }
                    NavigationLink(value: run.id) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(run.goal)
                                Text(run.date.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.forward").font(.caption)
                        }.padding(.vertical, 9).frame(minHeight: 44)
                    }.buttonStyle(.plain)
                }
            }
        }
    }
}

private struct ToolRoute: Hashable {
    let run: UUID
    let artifact: UUID
}

private struct ToolView: View {
    let artifact: Artifact
    let onChange: (Artifact) -> Void
    @State private var values = ""
    @State private var result: Double?
    @State private var calculationError = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !artifact.body.isEmpty { Text(artifact.body).textSelection(.enabled) }
                if artifact.kind == .checklist {
                    ForEach(artifact.items.indices, id: \.self) { index in
                        Button {
                            var next = artifact
                            if !next.checked.insert(index).inserted { next.checked.remove(index) }
                            onChange(next)
                        } label: {
                            Label(artifact.items[index], systemImage: artifact.checked.contains(index) ? "checkmark.square" : "square")
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(artifact.checked.contains(index) ? .isSelected : [])
                    }
                }
                if let operation = artifact.operation {
                    Text(operation.title).font(.headline)
                    TextField("Numbers separated by spaces or commas", text: $values, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: values) { _, _ in result = nil; calculationError = false }
                    Button("Calculate") {
                        do {
                            let entries = values.split { $0.isWhitespace || $0 == "," }
                            let numbers = entries.compactMap { Double($0) }
                            guard entries.count == numbers.count else { throw AppError.invalidNumbers }
                            result = try operation.evaluate(numbers)
                            calculationError = false
                        } catch {
                            result = nil
                            calculationError = true
                        }
                    }.buttonStyle(.bordered)
                    if let result { Text(result.formatted(.number.precision(.significantDigits(1...15)))).textSelection(.enabled) }
                    if calculationError { Text(AppError.invalidNumbers.localizedDescription).font(.footnote) }
                }
            }
            .padding(16)
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(artifact.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: artifact.exportText) {
                    Label("Share tool", systemImage: "square.and.arrow.up").labelStyle(.iconOnly)
                }
            }
        }
    }
}
