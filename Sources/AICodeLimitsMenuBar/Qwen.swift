import Foundation

/// Qwen Cloud Token Plan (Individual).
///
/// У Token Plan нет usage API по API-ключу (`sk-sp-`): остатки Credits читаются
/// только через консольный шлюз OneConsole с cookie браузерной сессии
/// (тот же контракт, что использует дашборд home.qwencloud.com).
/// Cookie берутся из `QWEN_CLOUD_COOKIE` или файла
/// `~/.config/ai-code-limits/qwen-cloud-cookie` (одна строка Cookie-заголовка).
enum QwenReader {
  private static let dashboard = URL(string: "https://home.qwencloud.com/billing/subscription/token-plan-individual")!
  private static let userInfo = URL(string: "https://home.qwencloud.com/tool/user/info.json")!
  private static let dataGateway = URL(string: "https://cs-data.qwencloud.com/data/api.json")!
  private static let usageAPI = "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/usage"
  private static let subscriptionAPI = "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/subscription"
  private static let commodityCode = "sfm_tokenplansolo_public_intl"
  // Шлюз отклоняет нестандартные User-Agent (проверка «человек или бот»), поэтому браузерный.
  private static let userAgent =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/157.0.0.0 Safari/537.36"

  private static let session: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    return URLSession(configuration: configuration)
  }()

  static func fetch() async throws -> ProviderSnapshot {
    let cookie = try cookieHeader()
    let secToken = try await secToken(cookie: cookie)
    let usage = try usageObject(await call(api: usageAPI, data: [:], cookie: cookie, secToken: secToken))
    var windows = [UsageWindow]()
    for (title, percentKey, resetKey) in [
      ("5h", "per5HourPercentage", "per5HourResetTime"),
      ("Week", "per1WeekPercentage", "per1WeekResetTime"),
      ("Month", "per1MonthPercentage", "per1MonthResetTime"),
    ] {
      guard let ratio = number(usage[percentKey]) else { continue }
      windows.append(UsageWindow(
        title: title, usedPercent: min(max(ratio, 0), 1) * 100, resetsAt: date(usage[resetKey])
      ))
    }
    guard !windows.isEmpty else { throw UsageError.malformed(.qwen, "нет окон usage") }
    var workspace: String?
    if let data = try? await call(
      api: subscriptionAPI, data: ["commodityCode": commodityCode], cookie: cookie, secToken: secToken
    ), let plan = planName(data) {
      workspace = plan
    }
    return ProviderSnapshot(provider: .qwen, usage: ProviderUsage(windows: windows, workspace: workspace))
  }

  static func raw() async throws -> String {
    let cookie = try cookieHeader()
    let secToken = try await secToken(cookie: cookie)
    let data = try await call(api: usageAPI, data: [:], cookie: cookie, secToken: secToken)
    return String(decoding: data, as: UTF8.self)
  }

  // MARK: - Credentials

  private static func cookieFile() -> URL {
    let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
      .flatMap { $0.isEmpty ? nil : $0 }
      .map(URL.init(fileURLWithPath:))
      ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config")
    return base.appending(path: "ai-code-limits/qwen-cloud-cookie")
  }

  private static func cookieHeader() throws -> String {
    var raw = ProcessInfo.processInfo.environment["QWEN_CLOUD_COOKIE"] ?? ""
    if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      raw = (try? String(contentsOf: cookieFile(), encoding: .utf8)) ?? ""
    }
    var header = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if header.lowercased().hasPrefix("cookie:") {
      header = String(header.dropFirst("cookie:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard !header.isEmpty, header.contains("=") else {
      throw UsageError.noCredentials(
        "Qwen Cloud: нет cookie сессии. Войдите на home.qwencloud.com и сохраните Cookie-заголовок в \(cookieFile().path()) (или задайте QWEN_CLOUD_COOKIE)."
      )
    }
    return header
  }

  private static func cookieValue(_ name: String, in header: String) -> String? {
    for pair in header.split(separator: ";") {
      let parts = pair.split(separator: "=", maxSplits: 1)
      guard parts.count == 2 else { continue }
      if parts[0].trimmingCharacters(in: .whitespaces).lowercased() == name.lowercased() {
        return String(parts[1])
      }
    }
    return nil
  }

  // MARK: - sec_token

  private static func secToken(cookie: String) async throws -> String {
    // 1. Лёгкий JSON-эндпоинт пользователя (проверен на живом аккаунте).
    if let token = try? await fetchSecTokenFromUserInfo(cookie: cookie) { return token }
    // 2. Cookie sec_token, привязанная к консоли.
    if let token = cookieValue("sec_token", in: cookie), !token.isEmpty { return token }
    // 3. Inline-константа в HTML дашборда.
    if let token = try? await fetchSecTokenFromDashboard(cookie: cookie) { return token }
    throw UsageError.unauthorized(.qwen)
  }

  private static func fetchSecTokenFromUserInfo(cookie: String) async throws -> String {
    var request = URLRequest(url: userInfo)
    request.timeoutInterval = 20
    request.setValue(cookie, forHTTPHeaderField: "Cookie")
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
    let (data, response) = try await session.data(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200,
          let raw = try? JSONSerialization.jsonObject(with: data),
          let token = firstString(forKeys: ["secToken", "sec_token", "csrfToken"], in: expandEmbeddedJSON(raw)),
          !token.isEmpty else {
      throw UsageError.unauthorized(.qwen)
    }
    return token
  }

  private static func fetchSecTokenFromDashboard(cookie: String) async throws -> String {
    var request = URLRequest(url: dashboard)
    request.timeoutInterval = 20
    request.setValue(cookie, forHTTPHeaderField: "Cookie")
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
    let (data, response) = try await session.data(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200,
          let html = String(data: data, encoding: .utf8) else {
      throw UsageError.unauthorized(.qwen)
    }
    for pattern in [#""secToken"\s*:\s*"([^"]+)""#, #""sec_token"\s*:\s*"([^"]+)""#,
                    #"secToken['"]?\s*[:=]\s*['"]([^'"]+)['"]"#, #"sec_token['"]?\s*[:=]\s*['"]([^'"]+)['"]"#] {
      guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
      let range = NSRange(html.startIndex..<html.endIndex, in: html)
      if let match = regex.firstMatch(in: html, range: range),
         let valueRange = Range(match.range(at: 1), in: html) {
        let token = String(html[valueRange])
        if !token.isEmpty { return token }
      }
    }
    throw UsageError.unauthorized(.qwen)
  }

  // MARK: - Gateway

  private static func call(api: String, data: [String: String], cookie: String, secToken: String) async throws -> Data {
    var components = URLComponents(url: dataGateway, resolvingAgainstBaseURL: false)!
    components.queryItems = [
      URLQueryItem(name: "action", value: "IntlBroadScopeAspnGateway"),
      URLQueryItem(name: "product", value: "sfm_bailian"),
      URLQueryItem(name: "api", value: api),
      URLQueryItem(name: "_v", value: "undefined"),
    ]
    var cornerstone: [String: Any] = [
      "feTraceId": UUID().uuidString.lowercased(),
      "feURL": dashboard.absoluteString,
      "protocol": "V2",
      "console": "ONE_CONSOLE",
      "productCode": "p_efm",
      "domain": dashboard.host ?? "home.qwencloud.com",
      "consoleSite": "QWENCLOUD",
      "userNickName": "",
      "userPrincipalName": "",
      "xsp_lang": "en-US",
    ]
    if let anonymousID = cookieValue("cna", in: cookie) { cornerstone["X-Anonymous-Id"] = anonymousID }
    var apiData: [String: Any] = data
    apiData["cornerstoneParam"] = cornerstone
    let params: [String: Any] = ["Api": api, "V": "1.0", "Data": apiData]
    let paramsJSON = String(data: try JSONSerialization.data(withJSONObject: params), encoding: .utf8) ?? "{}"

    var request = URLRequest(url: components.url!)
    request.httpMethod = "POST"
    request.timeoutInterval = 30
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
    request.setValue(cookie, forHTTPHeaderField: "Cookie")
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("https://home.qwencloud.com", forHTTPHeaderField: "Origin")
    request.setValue(dashboard.absoluteString, forHTTPHeaderField: "Referer")
    request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
    if let csrf = cookieValue("login_aliyunid_csrf", in: cookie) ?? cookieValue("csrf", in: cookie) {
      request.setValue(csrf, forHTTPHeaderField: "x-xsrf-token")
      request.setValue(csrf, forHTTPHeaderField: "x-csrf-token")
    }
    request.httpBody = formEncode([
      ("product", "sfm_bailian"),
      ("action", "IntlBroadScopeAspnGateway"),
      ("sec_token", secToken),
      ("region", "ap-southeast-1"),
      ("language", "en-US"),
      ("params", paramsJSON),
    ])
    let (data, response) = try await session.data(for: request)
    switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
    case 200: return data
    case 301, 302, 303, 307, 308, 401, 403: throw UsageError.unauthorized(.qwen)
    case let code: throw UsageError.http(.qwen, code)
    }
  }

  private static func formEncode(_ fields: [(String, String)]) -> Data {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return fields.map { key, value in
      let escapedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
      let escapedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
      return "\(escapedKey)=\(escapedValue)"
    }.joined(separator: "&").data(using: .utf8) ?? Data()
  }

  // MARK: - Parsing

  private static func usageObject(_ data: Data) throws -> [String: Any] {
    let text = String(decoding: data, as: UTF8.self)
    let lowered = text.lowercased()
    // Шлюз отвечает HTTP 200 даже с протухшей сессией или HTML-страницей входа.
    if lowered.contains("notlogined") || lowered.contains("needlogin")
      || lowered.contains("session_expired") || lowered.hasPrefix("<") {
      throw UsageError.unauthorized(.qwen)
    }
    guard let raw = try? JSONSerialization.jsonObject(with: data) else {
      throw UsageError.malformed(.qwen, "ожидался JSON")
    }
    guard let usage = findObject(
      containingAnyOf: ["per5HourPercentage", "per1WeekPercentage", "per1MonthPercentage"],
      in: expandEmbeddedJSON(raw)
    ) else {
      throw UsageError.malformed(.qwen, "нет usage в ответе шлюза")
    }
    return usage
  }

  private static func planName(_ data: Data) -> String? {
    guard let raw = try? JSONSerialization.jsonObject(with: data),
          let plan = findObject(containingAnyOf: ["specCode", "spec_code"], in: expandEmbeddedJSON(raw)),
          let code = (plan["specCode"] as? String) ?? (plan["spec_code"] as? String), !code.isEmpty else {
      return nil
    }
    var title = "Plan: \(code.capitalized)"
    if let days = number(plan["remainingDays"]) { title += " · \(Int(days))d left" }
    return title
  }

  /// Ответы шлюза заворачивают полезную нагрузку в строки с JSON внутри JSON.
  private static func expandEmbeddedJSON(_ value: Any) -> Any {
    if let string = value as? String {
      let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
      guard trimmed.hasPrefix("{") || trimmed.hasPrefix("[") else { return value }
      guard let data = trimmed.data(using: .utf8),
            let decoded = try? JSONSerialization.jsonObject(with: data) else { return value }
      return expandEmbeddedJSON(decoded)
    }
    if let dictionary = value as? [String: Any] { return dictionary.mapValues(expandEmbeddedJSON) }
    if let array = value as? [Any] { return array.map(expandEmbeddedJSON) }
    return value
  }

  private static func findObject(containingAnyOf keys: Set<String>, in value: Any) -> [String: Any]? {
    if let dictionary = value as? [String: Any] {
      if !keys.isDisjoint(with: dictionary.keys) { return dictionary }
      for nested in dictionary.values {
        if let found = findObject(containingAnyOf: keys, in: nested) { return found }
      }
    } else if let array = value as? [Any] {
      for nested in array {
        if let found = findObject(containingAnyOf: keys, in: nested) { return found }
      }
    }
    return nil
  }

  private static func firstString(forKeys keys: [String], in value: Any) -> String? {
    for key in keys {
      if let found = firstString(forKey: key, in: value) { return found }
    }
    return nil
  }

  private static func firstString(forKey key: String, in value: Any) -> String? {
    if let dictionary = value as? [String: Any] {
      if let text = dictionary[key] as? String, !text.isEmpty { return text }
      for nested in dictionary.values {
        if let found = firstString(forKey: key, in: nested) { return found }
      }
    } else if let array = value as? [Any] {
      for nested in array {
        if let found = firstString(forKey: key, in: nested) { return found }
      }
    }
    return nil
  }

  private static func number(_ value: Any?) -> Double? {
    if let number = value as? NSNumber { return number.doubleValue }
    if let text = value as? String { return Double(text) }
    return nil
  }

  private static func date(_ value: Any?) -> Date? {
    if let number = number(value), number > 0 {
      let seconds = number >= 1_000_000_000_000 ? number / 1000 : number
      return Date(timeIntervalSince1970: seconds)
    }
    guard let text = value as? String else { return nil }
    if let date = parseDate(text) { return date }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
      formatter.dateFormat = format
      if let date = formatter.date(from: text) { return date }
    }
    return nil
  }
}