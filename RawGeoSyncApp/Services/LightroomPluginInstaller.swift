import Foundation

enum LightroomPluginInstallationStatus: Equatable, Sendable {
  case checking
  case unavailable
  case notInstalled
  case updateAvailable
  case installed

  var title: String {
    switch self {
    case .checking: "正在检查插件…"
    case .unavailable: "当前构建未包含插件"
    case .notInstalled: "插件尚未安装"
    case .updateAvailable: "插件可更新"
    case .installed: "插件已安装"
    }
  }

  var actionTitle: String? {
    switch self {
    case .notInstalled: "安装插件"
    case .updateAvailable: "更新插件"
    case .checking, .unavailable, .installed: nil
    }
  }
}

struct LightroomPluginInstaller: Sendable {
  static let pluginDirectoryName = "RawGeoSync.lrplugin"
  static let toolkitIdentifier = "com.sssimplec.rawgeosync.lightroom"

  let bundledPluginURL: URL?
  let modulesDirectoryURL: URL

  init(
    bundle: Bundle = .main,
    applicationSupportURL: URL? = nil
  ) {
    bundledPluginURL =
      bundle.url(forResource: "RawGeoSync", withExtension: "lrplugin")
      ?? bundle.resourceURL?.appendingPathComponent(Self.pluginDirectoryName, isDirectory: true)
    let root =
      applicationSupportURL
      ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
        "Library/Application Support",
        isDirectory: true
      )
    modulesDirectoryURL =
      root
      .appendingPathComponent("Adobe/Lightroom/Modules", isDirectory: true)
  }

  init(bundledPluginURL: URL?, modulesDirectoryURL: URL) {
    self.bundledPluginURL = bundledPluginURL?.standardizedFileURL
    self.modulesDirectoryURL = modulesDirectoryURL.standardizedFileURL
  }

  var installedPluginURL: URL {
    modulesDirectoryURL.appendingPathComponent(Self.pluginDirectoryName, isDirectory: true)
  }

  func status() -> LightroomPluginInstallationStatus {
    guard let source = validBundledPluginURL() else { return .unavailable }
    guard FileManager.default.fileExists(atPath: installedPluginURL.path) else {
      return .notInstalled
    }
    guard validInstalledPluginURL() != nil else { return .updateAvailable }
    if let sourceVersion = pluginVersion(at: source),
      let installedVersion = pluginVersion(at: installedPluginURL)
    {
      return sourceVersion == installedVersion ? .installed : .updateAvailable
    }
    let sourceInfo = try? Data(contentsOf: source.appendingPathComponent("Info.lua"))
    let installedInfo = try? Data(contentsOf: installedPluginURL.appendingPathComponent("Info.lua"))
    return sourceInfo != nil && sourceInfo == installedInfo ? .installed : .updateAvailable
  }

  @discardableResult
  func installOrUpdate() throws -> URL {
    guard let source = validBundledPluginURL() else {
      throw WorkflowFailure(message: "当前 RawGeoSync 构建中没有可安装的 Lightroom Classic 插件。")
    }

    let fileManager = FileManager.default
    try fileManager.createDirectory(at: modulesDirectoryURL, withIntermediateDirectories: true)
    let modulesValues = try modulesDirectoryURL.resourceValues(forKeys: [
      .isDirectoryKey, .isSymbolicLinkKey,
    ])
    guard modulesValues.isDirectory == true, modulesValues.isSymbolicLink != true else {
      throw WorkflowFailure(message: "Lightroom Modules 路径不是安全的本地目录，已停止安装。")
    }

    if fileManager.fileExists(atPath: installedPluginURL.path) {
      guard validInstalledPluginURL() != nil else {
        throw WorkflowFailure(message: "目标插件路径已被未知文件或符号链接占用，已停止覆盖。")
      }
    }

    let stagingURL = modulesDirectoryURL.appendingPathComponent(
      ".RawGeoSync-install-\(UUID().uuidString).lrplugin",
      isDirectory: true
    )
    let backupURL = modulesDirectoryURL.appendingPathComponent(
      ".RawGeoSync-backup-\(UUID().uuidString).lrplugin",
      isDirectory: true
    )
    var movedExistingToBackup = false
    defer {
      try? fileManager.removeItem(at: stagingURL)
      if fileManager.fileExists(atPath: backupURL.path) {
        try? fileManager.removeItem(at: backupURL)
      }
    }

    try fileManager.copyItem(at: source, to: stagingURL)
    guard validPluginDirectory(at: stagingURL) else {
      throw WorkflowFailure(message: "内置插件缺少有效的 Info.lua，已停止安装。")
    }

    do {
      if fileManager.fileExists(atPath: installedPluginURL.path) {
        try fileManager.moveItem(at: installedPluginURL, to: backupURL)
        movedExistingToBackup = true
      }
      try fileManager.moveItem(at: stagingURL, to: installedPluginURL)
      if movedExistingToBackup {
        try fileManager.removeItem(at: backupURL)
      }
      return installedPluginURL
    } catch {
      if movedExistingToBackup,
        !fileManager.fileExists(atPath: installedPluginURL.path),
        fileManager.fileExists(atPath: backupURL.path)
      {
        try? fileManager.moveItem(at: backupURL, to: installedPluginURL)
      }
      throw WorkflowFailure(message: "Lightroom Classic 插件安装失败：\(error.localizedDescription)")
    }
  }

  private func validBundledPluginURL() -> URL? {
    guard let bundledPluginURL, validPluginDirectory(at: bundledPluginURL) else { return nil }
    return bundledPluginURL
  }

  private func validInstalledPluginURL() -> URL? {
    validPluginDirectory(at: installedPluginURL) ? installedPluginURL : nil
  }

  private func validPluginDirectory(at url: URL) -> Bool {
    guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
      values.isDirectory == true,
      values.isSymbolicLink != true
    else { return false }
    let infoURL = url.appendingPathComponent("Info.lua", isDirectory: false)
    guard
      let infoValues = try? infoURL.resourceValues(
        forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
      )
    else { return false }
    guard infoValues.isRegularFile == true, infoValues.isSymbolicLink != true,
      let info = try? String(contentsOf: infoURL, encoding: .utf8)
    else { return false }
    return info.contains(Self.toolkitIdentifier)
  }

  private func pluginVersion(at pluginURL: URL) -> String? {
    let infoURL = pluginURL.appendingPathComponent("Info.lua", isDirectory: false)
    guard let contents = try? String(contentsOf: infoURL, encoding: .utf8) else { return nil }
    let patterns = ["VERSION.major", "VERSION.minor", "VERSION.revision", "VERSION.build"]
    let values = patterns.map { key -> String in
      guard let range = contents.range(of: key),
        let equals = contents[range.upperBound...].firstIndex(of: "=")
      else { return "" }
      let suffix = contents[contents.index(after: equals)...]
        .trimmingCharacters(in: .whitespaces)
      return suffix.prefix { $0.isNumber }.description
    }
    let joined = values.joined(separator: ".")
    return joined == "..." ? nil : joined
  }
}
