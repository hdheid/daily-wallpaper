import Foundation

enum AppConstants {
    static let displayName = "Daily Wallpaper"
    static let defaultArchiveFolderName = "dailywallpaper"
    static let applicationSupportFolderName = "DailyWallpaper"
    static let thumbnailCacheFolderName = "Thumbnails"
    static let mediaLibraryPageSize = 80
    static let mediaLibraryThumbnailPointSize: CGFloat = 400
    static let thumbnailMemoryLimit = 32 * 1_024 * 1_024
    static let thumbnailDiskLimit: Int64 = 256 * 1_024 * 1_024
}

extension Notification.Name {
    static let dailyWallpaperSettingsDidChange = Notification.Name("DailyWallpaper.SettingsDidChange")
    static let dailyWallpaperDisplaysDidChange = Notification.Name("DailyWallpaper.DisplaysDidChange")
    static let dailyWallpaperLibraryDidChange = Notification.Name("DailyWallpaper.LibraryDidChange")
}
