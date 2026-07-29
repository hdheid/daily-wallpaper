import Foundation
import OSLog

enum UpdatePhase: Equatable {
    case idle
    case checking
    case downloading
    case applying
    case success
    case failed
}

struct UpdateStatus {
    let phase: UpdatePhase
    let message: String
    let isBusy: Bool
}

@MainActor
final class UpdateCoordinator {
    var onStatusChange: ((UpdateStatus) -> Void)?

    private let settings: SettingsStore
    private let displayRegistry: DisplayRegistry
    private let directoryManager: DownloadDirectoryManager
    private let bingService: BingImageProviding
    private let store: WallpaperStore
    private let index: MediaLibraryIndex
    private let pendingIndexQueue: PendingIndexQueue
    private let applier: WallpaperApplier
    private let retryTimer: RetryTimer
    private let logger = Logger(subsystem: "com.liuhao.DailyWallpaper", category: "Update")

    private(set) var status = UpdateStatus(phase: .idle, message: "等待更新", isBusy: false)
    private var updateTask: Task<Void, Never>?
    private var pendingManualTrigger: UpdateTrigger?
    private var pendingAutomaticTrigger: UpdateTrigger?
    private var pendingSpaceReapply = false
    private var isLibraryMutationInProgress = false
    private var isShuttingDown = false
    private var consecutiveFailureCount = 0

    private enum CachedApplyOutcome {
        case missing
        case success
        case staleConfiguration
        case failed([String])
    }

    init(
        settings: SettingsStore,
        displayRegistry: DisplayRegistry,
        directoryManager: DownloadDirectoryManager,
        bingService: BingImageProviding,
        store: WallpaperStore,
        index: MediaLibraryIndex,
        pendingIndexQueue: PendingIndexQueue,
        applier: WallpaperApplier,
        retryTimer: RetryTimer
    ) {
        self.settings = settings
        self.displayRegistry = displayRegistry
        self.directoryManager = directoryManager
        self.bingService = bingService
        self.store = store
        self.index = index
        self.pendingIndexQueue = pendingIndexQueue
        self.applier = applier
        self.retryTimer = retryTimer
    }

    func trigger(_ trigger: UpdateTrigger) {
        guard !isShuttingDown else { return }
        if isLibraryMutationInProgress {
            if trigger == .spaceChanged {
                pendingSpaceReapply = true
            } else {
                enqueuePending(trigger)
            }
            return
        }
        if trigger == .spaceChanged {
            if updateTask == nil {
                reapplyCurrentWallpapers()
            } else {
                pendingSpaceReapply = true
            }
            return
        }

        guard updateTask == nil else {
            // 系统事件到达下载窗口时不能直接丢弃，否则跨日或新显示器可能整天漏更。
            enqueuePending(trigger)
            return
        }

        start(trigger)
    }

    private func start(_ trigger: UpdateTrigger) {
        updateTask = Task { [weak self] in
            guard let self else { return }
            await self.run(trigger: trigger)
            self.bingService.releaseIdleResources()
            self.finishCurrentTask()
        }
        // Task 已登记就同步发布占用状态，消除任务启动与首次 await 之间的 UI 可用窗口。
        publish(.checking, "正在准备更新…", busy: true)
    }

    func cancel() {
        isShuttingDown = true
        updateTask?.cancel()
        updateTask = nil
        pendingManualTrigger = nil
        pendingAutomaticTrigger = nil
        pendingSpaceReapply = false
        retryTimer.cancel()
    }

    /// 删除媒体文件期间暂停所有下载与重新应用；期间到达的触发会合并并在删除完成后执行。
    func setLibraryMutationInProgress(_ isInProgress: Bool) {
        guard isLibraryMutationInProgress != isInProgress else { return }
        isLibraryMutationInProgress = isInProgress
        if !isInProgress, updateTask == nil {
            finishCurrentTask()
        }
    }

    func shutdown() async {
        let task = updateTask
        cancel()
        await task?.value
    }

    private func enqueuePending(_ trigger: UpdateTrigger) {
        if trigger.isManual {
            pendingManualTrigger = UpdateTriggerCoalescer.merge(pendingManualTrigger, with: trigger)
        } else {
            pendingAutomaticTrigger = UpdateTriggerCoalescer.merge(pendingAutomaticTrigger, with: trigger)
        }
    }

    private func finishCurrentTask() {
        updateTask = nil
        guard !isShuttingDown, !isLibraryMutationInProgress else { return }

        if let next = pendingManualTrigger {
            pendingManualTrigger = nil
            start(next)
            return
        }
        if let next = pendingAutomaticTrigger {
            pendingAutomaticTrigger = nil
            start(next)
            return
        }
        if pendingSpaceReapply {
            pendingSpaceReapply = false
            reapplyCurrentWallpapers()
        }
    }

