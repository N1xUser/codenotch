import Foundation
import SQLite3
import os
/// Gemini, as Antigravity sees it.
///
/// **What this can and cannot report, and why.** Antigravity talks to Google's
/// Cloud Code backend, and the only call that describes the account is
/// `:loadCodeAssist`. It answers with tiers — which plan you are on and which
/// you are not eligible for — and no numbers: no used, no limit, no reset. A
/// packet capture of a signed-in install showed exactly two RPCs, and neither
/// carries a quota.
///
/// So this provider reports the account honestly and says there is nothing
/// metered, rather than inventing a ring. That is the same answer Cursor's free
/// plan gets, and for the same reason: a confident 0% is worse than an admitted
/// blank, especially in something people pay for.
actor AntigravityProvider: UsageProvider {
    nonisolated let profile: AntigravityProfile
    nonisolated let id: String
    // The id stays `gemini` for default profile: it keys the archive and the user's connection
    // choice, and changing it would silently discard both. Additional profiles are `antigravity-<slug>`.
    nonisolated let displayName: String
    nonisolated let glyph = ProviderGlyph.antigravity

    /// The production host. Antigravity itself also calls a `daily-` variant,
    /// which answers 403 to this token — so it is not a fallback, it is a
    /// different audience.
    private let endpoint = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")!
    /// The real usage figure — served by Cloud Code PA.
    private let quotaEndpoint = URL(string: "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary")!
    private let prodQuotaEndpoint = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary")!
    private let session: URLSession
    /// A second session, trusting loopback only, for the local language server.
    private let localSession: URLSession
    /// Re-discovering the port and token means spawning `ps` and `lsof`, which
    /// is not something to do every minute. Cached until it stops working.
    private var bridge: AntigravityBridge.Endpoint?
    /// Whether the language server has ever answered.
    ///
    /// Once it has, a failure is Antigravity being closed or restarted — its
    /// port changes every launch — not an account that cannot be read. Falling
    /// back to the request count then *replaces* a percentage with a plain
    /// number, and a ring that reads 8% one minute and 31 the next looks broken
    /// rather than degraded.
    private var everBridged = false

    /// How the language server is asked, when a test needs to say. Production
    /// leaves this nil and goes through `localQuota()`, which spawns `ps` and
    /// `lsof` to find a port that only exists while Antigravity is running —
    /// nothing a test can arrange, and the ordering this fixes is exactly what
    /// would otherwise go uncovered.
    private let localQuotaOverride: (@Sendable () async -> [LimitWindow]?)?

    init(profile: AntigravityProfile = .default(),
         session: URLSession = .shared,
         localQuota: (@Sendable () async -> [LimitWindow]?)? = nil) {
        self.profile = profile
        self.id = profile.id
        self.displayName = profile.displayName
        self.session = session
        self.localQuotaOverride = localQuota
        self.localSession = URLSession(configuration: .ephemeral,
                                       delegate: LocalhostTrust(),
                                       delegateQueue: nil)
    }

    nonisolated var signInRoute: SignInRoute {
        profile.signInRoute
    }

    /// Reached only from "Allow access…", so it may let the next read prompt.
    nonisolated func forgetCachedCredential() {
        AntigravityCredentials.forgetCached(for: profile)
        AntigravityCredentials.askAgain(for: profile)
    }

    nonisolated func account() -> ProviderAccount? {
        if AntigravityCredentials.isSignedIn(for: profile), let held = AntigravityCredentials.held(for: profile) {
            let email = held.email
            let plan = held.authMethod == "consumer" ? L10n.t("Personal") : held.authMethod
            let source = held.sourceName ?? profile.sourceName
            return ProviderAccount(
                label: email,
                plan: plan,
                source: source,
                manageURL: URL(string: "https://antigravity.google")
            )
        }

        if profile.slug == nil && UserDefaults.standard.bool(forKey: "AntigravityEverBridged") {
            return ProviderAccount(
                label: L10n.t("Local Session"),
                plan: L10n.t("Active"),
                source: "Antigravity IDE",
                manageURL: nil
            )
        }

        return nil
    }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        // Fast test bypass for bridge tests
        if let localQuotaOverride {
            if let windows = await localQuotaOverride() {
                everBridged = true
                UserDefaults.standard.set(true, forKey: "AntigravityEverBridged")

                return ProviderSnapshot(id: id, displayName: displayName, glyph: glyph,
                                        fidelity: .official, status: .ok, windows: windows,
                                        headlineID: resolveHeadlineID(for: windows),
                                        weeklyID: resolveWeeklyID(for: windows))
            }

            if everBridged {
                throw UsageProviderError.credentialExpired
            }
        }

        if profile.slug != nil {
            var credentials = try? AntigravityCredentials.load(for: profile)
            if let creds = credentials, (creds.isExpired || creds.accessToken.isEmpty), creds.refreshToken != nil {
                if let refreshed = try? await AntigravityCredentials.refresh(credentials: creds, session: session) {
                    credentials = refreshed
                    AntigravityCredentials.updateHeld(refreshed, for: profile)
                }
            }
            if let credentials,
               let windows = try? await quota(token: credentials.accessToken,
                                              project: credentials.projectId,
                                              isACP: false),
               !windows.isEmpty {
                return ProviderSnapshot(id: id, displayName: displayName, glyph: glyph,
                                        fidelity: .official, status: .ok, windows: windows,
                                        headlineID: resolveHeadlineID(for: windows),
                                        weeklyID: resolveWeeklyID(for: windows))
            }
        } else {
            let processTable = AntigravityBridge.run("/bin/ps", ["-Ao", "pid,command"])
            let runningFlavors = AntigravityFlavor.runningFlavors(processTable: processTable)

            // 1. Query token / credentials for each flavor: IDE, CLI, ACP
            var candidates: [FlavorCandidate] = []
            for flavor in AntigravityFlavor.allCases {
                let isRunning = runningFlavors.contains(flavor)
                let creds = try? AntigravityCredentials.load(for: flavor, profile: profile)
                let lastActivity = flavor.lastActivityDate()
                let canProvide = isRunning || (creds != nil && (!creds!.isExpired || creds!.refreshToken != nil))
                let isActive = isRunning || (canProvide && (lastActivity != nil || (creds != nil && !creds!.isExpired)))
                candidates.append(FlavorCandidate(
                    flavor: flavor,
                    credentials: creds,
                    isRunning: isRunning,
                    lastActivity: lastActivity,
                    canProvideQuota: canProvide,
                    isActive: isActive
                ))
            }

            // 2. Only active ones get fetched from
            let activeCandidates = candidates.filter { $0.isActive && $0.canProvideQuota }

            // 3. If 2 or more are active, rank them to decide which one to fetch from
            let ranked = AntigravityFlavor.rankCandidates(activeCandidates)

            for candidate in ranked {
                if let snapshot = await tryFetchQuota(for: candidate, processTable: processTable) {
                    return snapshot
                }
            }
        }

        // 4. Fallback to OMP SQLite store if offline or direct call fails
        if profile.slug == nil {
            let ompWindows = Self.ompUsageWindows(forEmail: AntigravityCredentials.held(for: profile)?.email)
            if !ompWindows.isEmpty {
                return ProviderSnapshot(id: id, displayName: displayName, glyph: glyph,
                                        fidelity: .official, status: .ok, windows: ompWindows,
                                        headlineID: resolveHeadlineID(for: ompWindows),
                                        weeklyID: resolveWeeklyID(for: ompWindows))
            }
        }

        if everBridged { throw UsageProviderError.credentialExpired }

        // 5. Final fallback: request count activity from transcripts
        let roots = profile.slug == nil ? AntigravityActivity.transcriptRoots : [profile.brainDirectory]
        let activity = AntigravityActivity.read(roots: roots)
        return ProviderSnapshot(
            id: id,
            displayName: displayName,
            glyph: glyph,
            fidelity: .derived,
            status: .ok,
            windows: [
                LimitWindow(id: "requests",
                            label: activity.label(),
                            used: activity.requestsToday)
            ],
            headlineID: "requests"
        )
    }

    private func tryFetchQuota(for candidate: FlavorCandidate, processTable: String) async -> ProviderSnapshot? {
        switch candidate.flavor {
        case .ide:
            if candidate.isRunning || AntigravityBridge.discover(processTable: processTable) != nil {
                if let windows = await localQuota(processTable: processTable), !windows.isEmpty {
                    everBridged = true
                    UserDefaults.standard.set(true, forKey: "AntigravityEverBridged")
                    return ProviderSnapshot(id: id, displayName: displayName, glyph: glyph,
                                            fidelity: .official, status: .ok, windows: windows,
                                            headlineID: resolveHeadlineID(for: windows),
                                            weeklyID: resolveWeeklyID(for: windows))
                }
            }
            if let creds = candidate.credentials {
                var activeCreds = creds
                if (activeCreds.isExpired || activeCreds.accessToken.isEmpty) && activeCreds.refreshToken != nil {
                    if let refreshed = try? await AntigravityCredentials.refresh(credentials: activeCreds, session: session) {
                        activeCreds = refreshed
                        AntigravityCredentials.updateHeld(refreshed, for: .ide, profile: profile)
                    }
                }
                if !activeCreds.isExpired,
                   let windows = try? await quota(token: activeCreds.accessToken, project: activeCreds.projectId, isACP: false),
                   !windows.isEmpty {
                    AntigravityCredentials.updateHeld(activeCreds, for: .ide, profile: profile)
                    return ProviderSnapshot(id: id, displayName: displayName, glyph: glyph,
                                            fidelity: .official, status: .ok, windows: windows,
                                            headlineID: resolveHeadlineID(for: windows),
                                            weeklyID: resolveWeeklyID(for: windows))
                }
            }
            return nil

        case .cli:
            if candidate.isRunning, let bridge = AntigravityBridge.discover(processTable: processTable) {
                if let windows = try? await AntigravityBridge.quota(from: bridge, session: localSession), !windows.isEmpty {
                    everBridged = true
                    UserDefaults.standard.set(true, forKey: "AntigravityEverBridged")
                    return ProviderSnapshot(id: id, displayName: displayName, glyph: glyph,
                                            fidelity: .official, status: .ok, windows: windows,
                                            headlineID: resolveHeadlineID(for: windows),
                                            weeklyID: resolveWeeklyID(for: windows))
                }
            }
            if let creds = candidate.credentials {
                var activeCreds = creds
                if (activeCreds.isExpired || activeCreds.accessToken.isEmpty) && activeCreds.refreshToken != nil {
                    if let refreshed = try? await AntigravityCredentials.refresh(credentials: activeCreds, session: session) {
                        activeCreds = refreshed
                        AntigravityCredentials.updateHeld(refreshed, for: .cli, profile: profile)
                    }
                }
                if !activeCreds.isExpired,
                   let windows = try? await quota(token: activeCreds.accessToken, project: activeCreds.projectId, isACP: false),
                   !windows.isEmpty {
                    AntigravityCredentials.updateHeld(activeCreds, for: .cli, profile: profile)
                    return ProviderSnapshot(id: id, displayName: displayName, glyph: glyph,
                                            fidelity: .official, status: .ok, windows: windows,
                                            headlineID: resolveHeadlineID(for: windows),
                                            weeklyID: resolveWeeklyID(for: windows))
                }
            }
            return nil

        case .acp:
            if let creds = candidate.credentials {
                var activeCreds = creds
                if (activeCreds.isExpired || activeCreds.accessToken.isEmpty) && activeCreds.refreshToken != nil {
                    if let refreshed = try? await AntigravityCredentials.refresh(credentials: activeCreds, session: session) {
                        activeCreds = refreshed
                        AntigravityCredentials.updateHeld(refreshed, for: .acp, profile: profile)
                    }
                }
                if !activeCreds.isExpired,
                   let windows = try? await quota(token: activeCreds.accessToken, project: activeCreds.projectId, isACP: true),
                   !windows.isEmpty {
                    AntigravityCredentials.updateHeld(activeCreds, for: .acp, profile: profile)
                    return ProviderSnapshot(id: id, displayName: displayName, glyph: glyph,
                                            fidelity: .official, status: .ok, windows: windows,
                                            headlineID: resolveHeadlineID(for: windows),
                                            weeklyID: resolveWeeklyID(for: windows))
                }
            }
            return nil
        }
    }

    nonisolated func resolveHeadlineID(for windows: [LimitWindow]) -> String {
        let preferredLimit = Preferences.storedAntigravityHeadlineLimit()
        let preferredModel = Preferences.storedAntigravityHeadlineModel()
        let modelCandidates = windows.filter { $0.id.hasPrefix(preferredModel.rawValue) }
        let candidates = modelCandidates.isEmpty ? windows : modelCandidates

        if preferredLimit != .automatic {
            let limitCandidates = candidates.filter { matches($0, cadence: preferredLimit) }
            if let mostConstrained = limitCandidates.max(by: constrainedBefore) {
                return mostConstrained.id
            }
        }

        // Match CodexBar's default: an exhausted lane does not displace a
        // usable lane unless every lane is exhausted.
        let fractional = candidates.filter { $0.usedFraction != nil }
        let usable = fractional.filter { ($0.usedFraction ?? 0) < 1 }
        return (usable.isEmpty ? fractional : usable).max(by: constrainedBefore)?.id
            ?? candidates.first?.id
            ?? "\(preferredModel.rawValue)-hourly"
    }

    private nonisolated func matches(_ window: LimitWindow, cadence: AntigravityHeadlineLimit) -> Bool {
        let value = "\(window.id) \(window.label)".lowercased()
        switch cadence {
        case .fiveHour:
            return window.duration == 5 * 3600 ||
                ["5h", "5-hour", "five hour", "five-hour", "hourly", "session"]
                    .contains(where: { value.contains($0) })
        case .weekly:
            return window.duration == 7 * 86400 || value.contains("weekly")
        case .automatic:
            return true
        }
    }

    private nonisolated func constrainedBefore(_ lhs: LimitWindow, _ rhs: LimitWindow) -> Bool {
        let left = lhs.usedFraction ?? 0
        let right = rhs.usedFraction ?? 0
        if left != right { return left < right }
        return lhs.id > rhs.id
    }

    nonisolated func resolveWeeklyID(for windows: [LimitWindow]) -> String? {
        let preferredModel = Preferences.storedAntigravityHeadlineModel()
        let modelCandidates = windows.filter { $0.id.hasPrefix(preferredModel.rawValue) }
        let candidates = modelCandidates.isEmpty ? windows : modelCandidates
        let weekly = candidates.filter { window in
            window.duration == 7 * 86400 ||
                window.id.lowercased().hasSuffix("-weekly") ||
                window.label.lowercased().contains("weekly")
        }
        return weekly.max(by: constrainedBefore)?.id
    }

    /// Ask Antigravity's language server, if it is running.
    ///
    /// Returns nil rather than throwing when it is not: Antigravity being
    /// closed is the ordinary case, not a fault, and the caller has an honest
    /// answer to fall back to.
    private func localQuota(processTable: String? = nil) async -> [LimitWindow]? {
        if let localQuotaOverride { return await localQuotaOverride() }
        if let bridge {
            do {
                let windows = try await AntigravityBridge.quota(from: bridge, session: localSession)
                if !windows.isEmpty { return windows }
            } catch {
                Log.usage.debug("Antigravity cached bridge endpoint gone: \(String(describing: error), privacy: .public)")
                self.bridge = nil
            }
        }
        guard let fresh = await resolveEndpoint(processTable: processTable) else {
            Log.usage.debug("Antigravity localQuota discover failed to find process")
            return nil
        }
        self.bridge = fresh
        do {
            return try await AntigravityBridge.quota(from: fresh, session: localSession)
        } catch {
            Log.usage.debug("Antigravity localQuota fresh bridge error: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Where to ask: the IDE's own server while it runs, otherwise one we start.
    private func resolveEndpoint(processTable: String? = nil) async -> AntigravityBridge.Endpoint? {
        if let running = AntigravityBridge.discover(processTable: processTable) { return running }

        guard let binary = AntigravityBridge.serverBinaryURL(),
              AntigravityBridge.owned.endpointOrStart(binary: binary) != nil,
              let pid = AntigravityBridge.owned.pid
        else { return nil }

        for _ in 0..<40 {
            let ports = AntigravityBridge.listeningPorts(ofPID: Int(pid))
            if !ports.isEmpty {
                AntigravityBridge.owned.resolvePorts(ports)
                return AntigravityBridge.owned.current
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        Log.usage.debug("Antigravity: started server never bound a port")
        return nil
    }

    /// Ask for the account's quota, returning nil when it is not allowed to.
    private func quota(token: String, project: String? = nil, isACP: Bool = false) async throws -> [LimitWindow]? {
        let candidateEndpoints = isACP ? [prodQuotaEndpoint, quotaEndpoint] : [quotaEndpoint, prodQuotaEndpoint]
        for url in candidateEndpoints {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let ua = isACP
                ? "antigravity/acp/1.4.1 (aidev_client; os_type=darwin; arch=arm64; proxy_client=antigravity/sdk)"
                : "antigravity/hub/2.8.0 (aidev_client; os_type=darwin; arch=arm64; cl=963137146)"
            request.setValue(ua, forHTTPHeaderField: "User-Agent")
            request.setValue("ideType=IDE_UNSPECIFIED,platform=PLATFORM_UNSPECIFIED,pluginType=GEMINI", forHTTPHeaderField: "Client-Metadata")
            let bodyObj: [String: Any] = (project != nil && !project!.isEmpty) ? ["project": project!] : [:]
            request.httpBody = try? JSONSerialization.data(withJSONObject: bodyObj)
            request.timeoutInterval = 15

            if let (data, response) = try? await session.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                let parsed = Self.windows(in: data)
                if !parsed.isEmpty { return parsed }
            }
        }
        return nil
    }

    /// Turns a quota summary into standard limit windows.
    nonisolated static func windows(in data: Data, now: Date = Date()) -> [LimitWindow] {
        AntigravityQuotaParser.parse(data, now: now)
    }

    static func ompUsageWindows(forEmail email: String? = nil) -> [LimitWindow] {
        let dbURL = URL(fileURLWithPath: ("~/.omp/agent/agent.db" as NSString).expandingTildeInPath)
        guard let db = SQLiteStore.open(dbURL) else { return [] }
        defer { sqlite3_close(db) }

        var targetEmail = email
        if targetEmail == nil {
            let sql = "SELECT email FROM usage_history WHERE provider = 'google-antigravity' AND email IS NOT NULL AND email != '' ORDER BY recorded_at DESC, id DESC LIMIT 1;"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                if sqlite3_step(stmt) == SQLITE_ROW, let em = sqlite3_column_text(stmt, 0) {
                    targetEmail = String(cString: em)
                }
                sqlite3_finalize(stmt)
            }
        }

        let sql = """
        SELECT model_id, duration_label, remaining_fraction, reset_at
        FROM usage_history
        WHERE provider = 'google-antigravity'
        ORDER BY recorded_at DESC, id DESC
        LIMIT 10;
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        var windows: [LimitWindow] = []
        var seenIDs = Set<String>()

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let model = sqlite3_column_text(stmt, 0),
                  let duration = sqlite3_column_text(stmt, 1) else { continue }
            let modelID = String(cString: model)
            let durationLabel = String(cString: duration)
            let remaining = sqlite3_column_double(stmt, 2)
            let resetText = sqlite3_column_text(stmt, 3).map { String(cString: $0) }

            let windowID = "\(modelID)-\(durationLabel)"
            guard !seenIDs.contains(windowID) else { continue }
            seenIDs.insert(windowID)

            let isWeekly = durationLabel.lowercased().contains("week")
            let durationSecs: TimeInterval = isWeekly ? 7 * 86400 : 5 * 3600
            let usedFraction = max(0.0, min(1.0, 1.0 - remaining))
            let resetsAt = resetText.flatMap { ISO8601DateFormatter().date(from: $0) }

            let group = modelID.lowercased().contains("gemini") ? "Gemini Models" : "Claude and GPT models"
            let label = isWeekly ? "Weekly Limit" : "5-hour Limit"

            windows.append(LimitWindow(
                id: windowID,
                group: group,
                label: label,
                usedFraction: usedFraction,
                resetsAt: resetsAt,
                duration: durationSecs
            ))
        }

        return windows
    }

    /// Read the plan name from `loadCodeAssist`.
    static func tier(in data: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "Gemini"
        }
        if let current = json["currentTier"] as? [String: Any],
           let name = current["name"] as? String, !name.isEmpty {
            return name
        }
        if let allowed = json["allowedTiers"] as? [[String: Any]] {
            if let def = allowed.first(where: { ($0["isDefault"] as? Bool) == true }),
               let name = def["name"] as? String, !name.isEmpty {
                return name
            }
            if let first = allowed.first,
               let name = first["name"] as? String, !name.isEmpty {
                return name
            }
        }
        return "Gemini"
    }
}
