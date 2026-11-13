import AppKit
import Foundation

func result<T>(_ operation: () async throws -> T) async -> Result<T, Error> {
  do { return .success(try await operation()) } catch { return .failure(error) }
}

/// Приглушённая, адаптивная к теме палитра. Яркие systemRed/systemOrange плохо
/// читаются в строке меню (особенно на светлой теме), поэтому здесь глубокий
/// кирпичный / янтарный для светлой и мягкий коралл / янтарь для тёмной.
enum StatusPalette {
  nonisolated(unsafe) static let critical = NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
      ? NSColor(srgbRed: 1.00, green: 0.56, blue: 0.52, alpha: 1)
      : NSColor(srgbRed: 0.72, green: 0.17, blue: 0.14, alpha: 1)
  }
  nonisolated(unsafe) static let warning = NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
      ? NSColor(srgbRed: 0.98, green: 0.75, blue: 0.33, alpha: 1)
      : NSColor(srgbRed: 0.70, green: 0.33, blue: 0.05, alpha: 1)
  }
  // Непрозрачный приглушённый серый: secondaryLabelColor полупрозрачный и
  // исчезает на полупрозрачной строке меню, а mild должен читаться.
  nonisolated(unsafe) static let mild = NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
      ? NSColor(srgbRed: 0.62, green: 0.62, blue: 0.67, alpha: 1)
      : NSColor(srgbRed: 0.42, green: 0.42, blue: 0.45, alpha: 1)
  }

  static func color(_ level: LimitLevel) -> NSColor {
    switch level {
    case .ok: return .labelColor
    case .mild: return mild
    case .warning: return warning
    case .critical: return critical
    }
  }
}

final class LimitRowView: NSView {
  private let limit: UsageWindow

  init(limit: UsageWindow) {
    self.limit = limit
    super.init(frame: NSRect(x: 0, y: 0, width: 390, height: 58))
  }