    func applyLibraryItem(_ item: MediaLibraryItem, displayUUIDs: [String]?) {
        // 下载任务持有活动目录租约时不能穿插媒体库应用，否则会提前发布空闲状态并重新开放目录操作。
        guard updateTask == nil, !isShuttingDown, !isLibraryMutationInProgress else { return }
        guard let imageURL = try? directoryManager.imageURL(rootID: item.rootID, relativePath: item.relativeImagePath) else {
            publish(.failed, "图片文件当前不可访问", busy: false)
            return
        }
        let targets = displayUUIDs ?? displayRegistry.refresh().map(\.uuid)
        let scaling = Dictionary(uniqueKeysWithValues: targets.map { ($0, settings.profile(for: $0).scaling) })
        publish(.applying, "正在设置媒体库图片…", busy: true)
        let result = applier.apply(imageURL: imageURL, to: targets, scalingByDisplay: scaling)
        recordApplied(
            rootID: item.rootID,
            relativeImagePath: item.relativeImagePath,
            contentSHA256: item.contentSHA256,
            title: item.title,
            copyrightText: item.copyrightText,
            scalingByDisplay: scaling,
            result: result
        )
        publish(
            result.hasFailures ? .failed : .success,
            result.hasFailures ? "部分显示器设置失败" : "壁纸已更换",
            busy: false
        )
    }

