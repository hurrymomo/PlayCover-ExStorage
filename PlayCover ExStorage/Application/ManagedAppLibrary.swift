import Foundation

/// Stateless registry operations over the authoritative AppModel.
@MainActor
enum ManagedAppLibrary {
    static func isInstalled(_ app: AppSnapshot) -> Bool {
        guard !app.applicationPath.isEmpty,
              FileSystemUtilities.itemExists(at: app.applicationURL),
              let bundle = Bundle(url: app.applicationURL) else { return false }
        return bundle.bundleIdentifier == app.bundleIdentifier
    }

    static func restore(into model: AppModel, from store: any ManagedAppPersisting) {
        let saved = store.load()
        guard !saved.isEmpty else { return }
        model.restoreApps(saved)
        persist(model, using: store)
    }

    static func record(
        from url: URL,
        model: AppModel
    ) -> AppSnapshot? {
        guard let appBundle = Bundle(url: url) else { return nil }
        let bundleID = appBundle.bundleIdentifier
            ?? appBundle.object(forInfoDictionaryKey: kCFBundleIdentifierKey as String) as? String
        guard let bundleID, !bundleID.isEmpty else { return nil }
        let displayName = appBundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? appBundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent
        let persistence = model.apps.first(where: { $0.bundleIdentifier == bundleID })?.persistence
            ?? (model.appInfo(for: bundleID) != nil ? .managed : .sessionOnly)
        return AppSnapshot(
            bundleIdentifier: bundleID,
            name: displayName,
            applicationPath: url.path,
            persistence: persistence
        )
    }

    static func persist(_ model: AppModel, using store: any ManagedAppPersisting) {
        store.save(model.apps)
    }
}