  required init?(coder: NSCoder) { nil }
  override var isFlipped: Bool { true }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    let remaining = limit.remainingPercent
    let labelAttributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold),
      .foregroundColor: NSColor.labelColor,
    ]
    let detailAttributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 11, weight: .medium),
      .foregroundColor: NSColor.secondaryLabelColor,
    ]
    limit.title.draw(at: NSPoint(x: 14, y: 12), withAttributes: labelAttributes)
    "\(remaining)%".draw(at: NSPoint(x: 136, y: 12), withAttributes: labelAttributes)
    "left".draw(at: NSPoint(x: 174, y: 13), withAttributes: detailAttributes)
    if let resetsAt = limit.resetsAt {
      let text = "reset \(Self.resetDescription(resetsAt))"
      let size = text.size(withAttributes: detailAttributes)
      text.draw(at: NSPoint(x: bounds.width - size.width - 14, y: 13), withAttributes: detailAttributes)
    }

    let bar = NSRect(x: 14, y: 36, width: bounds.width - 28, height: 8)
    NSColor.tertiaryLabelColor.withAlphaComponent(0.34).setFill()
    NSBezierPath(roundedRect: bar, xRadius: 4, yRadius: 4).fill()
    let width = bar.width * CGFloat(remaining) / 100
    if width > 0 {
      let colors: [NSColor]
      switch limit.level {
      case .ok: colors = [.systemTeal, .systemCyan]
      case .mild: colors = [StatusPalette.mild, StatusPalette.mild.blended(withFraction: 0.35, of: .white) ?? StatusPalette.mild]
      case .warning: colors = [StatusPalette.warning, StatusPalette.warning.blended(withFraction: 0.35, of: .white) ?? StatusPalette.warning]
      case .critical: colors = [StatusPalette.critical, StatusPalette.critical.blended(withFraction: 0.35, of: .white) ?? StatusPalette.critical]
      }
      NSGradient(colors: colors)!.draw(
        in: NSBezierPath(roundedRect: NSRect(x: bar.minX, y: bar.minY, width: width, height: bar.height),
                         xRadius: 4, yRadius: 4), angle: 0
      )
    }
  }

  private static func resetDescription(_ date: Date) -> String {
    let interval = max(0, date.timeIntervalSinceNow)
    let formatter = DateComponentsFormatter()
    formatter.allowedUnits = interval >= 86_400 ? [.day, .hour] : [.hour, .minute]
    formatter.unitsStyle = .abbreviated
    formatter.maximumUnitCount = 2
    return formatter.string(from: interval) ?? "now"
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
  private var snapshots: [Provider: ProviderSnapshot] = [:]
  private var errors: [Provider: Error] = [:]
  private var fetching = false
  private var refreshTimer: Timer?

  func applicationDidFinishLaunching(_ notification: Notification) {
    statusItem.button?.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    statusItem.button?.title = "K …  G …  Q …"
    rebuildMenu()
    refresh()
    refreshTimer = Timer.scheduledTimer(
      timeInterval: 120, target: self, selector: #selector(refresh), userInfo: nil, repeats: true
    )
  }

  func applicationWillTerminate(_ notification: Notification) { refreshTimer?.invalidate() }

  @objc private func refresh() {
    guard !fetching else { return }
    fetching = true
    Task { [weak self] in
      async let kimi = result { try await KimiReader.fetch() }
      async let go = result { try await OpenCodeReader.fetch() }
      async let qwen = result { try await QwenReader.fetch() }
      let results = await [Provider.kimi: kimi, Provider.go: go, Provider.qwen: qwen]
      await MainActor.run {
        guard let self else { return }
        for (provider, result) in results {
          switch result {
          case let .success(snapshot):
            self.snapshots[provider] = snapshot
            self.errors.removeValue(forKey: provider)
          case let .failure(error): self.errors[provider] = error
          }
        }
        self.fetching = false
        self.rebuildMenu()
      }
    }
  }

  private func rebuildMenu() {
    updateTitle()
    let menu = NSMenu()
    statusItem.menu = menu
    for provider in Provider.allCases {
      let heading = provider.heading
      menu.addItem(withTitle: heading, action: nil, keyEquivalent: "")
      if let snapshot = snapshots[provider] {
        if let workspace = snapshot.usage.workspace, !workspace.isEmpty {
          menu.addItem(withTitle: workspace, action: nil, keyEquivalent: "")
        }
        for limit in snapshot.usage.windows {
          let item = NSMenuItem()
          item.view = LimitRowView(limit: limit)
          menu.addItem(item)
        }
        menu.addItem(withTitle: "Обновлено \(freshness(snapshot.timestamp))", action: nil, keyEquivalent: "")
      } else {
        menu.addItem(withTitle: "Нет данных", action: nil, keyEquivalent: "")
      }
      if let error = errors[provider] {
        let item = menu.addItem(withTitle: message(error), action: nil, keyEquivalent: "")
        item.isEnabled = false
      } else if snapshots[provider] == nil {
        menu.addItem(withTitle: "Загрузка…", action: nil, keyEquivalent: "")
      }
      let openItem = menu.addItem(withTitle: "Открыть \(heading)", action: #selector(openDashboard(_:)), keyEquivalent: "")
      openItem.target = self
      openItem.representedObject = provider
      menu.addItem(.separator())
    }
    menu.addItem(withTitle: "Обновить", action: #selector(refresh), keyEquivalent: "r").target = self
    menu.addItem(withTitle: "Закрыть AI Code Limits", action: #selector(quit), keyEquivalent: "q").target = self
  }

  private func updateTitle() {
    let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    let title = NSMutableAttributedString()
    func append(_ text: String, _ color: NSColor) {
      title.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]))
    }
    for (index, provider) in Provider.allCases.enumerated() {
      if index > 0 { append("  ", .labelColor) }
      guard let snapshot = snapshots[provider] else {
        append("\(provider.shortTitle) —", .labelColor)
        continue
      }
      let windows = snapshot.usage.windows
      // Буква провайдера — по «бюджетным» окнам (не 5h): временный rate-limit
      // не должен красить весь сервис. Если есть только rolling — по нему.
      let durable = windows.filter { $0.kind != .rolling }
      let letterLevel = (durable.isEmpty ? windows : durable).map(\.level).max() ?? .ok
      append(provider.shortTitle, StatusPalette.color(letterLevel))
      append(" ", .labelColor)
      for (windowIndex, window) in windows.enumerated() {
        if windowIndex > 0 { append("·", StatusPalette.mild) }
        append("\(window.remainingPercent)", StatusPalette.color(window.level))
      }
    }
    if !errors.isEmpty { append(" ·!", StatusPalette.warning) }
    statusItem.button?.attributedTitle = title
    statusItem.button?.toolTip = "Kimi Coding · OpenCode Go · Qwen Token Plan — остаток лимитов, %"
  }

  private func freshness(_ timestamp: Date) -> String {
    Date().timeIntervalSince(timestamp) < 60 ? "только что"
      : RelativeDateTimeFormatter().localizedString(for: timestamp, relativeTo: Date())
  }

  private func message(_ error: Error) -> String {
    (error as? UsageError)?.errorDescription ?? error.localizedDescription
  }

  @objc private func openDashboard(_ sender: NSMenuItem) {
    guard let provider = sender.representedObject as? Provider else { return }
    NSWorkspace.shared.open(provider.dashboard)
  }
  @objc private func quit() { NSApplication.shared.terminate(nil) }
}