    private func run(trigger: UpdateTrigger) async {
        if trigger == .screensChanged {
            displayRegistry.refresh()
        }

        if !trigger.isManual, !settings.automaticDailyDownloadEnabled {
            if trigger == .screensChanged || trigger == .settingsChanged {
                reapplyCurrentWallpapers(useConfiguredScaling: trigger == .settingsChanged)
            }
            publish(.idle, "每日自动下载已关闭", busy: false)
            return
        }

        publish(.checking, "正在检查今日图片…", busy: true)
        let startingConfigurationRevision = settings.configurationRevision
        let displays = displayRegistry.refresh()
        let requests = UpdatePlanBuilder.buildRequests(
            mode: settings.configurationMode,
            sharedProfile: settings.sharedProfile,
            assignments: settings.displayAssignments,
            displays: displays
        )
        guard !requests.isEmpty else {
            publish(.failed, "未检测到可用显示器", busy: false)
            return
        }

        let shouldApply = trigger.shouldApplyDownloadedImage
            || (!trigger.isManual && settings.automaticDailyApplyEnabled)
        let dayKey = LocalDay.key()
        var networkRequests: [ResolvedProfileRequest] = []
        var errors: [String] = []

        for request in requests {
            let alreadyDownloaded = !trigger.isManual
                && settings.wasDownloaded(configurationFingerprint: request.fingerprint, on: dayKey)
            if alreadyDownloaded {
                if shouldApply {
                    switch await applyCached(
                        request: request,
                        automatic: !trigger.isManual,
                        expectedConfigurationRevision: startingConfigurationRevision
                    ) {
                    case .missing:
                        // 当日标记存在但缓存文件被用户删除时，重新下载才能恢复完整状态。
                        networkRequests.append(request)
                    case .success:
                        break
                    case .staleConfiguration:
                        enqueuePending(.settingsChanged)
                        publish(.checking, "配置已变化，正在重新检查…", busy: false)
                        return
                    case let .failed(applyErrors):
                        // 本地文件仍然可用，后续只安排低频重试，绝不重复消耗网络。
                        errors.append(contentsOf: applyErrors)
                    }
                }
            } else {
                networkRequests.append(request)
            }
        }

        if networkRequests.isEmpty {
            if errors.isEmpty {
                consecutiveFailureCount = 0
                retryTimer.cancel()
                publish(.success, shouldApply ? "今日图片已同步" : "今日图片已下载", busy: false)
            } else {
                publish(.failed, errors.first ?? "壁纸设置失败", busy: false)
                scheduleRetryIfNeeded(manual: trigger.isManual)
            }
            return
        }

        var deferredForNewConfiguration = false
        do {
            let root = try directoryManager.ensureActiveRoot()
            try directoryManager.beginWriteLease(rootID: root.root.id)
            defer { directoryManager.endWriteLease(rootID: root.root.id) }
            var candidateByMarket: [String: BingImageCandidate] = [:]
            // 这里只复用图片字节，绝不能复用第一国家的标题、介绍和归档路径。
            var reusableImageByProviderAndVariant: [String: StoredWallpaper] = [:]

            for (indexInBatch, request) in networkRequests.enumerated() {
                try Task.checkCancellation()
                let market = request.profile.normalizedMarket
                let candidate: BingImageCandidate
                do {
                    if let cached = candidateByMarket[market] {
                        candidate = cached
                    } else {
                        candidate = try await bingService.fetchCandidate(market: market)
                        candidateByMarket[market] = candidate
                    }
                    try Task.checkCancellation()
                    if automaticConfigurationChanged(
                        since: startingConfigurationRevision,
                        trigger: trigger
                    ) {
                        enqueuePending(.settingsChanged)
                        deferredForNewConfiguration = true
                        break
                    }

                    publish(
                        .downloading,
                        "正在下载 \(indexInBatch + 1)/\(networkRequests.count)：\(candidate.title)",
                        busy: true
                    )
                    let providerKey = "\(candidate.providerHash ?? candidate.urlBase)|\(request.variant.rawValue)"
                    let stored: StoredWallpaper
                    if let cached = reusableImageByProviderAndVariant[providerKey] {
                        stored = try await store.archiveDownloaded(
                            candidate: candidate,
                            reusing: cached,
                            requestedMarket: market,
                            recordedAt: Date(),
                            in: root
                        )
                    } else {
                        let downloaded = try await bingService.download(candidate: candidate, variant: request.variant)
                        try Task.checkCancellation()
                        if automaticConfigurationChanged(
                            since: startingConfigurationRevision,
                            trigger: trigger
                        ) {
                            try? FileManager.default.removeItem(at: downloaded.temporaryFileURL)
                            enqueuePending(.settingsChanged)
                            deferredForNewConfiguration = true
                            break
                        }
                        stored = try await store.archiveDownloaded(
                            DownloadArchiveRequest(
                                temporaryFileURL: downloaded.temporaryFileURL,
                                sourceURL: downloaded.sourceURL,
                                mimeType: downloaded.mimeType,
                                candidate: candidate,
                                requestedMarket: market,
                                recordedAt: Date()
                            ),
                            in: root
                        )
                        try Task.checkCancellation()
                        reusableImageByProviderAndVariant[providerKey] = stored
                    }

                    try Task.checkCancellation()
                    do {
                        _ = try await self.index.upsert(stored.metadata)
                        try? await pendingIndexQueue.remove(stored.metadata)
                        NotificationCenter.default.post(name: .dailyWallpaperLibraryDidChange, object: self)
                    } catch {
                        // 原图和旁车 JSON 已提交，持久队列会在下次启动补索引，避免重复网络下载。
                        do {
                            try await pendingIndexQueue.add(stored.metadata)
                        } catch {
                            logger.error("待索引队列写入失败：\(error.localizedDescription, privacy: .public)")
                        }
                        logger.error("媒体库索引写入失败：\(error.localizedDescription, privacy: .public)")
                    }

                    settings.setCachedWallpaper(CachedWallpaperRecord(
                        configurationFingerprint: request.fingerprint,
                        rootID: stored.metadata.rootID,
                        relativeImagePath: stored.metadata.relativeImagePath,
                        contentSHA256: stored.metadata.contentSHA256,
                        title: stored.metadata.title,
                        copyrightText: stored.metadata.copyrightText,
                        cachedAt: Date()
                    ))
                    settings.markDownloaded(configurationFingerprint: request.fingerprint, on: dayKey)
                    if LocalDay.key() != dayKey {
                        // 下载跨过本地零点时仍标记原任务日期，并立即补跑新一天。
                        enqueuePending(.calendarDayChanged)
                    }

                    if automaticConfigurationChanged(
                        since: startingConfigurationRevision,
                        trigger: trigger
                    ) {
                        enqueuePending(.settingsChanged)
                        deferredForNewConfiguration = true
                        break
                    }

                    if shouldApply {
                        let targets = eligibleTargets(for: request, automatic: !trigger.isManual)
                        if !targets.isEmpty {
                            publish(.applying, "正在应用：\(candidate.title)", busy: true)
                            let scaling = scalingMap(for: targets)
                            let result = applier.apply(
                                imageURL: stored.imageURL,
                                to: targets,
                                scalingByDisplay: scaling
                            )
                            recordApplied(
                                rootID: stored.metadata.rootID,
                                relativeImagePath: stored.metadata.relativeImagePath,
                                contentSHA256: stored.metadata.contentSHA256,
                                title: stored.metadata.title,
                                copyrightText: stored.metadata.copyrightText,
                                scalingByDisplay: scaling,
                                result: result
                            )
                            errors.append(contentsOf: result.failures.values)
                        }
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    errors.append("\(market)：\(error.localizedDescription)")
                }
            }
        } catch is CancellationError {
            publish(.idle, "更新已取消", busy: false)
            return
        } catch {
            errors.append(error.localizedDescription)
        }

        if deferredForNewConfiguration {
            publish(.checking, "配置已变化，正在重新检查…", busy: false)
            return
        }

        if errors.isEmpty {
            consecutiveFailureCount = 0
            retryTimer.cancel()
            publish(.success, shouldApply ? "今日壁纸已更新" : "今日图片已下载", busy: false)
        } else {
            publish(.failed, errors.first ?? "更新失败", busy: false)
            scheduleRetryIfNeeded(manual: trigger.isManual)
        }
    }

    private func applyCached(
        request: ResolvedProfileRequest,
        automatic: Bool,
        expectedConfigurationRevision: UInt64
    ) async -> CachedApplyOutcome {
        guard
            let cached = settings.cachedImageByConfiguration[request.fingerprint],
            let url = try? directoryManager.imageURL(rootID: cached.rootID, relativePath: cached.relativeImagePath),
            await store.isValidArchivedImage(url, expectedSHA256: cached.contentSHA256)
        else { return .missing }

        if automatic, settings.configurationRevision != expectedConfigurationRevision {
            return .staleConfiguration
        }
        let targets = eligibleTargets(for: request, automatic: automatic)
        guard !targets.isEmpty else { return .success }
        let scaling = scalingMap(for: targets)
        let result = applier.apply(imageURL: url, to: targets, scalingByDisplay: scaling)
        recordApplied(
            rootID: cached.rootID,
            relativeImagePath: cached.relativeImagePath,
            contentSHA256: cached.contentSHA256,
            title: cached.title,
            copyrightText: cached.copyrightText,
            scalingByDisplay: scaling,
            result: result
        )
        return result.hasFailures ? .failed(Array(result.failures.values)) : .success
    }

    private func reapplyCurrentWallpapers(useConfiguredScaling: Bool = false) {
        let displays = displayRegistry.refresh()
        let records = settings.currentImageByDisplayUUID

        // Space 切换只重放每块屏幕最后实际成功的记录，不能从字典随机挑一张覆盖全部屏幕。
        for display in displays {
            guard
                let record = records[display.uuid],
                let url = try? directoryManager.imageURL(rootID: record.rootID, relativePath: record.relativeImagePath)
            else { continue }
            let scaling = useConfiguredScaling ? settings.profile(for: display.uuid).scaling : record.scaling
            let result = applier.apply(
                imageURL: url,
                to: [display.uuid],
                scalingByDisplay: [display.uuid: scaling]
            )
            recordApplied(
                rootID: record.rootID,
                relativeImagePath: record.relativeImagePath,
                contentSHA256: record.contentSHA256,
                title: record.title,
                copyrightText: record.copyrightText,
                scalingByDisplay: [display.uuid: scaling],
                result: result
            )
        }
    }

    private func automaticConfigurationChanged(
        since revision: UInt64,
        trigger: UpdateTrigger
    ) -> Bool {
        !trigger.isManual && settings.configurationRevision != revision
    }

    private func eligibleTargets(for request: ResolvedProfileRequest, automatic: Bool) -> [String] {
        guard automatic else { return request.targetDisplayUUIDs }
        return request.targetDisplayUUIDs.filter { settings.profile(for: $0).automaticApplyEnabled }
    }

    private func scalingMap(for displayUUIDs: [String]) -> [String: WallpaperScaling] {
        Dictionary(uniqueKeysWithValues: displayUUIDs.map { ($0, settings.profile(for: $0).scaling) })
    }

    private func recordApplied(
        rootID: UUID,
        relativeImagePath: String,
        contentSHA256: String,
        title: String,
        copyrightText: String,
        scalingByDisplay: [String: WallpaperScaling],
        result: WallpaperApplySummary
    ) {
        let successfulDisplays = result.appliedDisplayUUIDs + result.skippedDisplayUUIDs
        for uuid in successfulDisplays {
            settings.setCurrentWallpaper(CurrentWallpaperRecord(
                displayUUID: uuid,
                rootID: rootID,
                relativeImagePath: relativeImagePath,
                contentSHA256: contentSHA256,
                title: title,
                copyrightText: copyrightText,
                scaling: scalingByDisplay[uuid] ?? .fill,
                updatedAt: Date()
            ))
        }
    }

    private func scheduleRetryIfNeeded(manual: Bool) {
        guard !manual else { return }
        consecutiveFailureCount += 1
        guard let entry = RetrySchedule.entry(afterFailure: consecutiveFailureCount) else { return }
        retryTimer.schedule(entry: entry) { [weak self] in
            self?.trigger(.wake)
        }
    }

    private func publish(_ phase: UpdatePhase, _ message: String, busy: Bool) {
        status = UpdateStatus(phase: phase, message: message, isBusy: busy)
        onStatusChange?(status)
    }
}
