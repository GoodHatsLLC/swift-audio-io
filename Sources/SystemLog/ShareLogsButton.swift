import Foundation

#if canImport(MessageUI)
  public import SwiftUI
  import MessageUI
#endif

// MARK: - Public API

extension SystemLog {

  /// A titled group of key-value pairs for inclusion in diagnostic emails.
  public struct DiagnosticSection: Sendable {
    public let title: String
    public let items: [(key: String, value: String)]

    public init(title: String, items: [(key: String, value: String)]) {
      self.title = title
      self.items = items
    }
  }

  /// A button that composes a diagnostic email with attached log files, static device info,
  /// and consumer-provided diagnostic sections.
  ///
  /// Configure with the same `baseDirectory` passed to ``DiskLogWriter`` and
  /// ``UncaughtExceptionLogger``. The button looks inside `<baseDirectory>/logs/` for `.log` files.
  ///
  /// ```swift
  /// SystemLog.ShareLogsButton(
  ///   baseDirectory: FileManager.applicationSupportDirectory,
  ///   recipientEmail: "support@example.com"
  /// ) {
  ///   [SystemLog.DiagnosticSection(title: "Database", items: [("Rows", "42")])]
  /// }
  /// ```
  #if canImport(MessageUI)
    public struct ShareLogsButton: View {

      private let baseDirectory: URL
      private let recipientEmail: String
      private let subject: String?
      private let prefix: String?
      private let additionalInfo: @Sendable () async -> [DiagnosticSection]

      @State private var preparedEmail: PreparedEmail?
      @State private var isLoading = false
      @State private var isShowingMail = false
      @State private var isShowingShareSheet = false

      public init(
        baseDirectory: URL,
        recipientEmail: String,
        subject: String? = nil,
        prefix: String? = nil,
        additionalInfo: @escaping @Sendable () async -> [DiagnosticSection] = { [] }
      ) {
        self.baseDirectory = baseDirectory
        self.recipientEmail = recipientEmail
        self.subject = subject
        self.additionalInfo = additionalInfo
        self.prefix = prefix
      }

      public var body: some View {
        Button {
          guard !isLoading else { return }
          isLoading = true
          Task {
            let extra = await additionalInfo()
            let email = PreparedEmail.build(
              baseDirectory: baseDirectory,
              recipientEmail: recipientEmail,
              subject: subject,
              prefix: prefix,
              additionalSections: extra
            )
            preparedEmail = email
            isLoading = false
            if MFMailComposeViewController.canSendMail() {
              isShowingMail = true
            } else {
              isShowingShareSheet = true
            }
          }
        } label: {
          HStack {
            Label("Share Logs", systemImage: "envelope.badge.shield.half.filled")
            Spacer()
            if isLoading {
              ProgressView()
                .controlSize(.small)
            }
          }
        }
        .disabled(isLoading)
        .sheet(isPresented: $isShowingMail) {
          if let email = preparedEmail {
            MailComposeView(email: email, isPresented: $isShowingMail)
          }
        }
        .sheet(isPresented: $isShowingShareSheet) {
          if let email = preparedEmail {
            ActivityView(email: email, isPresented: $isShowingShareSheet)
          }
        }
      }
    }
  #endif
}

// MARK: - PreparedEmail

extension SystemLog {

  struct PreparedEmail: Sendable {
    let recipients: [String]
    let subject: String
    let body: String
    let attachments: [(fileName: String, data: Data, mimeType: String)]

    static func build(
      baseDirectory: URL,
      recipientEmail: String,
      subject: String?,
      prefix: String?,
      additionalSections: [DiagnosticSection]
    ) -> PreparedEmail {
      let deviceInfo = DeviceInfoCollector.gather()
      let logFiles = LogFileCollector.gather(baseDirectory: baseDirectory)

      let resolvedSubject = subject ?? defaultSubject()

      let body = formatBody(
        prefix: prefix, deviceInfo: deviceInfo, additionalSections: additionalSections)

      let attachments: [(fileName: String, data: Data, mimeType: String)] = logFiles.map {
        (fileName: $0.fileName, data: $0.data, mimeType: "text/plain")
      }

      return PreparedEmail(
        recipients: [recipientEmail],
        subject: resolvedSubject,
        body: body,
        attachments: attachments
      )
    }

    private static func defaultSubject() -> String {
      let appName =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
        ?? "App"
      let date = Date.now.formatted(date: .numeric, time: .shortened)
      return "\(appName) Diagnostic Logs — \(date)"
    }

