import Foundation

/// Длительность окна лимита. Короткие (5h) — временный rate-limit, который
/// сам восстановится; месяц — реальный бюджет подписки. От этого зависит,
/// насколько «тревожным» должен быть цвет.
enum WindowKind {
  case rolling, weekly, monthly

  static func infer(_ title: String) -> WindowKind {
    let lower = title.lowercased()
    if lower.contains("week") || lower.contains("7d") { return .weekly }
    if lower.contains("month") || lower.contains("30d") { return .monthly }
    return .rolling
  }
}

/// Уровень тревоги окна. rolling никогда не поднимается выше mild.
enum LimitLevel: Int, Comparable {
  case ok = 0, mild = 1, warning = 2, critical = 3

  static func < (lhs: LimitLevel, rhs: LimitLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct UsageWindow {
  let title: String
  let usedPercent: Double
  let resetsAt: Date?
  let kind: WindowKind

  init(title: String, usedPercent: Double, resetsAt: Date?, kind: WindowKind? = nil) {
    self.title = title
    self.usedPercent = usedPercent
    self.resetsAt = resetsAt
    self.kind = kind ?? WindowKind.infer(title)
  }

  var remainingPercent: Int {
    max(0, min(100, 100 - Int(usedPercent.rounded())))
  }

  /// Тревога с учётом длительности окна: исчерпанный 5h — это mild (временно),
  /// исчерпанный месяц — critical (бюджет кончился).
  var level: LimitLevel {
    let remaining = remainingPercent
    switch kind {
    case .monthly: return remaining <= 10 ? .critical : remaining <= 20 ? .warning : .ok
    case .weekly: return remaining <= 10 ? .warning : remaining <= 20 ? .mild : .ok
    case .rolling: return remaining <= 10 ? .mild : .ok
    }
  }
}

struct ProviderUsage {
  let windows: [UsageWindow]
  let workspace: String?
}

struct ProviderSnapshot {
  let provider: Provider
  let usage: ProviderUsage
  let timestamp = Date()
}

enum Provider: String, CaseIterable {
  case kimi = "Kimi"
  case go = "Go"
  case qwen = "Qwen"

  var shortTitle: String {
    switch self {
    case .kimi: "K"
    case .go: "G"
    case .qwen: "Q"
    }
  }

  var heading: String {
    switch self {
    case .kimi: "Kimi Coding"
    case .go: "OpenCode Go"
    case .qwen: "Qwen Token Plan"
    }
  }

  var dashboard: URL {
    switch self {
    case .kimi: URL(string: "https://www.kimi.ai/code/console")!
    case .go: URL(string: "https://opencode.ai/auth")!
    case .qwen: URL(string: "https://home.qwencloud.com/analytics/token-plan/individual")!
    }
  }

  func fetch() async throws -> ProviderSnapshot {
    switch self {
    case .kimi: try await KimiReader.fetch()
    case .go: try await OpenCodeReader.fetch()
    case .qwen: try await QwenReader.fetch()
    }
  }

  func raw() async throws -> String {
    switch self {
    case .kimi: try await KimiReader.raw()
    case .go: try await OpenCodeReader.raw()
    case .qwen: try await QwenReader.raw()
    }
  }
}

enum UsageError: LocalizedError {
  case noCredentials(String)
  case unauthorized(Provider)
  case http(Provider, Int)
  case malformed(Provider, String)
  case command(String)

  var errorDescription: String? {
    switch self {
    case let .noCredentials(message): message
    case let .unauthorized(provider):
      provider == .qwen
        ? "Qwen Cloud отклонил авторизацию. Войдите заново на home.qwencloud.com и обновите cookie."
        : "\(provider.rawValue) отклонил авторизацию. Войдите заново в CLI."
    case let .http(provider, code): "\(provider.rawValue) вернул HTTP \(code)."
    case let .malformed(provider, detail): "\(provider.rawValue): не удалось разобрать ответ (\(detail))."
    case let .command(message): message
    }
  }
}

func parseDate(_ value: Any?) -> Date? {
  if let milliseconds = value as? NSNumber {
    return Date(timeIntervalSince1970: milliseconds.doubleValue / 1000)
  }
  guard let text = value as? String else { return nil }
  let fractional = ISO8601DateFormatter()
  fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  if let date = fractional.date(from: text) { return date }
  let plain = ISO8601DateFormatter()
  plain.formatOptions = [.withInternetDateTime]
  return plain.date(from: text)
}

func resetDate(_ object: [String: Any]) -> Date? {
  for key in ["reset_at", "resetAt", "reset_time", "resetTime", "resetsAt"] {
    if let date = parseDate(object[key]) { return date }
  }
  for key in ["reset_in", "resetIn", "ttl"] {
    if let seconds = (object[key] as? NSNumber)?.doubleValue {
      return Date().addingTimeInterval(seconds)
    }
  }
  return nil
}

func jsonObject(_ data: Data) throws -> [String: Any] {
  guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
    throw UsageError.malformed(.kimi, "ожидался JSON-объект")
  }
  return object
}
