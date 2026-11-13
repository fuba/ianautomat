import Foundation

@MainActor @Observable
final class GoalController {
    var draft = UserDefaults.standard.string(forKey: "goalDraft") ?? "" {
        didSet { UserDefaults.standard.set(draft, forKey: "goalDraft") }
    }
    var stepLimit = UserDefaults.standard.object(forKey: "stepLimit") as? Int ?? 100 {
        didSet { UserDefaults.standard.set(stepLimit, forKey: "stepLimit") }
    }
    private(set) var current: GoalRun?
    private(set) var history: [GoalRun] = []
    private(set) var error: String?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var budget = 0
    private let workspace = Workspace.local

    var active: Bool { current?.phase.active ?? false }
    var canStart: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draft.utf8.count <= 16_000 }

    func load() {
        do {
            history = try workspace.load().map { value in
                var run = value
                if run.phase == .running {
                    run.phase = .paused
                    run.logs.append(String(localized: "Execution was interrupted."))
                }
                return run
            }
            if current == nil { current = history.first }
        } catch {
            self.error = AppError.storage.localizedDescription
        }
    }

    func start(account: Account) {
        guard !active, canStart, account.connected, !account.selectedModel.isEmpty else { return }
        current = GoalRun(goal: draft.trimmingCharacters(in: .whitespacesAndNewlines))
        budget = min(100, max(1, stepLimit))
        begin(account: account)
    }

    func pause() {
        guard var run = current, run.phase == .running else { return }
        cancel()
        run.phase = .paused
        run.logs.append(String(localized: "Paused"))
        persist(run)
    }

    func stop() {
        guard var run = current, run.phase.active else { return }
        cancel()
        run.phase = .stopped
        run.logs.append(String(localized: "Stopped"))
        persist(run)
    }

    func resume(account: Account) {
        guard current?.phase.resumable == true, account.connected, !account.selectedModel.isEmpty else { return }
        if budget <= 0 { budget = min(100, max(1, stepLimit)) }
        begin(account: account)
    }

    func update(_ artifact: Artifact, in runID: UUID) {
        guard var run = history.first(where: { $0.id == runID }) ?? (current?.id == runID ? current : nil),
              let index = run.artifacts.firstIndex(where: { $0.id == artifact.id }) else { return }
        run.artifacts[index] = artifact
        persist(run)
    }

    private func begin(account: Account) {
        guard var run = current else { return }
        error = nil
        cancel()
        run.phase = .running
        run.logs.append(String(localized: "Running"))
        guard persist(run) else { return }
        let id = generation
        let model = account.selectedModel
        task = Task { [weak self] in
            await self?.execute(account: account, model: model, id: id)
        }
    }

    private func execute(account: Account, model: String, id: UUID) async {
        var failures = 0
        while !Task.isCancelled, generation == id, var run = current {
            guard budget > 0 else {
                run.phase = .limited
                run.logs.append(String(localized: "Step limit reached"))
                persist(run)
                return
            }
            budget -= 1
            run.steps += 1
            guard persist(run) else { return }
            do {
                let token = try await account.accessToken()
                try Task.checkCancellation()
                let language = Bundle.main.preferredLocalizations.first == "ja" ? "Japanese" : "English"
                let result = try await OpenAI.next(run: run, model: model, token: token, language: language)
                guard generation == id, !Task.isCancelled, let latest = current else { return }
                run = latest
                run.tokens += result.tokens ?? 0
                let action = try GoalAction.parse(result.text)
                if let artifact = action.artifact {
                    guard run.artifacts.count < 32 else { throw AppError.invalidTool }
                    if !run.artifacts.contains(where: { $0.kind == artifact.kind && $0.title == artifact.title }) {
                        run.artifacts.append(artifact)
                        run.logs.append(String(localized: "Created \(artifact.title)"))
                    }
                }
                if !action.message.isEmpty { run.logs.append(action.message) }
                if action.action == .done { run.phase = .completed }
                if action.action == .blocked { run.phase = .blocked }
                failures = 0
                guard persist(run), run.phase == .running else { return }
            } catch {
                guard generation == id, !Task.isCancelled else { return }
                if let latest = current {
                    run.artifacts = latest.artifacts
                    run.logs = latest.logs
                }
                let responseFailure = error as? ResponseFailure
                let retryAfter = responseFailure?.retryAfter ?? (error as? RetryAfter)?.seconds
                let networkError = (error as? URLError).map {
                    [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost].contains($0.code)
                } ?? false
                let retryable = networkError || (error as? AppError)?.retryable == true ||
                    (responseFailure?.retryable ?? (retryAfter.map { $0 <= 86_400 } ?? false))
                run.logs.append(displayError(error))
                if failures < 2, budget > 0, retryable {
                    let base = pow(2, Double(failures + 1))
                    let delay = retryAfter ?? base + Double.random(in: 0...0.5)
                    failures += 1
                    run.logs.append(String(localized: "Retrying…"))
                    guard persist(run) else { return }
                    do { try await Task.sleep(for: .seconds(delay)) }
                    catch { return }
                } else {
                    run.phase = .paused
                    persist(run)
                    return
                }
            }
        }
    }

    @discardableResult
    private func persist(_ run: GoalRun) -> Bool {
        do {
            try workspace.save(run)
            if current?.id == run.id { current = run }
            if let index = history.firstIndex(where: { $0.id == run.id }) { history[index] = run }
            else { history.insert(run, at: 0) }
            return true
        } catch {
            self.error = AppError.storage.localizedDescription
            if current?.id == run.id {
                var paused = run
                if paused.phase == .running { paused.phase = .paused }
                current = paused
            }
            return false
        }
    }

    private func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
    }
}