    private static func formatBody(
      prefix: String?,
      deviceInfo: [(key: String, value: String)],
      additionalSections: [DiagnosticSection]
    ) -> String {
      var lines: [String] = []

      if let prefix {
        lines.append(prefix)
      }

      lines.append("--- Device & App ---")
      for item in deviceInfo {
        lines.append("\(item.key): \(item.value)")
      }

      for section in additionalSections {
        lines.append("")
        lines.append("--- \(section.title) ---")
        for item in section.items {
          lines.append("\(item.key): \(item.value)")
        }
      }

      return lines.joined(separator: "\n")
    }
  }
}

// MARK: - Device Info

extension SystemLog {

  enum DeviceInfoCollector {
    static func gather() -> [(key: String, value: String)] {
      let info = Bundle.main.infoDictionary ?? [:]
      let appName =
        info["CFBundleDisplayName"] as? String
        ?? info["CFBundleName"] as? String
        ?? "Unknown"
      let version = info["CFBundleShortVersionString"] as? String ?? "?"
      let build = info["CFBundleVersion"] as? String ?? "?"
      let bundleID = Bundle.main.bundleIdentifier ?? "Unknown"

      let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
      let model = machineIdentifier()

      return [
        ("App", "\(appName) \(version) (\(build))"),
        ("Bundle ID", bundleID),
        ("OS", osVersion),
        ("Device", model),
        ("Locale", Locale.current.identifier),
        ("Timezone", TimeZone.current.identifier),
      ]
    }

    private static func machineIdentifier() -> String {
      var systemInfo = utsname()
      unsafe uname(&systemInfo)
      return unsafe withUnsafePointer(to: systemInfo.machine) { ptr in
        unsafe ptr.withMemoryRebound(to: CChar.self, capacity: 1) { cString in
          unsafe String(cString: cString)
        }
      }
    }
  }
}

// MARK: - Log File Collection

extension SystemLog {

  enum LogFileCollector {
    static func gather(baseDirectory: URL) -> [(fileName: String, data: Data)] {
      let logsDirectory = baseDirectory.appendingPathComponent("logs", isDirectory: true)
      let fm = FileManager.default
      guard
        let contents = try? fm.contentsOfDirectory(
          at: logsDirectory,
          includingPropertiesForKeys: [.contentModificationDateKey],
          options: .skipsHiddenFiles
        )
      else { return [] }

      return
        contents
        .filter { $0.pathExtension == "log" }
        .sorted { lhs, rhs in
          let lhsDate =
            (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
            ?? .distantPast
          let rhsDate =
            (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
            ?? .distantPast
          return lhsDate > rhsDate
        }
        .compactMap { url in
          guard let data = try? Data(contentsOf: url) else { return nil }
          return (fileName: url.lastPathComponent, data: data)
        }
    }
  }
}

// MARK: - Mail Compose (UIKit Bridge)

#if canImport(MessageUI)

  extension SystemLog {

    @MainActor
    struct MailComposeView: UIViewControllerRepresentable {
      let email: PreparedEmail
      @Binding var isPresented: Bool

      func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let vc = MFMailComposeViewController()
        vc.mailComposeDelegate = context.coordinator
        vc.setToRecipients(email.recipients)
        vc.setSubject(email.subject)
        vc.setMessageBody(email.body.replacingOccurrences(of: "\n", with: "<br />"), isHTML: true)
        for attachment in email.attachments {
          vc.addAttachmentData(
            attachment.data, mimeType: attachment.mimeType, fileName: attachment.fileName)
        }
        return vc
      }

      func updateUIViewController(_: MFMailComposeViewController, context _: Context) {}

      func makeCoordinator() -> Coordinator {
        Coordinator(isPresented: $isPresented)
      }

      final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        @Binding var isPresented: Bool

        init(isPresented: Binding<Bool>) {
          self._isPresented = isPresented
        }

        func mailComposeController(
          _ controller: MFMailComposeViewController,
          didFinishWith _: MFMailComposeResult,
          error _: (any Error)?
        ) {
          Task { @MainActor [$isPresented] in
            $isPresented.wrappedValue = false
            controller.dismiss(animated: true)
          }
        }
      }
    }
  }

  // MARK: - Activity View (Fallback)

  extension SystemLog {

    @MainActor
    struct ActivityView: UIViewControllerRepresentable {
      let email: PreparedEmail
      @Binding var isPresented: Bool

      func makeUIViewController(context _: Context) -> UIActivityViewController {
        var items: [Any] = []

        // Include body text as a shareable text item.
        items.append(email.body)

        // Write log files to temp directory so they can be shared as file URLs.
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
          "share-logs-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        for attachment in email.attachments {
          let fileURL = tempDir.appendingPathComponent(attachment.fileName)
          try? attachment.data.write(to: fileURL)
          items.append(fileURL)
        }

        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        return vc
      }

      func updateUIViewController(_: UIActivityViewController, context _: Context) {}
    }
  }

#endif
