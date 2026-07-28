import Foundation

enum UpdatePlanBuilder {
    static func buildRequests(
        mode: DisplayConfigurationMode,
        sharedProfile: WallpaperProfile,
        assignments: [String: WallpaperProfile],
        displays: [DisplayDescriptor]
    ) -> [ResolvedProfileRequest] {
        guard !displays.isEmpty else { return [] }

        switch mode {
        case .shared:
            let variant = resolveVariant(
                preference: sharedProfile.resolutionPreference,
                displays: displays
            )
            return [ResolvedProfileRequest(
                profile: sharedProfile,
                variant: variant,
                targetDisplayUUIDs: displays.map(\.uuid)
            )]

        case .individual:
            struct GroupKey: Hashable {
                let market: String
                let variant: ImageVariant
            }
            var grouped: [GroupKey: (profile: WallpaperProfile, displays: [String])] = [:]
            for display in displays {
                let profile = assignments[display.uuid] ?? .default
                let variant = resolveVariant(preference: profile.resolutionPreference, displays: [display])
                let key = GroupKey(market: profile.normalizedMarket.lowercased(), variant: variant)
                if grouped[key] == nil {
                    grouped[key] = (profile, [])
                }
                grouped[key]?.displays.append(display.uuid)
            }
            return grouped
                .map { key, value in
                    ResolvedProfileRequest(
                        profile: value.profile,
                        variant: key.variant,
                        targetDisplayUUIDs: value.displays
                    )
                }
                .sorted { $0.fingerprint < $1.fingerprint }
        }
    }

    static func resolveVariant(
        preference: WallpaperResolutionPreference,
        displays: [DisplayDescriptor]
    ) -> ImageVariant {
        switch preference {
        case .original: .original
        case .uhd: .uhd
        case .automatic:
            displays.contains { $0.pixelWidth > 1_920 || $0.pixelHeight > 1_080 } ? .uhd : .original
        }
    }
}

enum RetrySchedule {
    struct Entry: Equatable, Sendable {
        let delay: TimeInterval
        let tolerance: TimeInterval
    }

    static func entry(afterFailure failureCount: Int) -> Entry? {
        switch failureCount {
        case 1: Entry(delay: 15 * 60, tolerance: 5 * 60)
        case 2: Entry(delay: 60 * 60, tolerance: 15 * 60)
        case 3: Entry(delay: 3 * 60 * 60, tolerance: 30 * 60)
        default: nil
        }
    }
}

enum UpdateTriggerCoalescer {
    static func merge(_ current: UpdateTrigger?, with incoming: UpdateTrigger) -> UpdateTrigger {
        guard let current else { return incoming }
        return priority(of: incoming) >= priority(of: current) ? incoming : current
    }

    private static func priority(of trigger: UpdateTrigger) -> Int {
        switch trigger {
        case .manualDownloadAndApply: 100
        case .manualDownload: 90
        case .settingsChanged: 80
        case .screensChanged: 70
        case .calendarDayChanged, .timeZoneChanged, .clockChanged: 60
        case .wake, .sessionActive: 50
        case .startup: 40
        case .spaceChanged: 0
        }
    }
}
