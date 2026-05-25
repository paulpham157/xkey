//
//  BackupRestoreSection.swift
//  XKey
//
//  Shared Backup & Restore Settings Section
//

import SwiftUI

struct BackupRestoreSection: View {
    @State private var showSuccessAlert = false
    @State private var showCountdownSheet = false
    @State private var showResetConfirmation = false
    @State private var countdownSeconds = 3
    @State private var alertTitle = ""
    @State private var alertMessage = ""
    @State private var countdownTimer: Timer?
    @State private var restartReason: RestartReason = .importSettings
    @State private var iCloudSyncEnabled = iCloudSyncManager.shared.isEnabled
    @State private var syncStatus = iCloudSyncManager.shared.status
    @State private var lastSyncDate = iCloudSyncManager.shared.lastSyncDate
    @State private var syncStatusObserver: NSObjectProtocol?
    @State private var firstEnablePromptObserver: NSObjectProtocol?
    @State private var showFirstEnablePrompt = false
    @State private var firstEnableCategories: [SyncCategory] = []
    @State private var isKVSAvailable = iCloudSyncManager.isKVSAvailable

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // iCloud Sync Section
                SettingsGroup(title: "iCloud Sync") {
                    VStack(alignment: .leading, spacing: 10) {
                        if !isKVSAvailable {
                            HStack(spacing: 6) {
                                Image(systemName: "icloud.slash")
                                    .foregroundColor(.secondary)
                                Text("iCloud Sync không khả dụng")
                                    .fontWeight(.medium)
                            }
                            Text("Vui lòng đăng nhập iCloud và bật iCloud Drive trên máy này. Trên macOS 26+, một số phiên bản phân phối ngoài App Store có thể tạm thời không hỗ trợ iCloud Sync.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                        Toggle(isOn: $iCloudSyncEnabled) {
                            HStack(spacing: 6) {
                                Image(systemName: "icloud")
                                Text("Đồng bộ thiết lập qua iCloud")
                            }
                        }
                        .onChange(of: iCloudSyncEnabled) { newValue in
                            iCloudSyncManager.shared.isEnabled = newValue
                            syncStatus = iCloudSyncManager.shared.status
                            lastSyncDate = iCloudSyncManager.shared.lastSyncDate
                        }

                        if iCloudSyncEnabled {
                            Divider()

                            HStack(spacing: 6) {
                                iCloudSyncStatusIcon(syncStatus)
                                iCloudSyncStatusText(syncStatus, lastSyncDate: lastSyncDate)
                                Spacer()
                                Button(action: {
                                    iCloudSyncManager.shared.pushAll()
                                    syncStatus = iCloudSyncManager.shared.status
                                    lastSyncDate = iCloudSyncManager.shared.lastSyncDate
                                }) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "arrow.triangle.2.circlepath")
                                        Text("Đồng bộ ngay")
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Dữ liệu được đồng bộ:")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .foregroundColor(.secondary)

                                HStack(spacing: 12) {
                                    iCloudSyncItem(icon: "gearshape", text: "Thiết lập")
                                    iCloudSyncItem(icon: "keyboard", text: "Hotkeys")
                                    iCloudSyncItem(icon: "text.badge.plus", text: "Macro")
                                }
                                HStack(spacing: 12) {
                                    iCloudSyncItem(icon: "text.book.closed", text: "Từ điển")
                                    iCloudSyncItem(icon: "list.bullet", text: "Quy tắc")
                                    iCloudSyncItem(icon: "globe", text: "Dịch thuật")
                                }
                            }

                            iCloudSyncQuotaMeter()

                            HStack {
                                if let size = iCloudSyncManager.shared.syncDataSizeBytes {
                                    let sizeStr = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
                                    Text(String(localized: "Tổng dung lượng: \(sizeStr) / \(SyncCategory.allCases.count) MB"))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Button(action: exportFromiCloud) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "square.and.arrow.up.on.square")
                                        Text("Export từ iCloud")
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(iCloudSyncManager.shared.syncDataSizeBytes == nil)
                            }
                        } else {
                            Text("Tự động đồng bộ cài đặt giữa các máy Mac cùng tài khoản iCloud.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        }  // end if isKVSAvailable
                    }
                }
                .onAppear {
                    // Re-probe KVS in case user signed into iCloud after launch.
                    isKVSAvailable = iCloudSyncManager.isKVSAvailable
                    syncStatusObserver = NotificationCenter.default.addObserver(
                        forName: .iCloudSyncStatusDidChange,
                        object: nil,
                        queue: .main
                    ) { _ in
                        syncStatus = iCloudSyncManager.shared.status
                        lastSyncDate = iCloudSyncManager.shared.lastSyncDate
                        iCloudSyncEnabled = iCloudSyncManager.shared.isEnabled
                    }
                    firstEnablePromptObserver = NotificationCenter.default.addObserver(
                        forName: .iCloudSyncFirstEnablePrompt,
                        object: nil,
                        queue: .main
                    ) { _ in
                        firstEnableCategories = iCloudSyncManager.shared.categoriesWithRemoteData()
                        showFirstEnablePrompt = true
                    }
                }
                .onDisappear {
                    if let observer = syncStatusObserver {
                        NotificationCenter.default.removeObserver(observer)
                    }
                    if let observer = firstEnablePromptObserver {
                        NotificationCenter.default.removeObserver(observer)
                    }
                }
                .confirmationDialog(
                    Text("iCloud đã có dữ liệu thiết lập sẵn"),
                    isPresented: $showFirstEnablePrompt,
                    titleVisibility: .visible
                ) {
                    Button("Gộp local + iCloud") {
                        iCloudSyncManager.shared.applyFirstEnableChoice(.merge)
                    }
                    Button("Dùng dữ liệu trên iCloud (ghi đè local)") {
                        iCloudSyncManager.shared.applyFirstEnableChoice(.useRemote)
                    }
                    Button("Đẩy local lên iCloud (ghi đè cloud)", role: .destructive) {
                        iCloudSyncManager.shared.applyFirstEnableChoice(.useLocal)
                    }
                    Button("Hủy", role: .cancel) {
                        iCloudSyncManager.shared.applyFirstEnableChoice(.cancel)
                        iCloudSyncEnabled = false
                    }
                } message: {
                    let names = firstEnableCategories.map { iCloudSyncCategoryName($0) }
                    Text(String(localized: "Dữ liệu hiện có trên iCloud: \(names.joined(separator: ", ")). Hãy chọn cách xử lý."))
                }

                // Export Section
                SettingsGroup(title: "Sao lưu thiết lập") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Export toàn bộ cấu hình ra file .plist")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            Spacer()
                            
                            Button(action: exportSettings) {
                                HStack(spacing: 6) {
                                    Image(systemName: "square.and.arrow.up")
                                    Text("Export")
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        
                        Text("Lưu toàn bộ cài đặt, macro, quy tắc. Phù hợp để backup hoặc chuyển sang máy khác.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                // Import Section
                SettingsGroup(title: "Khôi phục thiết lập") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Import cấu hình từ file đã lưu")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            Spacer()
                            
                            Button(action: importSettings) {
                                HStack(spacing: 6) {
                                    Image(systemName: "square.and.arrow.down")
                                    Text("Import")
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                                .font(.caption)
                            Text("Import sẽ ghi đè toàn bộ thiết lập hiện tại và tự động khởi động lại XKey.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                
                // Reset to Default Section
                SettingsGroup(title: "Khôi phục mặc định") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Đặt lại toàn bộ thiết lập về trạng thái ban đầu")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            Spacer()
                            
                            Button(action: { showResetConfirmation = true }) {
                                HStack(spacing: 6) {
                                    Image(systemName: "arrow.counterclockwise")
                                    Text("Reset")
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .tint(.red)
                        }
                        
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.red)
                                .font(.caption)
                            Text("Xoá toàn bộ cài đặt, macro, từ điển, quy tắc tuỳ chỉnh và cấu hình dịch thuật. Thao tác này không thể hoàn tác.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .alert(alertTitle, isPresented: $showSuccessAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(alertMessage)
        }
        .alert("Khôi phục mặc định?", isPresented: $showResetConfirmation) {
            Button("Huỷ", role: .cancel) { }
            Button("Khôi phục", role: .destructive) {
                performReset()
            }
        } message: {
            Text("Toàn bộ cài đặt, macro, từ điển tuỳ chỉnh, quy tắc và cấu hình dịch thuật sẽ bị xoá. XKey sẽ trở về trạng thái như mới cài đặt.\n\nHãy export backup trước nếu bạn muốn giữ lại thiết lập hiện tại.")
        }
        .sheet(isPresented: $showCountdownSheet) {
            RestartCountdownView(
                seconds: $countdownSeconds,
                title: restartReason.title,
                icon: restartReason.icon,
                iconColor: restartReason.iconColor,
                onCancel: {
                    stopCountdown()
                    showCountdownSheet = false
                },
                onRestart: {
                    stopCountdown()
                    showCountdownSheet = false
                    // Delay a bit to let sheet close, then restart
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        Self.performRestart()
                    }
                }
            )
            .onAppear {
                startCountdown()
            }
            .onDisappear {
                stopCountdown()
            }
        }
    }
    
    // MARK: - Export/Import Actions
    
    private func exportSettings() {
        guard let data = SharedSettings.shared.exportSettings() else {
            showAlert(title: String(localized: "Lỗi"), message: String(localized: "Không thể export thiết lập"))
            return
        }

        let panel = NSSavePanel()
        panel.title = "Export Settings"
        panel.message = String(localized: "Lưu file thiết lập XKey")
        panel.nameFieldStringValue = SharedSettings.shared.getExportFileName()
        panel.allowedContentTypes = [.propertyList]
        panel.canCreateDirectories = true
        
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try data.write(to: url)
                showAlert(title: String(localized: "Thành công"), message: String(localized: "Đã export thiết lập thành công"))
            } catch {
                showAlert(title: String(localized: "Lỗi"), message: String(localized: "Không thể lưu file: \(error.localizedDescription)"))
            }
        }
    }
    
    private func importSettings() {
        let panel = NSOpenPanel()
        panel.title = "Import Settings"
        panel.message = String(localized: "Chọn file thiết lập XKey để import")
        panel.allowedContentTypes = [.propertyList]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let data = try Data(contentsOf: url)
                if SharedSettings.shared.importSettings(from: data) {
                    // Show countdown sheet for auto-restart
                    restartReason = .importSettings
                    countdownSeconds = 3
                    showCountdownSheet = true
                } else {
                    showAlert(title: String(localized: "Lỗi"), message: String(localized: "File không hợp lệ hoặc không đúng định dạng"))
                }
            } catch {
                showAlert(title: String(localized: "Lỗi"), message: String(localized: "Không thể đọc file: \(error.localizedDescription)"))
            }
        }
    }
    
    private func exportFromiCloud() {
        guard let data = iCloudSyncManager.shared.exportCloudData() else {
            showAlert(title: String(localized: "Lỗi"), message: String(localized: "Không có dữ liệu trên iCloud"))
            return
        }

        let panel = NSSavePanel()
        panel.title = "Export iCloud Settings"
        panel.message = String(localized: "Lưu thiết lập từ iCloud ra file")
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        panel.nameFieldStringValue = "XKey-iCloud-\(df.string(from: Date())).plist"
        panel.allowedContentTypes = [.propertyList]
        panel.canCreateDirectories = true

        if panel.runModal() == .OK, let url = panel.url {
            do {
                try data.write(to: url)
                showAlert(title: String(localized: "Thành công"), message: String(localized: "Đã export thiết lập từ iCloud"))
            } catch {
                showAlert(title: String(localized: "Lỗi"), message: String(localized: "Không thể lưu file: \(error.localizedDescription)"))
            }
        }
    }

    // MARK: - Reset to Default
    
    private func performReset() {
        guard SharedSettings.shared.resetToDefaults() else {
            showAlert(title: String(localized: "Lỗi"), message: String(localized: "Không thể khôi phục mặc định. Vui lòng thử lại."))
            return
        }
        
        // Show countdown for restart
        restartReason = .resetToDefault
        countdownSeconds = 3
        showCountdownSheet = true
    }
    
    // MARK: - Countdown & Restart
    
    private func startCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [self] _ in
            DispatchQueue.main.async {
                if self.countdownSeconds > 1 {
                    self.countdownSeconds -= 1
                } else {
                    self.stopCountdown()
                    self.showCountdownSheet = false
                    // Delay a bit to let sheet close, then restart
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        Self.performRestart()
                    }
                }
            }
        }
    }
    
    private func stopCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
    }
    
    /// Restart the app using a shell script
    private static func performRestart() {
        let bundlePath = Bundle.main.bundleURL.path
        let pid = ProcessInfo.processInfo.processIdentifier
        
        // Create a shell script that will:
        // 1. Wait for this process to exit
        // 2. Relaunch the app
        let script = """
        while kill -0 \(pid) 2>/dev/null; do
            sleep 0.1
        done
        open "\(bundlePath)"
        """
        
        let task = Process()
        task.launchPath = "/bin/bash"
        task.arguments = ["-c", script]
        
        do {
            try task.run()
        } catch {
            NSLog("Failed to start restart script: \(error)")
        }
        
        // Force quit the app - use exit() instead of terminate() to avoid UI blocking
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            exit(0)
        }
    }
    
    private func showAlert(title: String, message: String) {
        alertTitle = title
        alertMessage = message
        showSuccessAlert = true
    }
}

// MARK: - iCloud Sync Helper Views

private func iCloudSyncStatusIcon(_ status: iCloudSyncStatus) -> some View {
    Group {
        switch status {
        case .synced:
            Image(systemName: "checkmark.icloud")
                .foregroundColor(.green)
        case .pushing:
            Image(systemName: "icloud.and.arrow.up")
                .foregroundColor(.blue)
        case .pulling:
            Image(systemName: "icloud.and.arrow.down")
                .foregroundColor(.blue)
        case .error:
            Image(systemName: "exclamationmark.icloud")
                .foregroundColor(.orange)
        default:
            Image(systemName: "icloud")
                .foregroundColor(.secondary)
        }
    }
    .font(.caption)
}

@ViewBuilder
private func iCloudSyncStatusText(_ status: iCloudSyncStatus, lastSyncDate: Date?) -> some View {
    switch status {
    case .synced:
        if let date = lastSyncDate {
            let timeStr = date.formatted(date: .abbreviated, time: .shortened)
            Text(String(localized: "Đã đồng bộ lúc \(timeStr)"))
                .font(.caption)
                .foregroundColor(.secondary)
        } else {
            Text("Đã đồng bộ")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    case .pushing:
        Text("Đang tải lên iCloud...")
            .font(.caption)
            .foregroundColor(.blue)
    case .pulling:
        Text("Đang tải về từ iCloud...")
            .font(.caption)
            .foregroundColor(.blue)
    case .error(let msg):
        Text(msg)
            .font(.caption)
            .foregroundColor(.orange)
    default:
        Text("Chờ đồng bộ")
            .font(.caption)
            .foregroundColor(.secondary)
    }
}

private func iCloudSyncItem(icon: String, text: String) -> some View {
    HStack(spacing: 3) {
        Image(systemName: icon)
            .font(.system(size: 9))
            .foregroundColor(.accentColor)
        Text(text)
            .font(.caption2)
            .foregroundColor(.secondary)
    }
}

/// Localized display name for a sync category — used in the first-enable prompt.
func iCloudSyncCategoryName(_ category: SyncCategory) -> String {
    switch category {
    case .scalars:      return String(localized: "Thiết lập")
    case .macros:       return String(localized: "Macro")
    case .rules:        return String(localized: "Quy tắc")
    case .excludedApps: return String(localized: "Ứng dụng loại trừ")
    case .userDict:     return String(localized: "Từ điển")
    }
}

/// Per-category byte usage row so the user can see which category is approaching the 1 MB cap.
private struct iCloudSyncQuotaMeter: View {
    @State private var refreshTick = 0
    @State private var statusObserver: NSObjectProtocol?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(SyncCategory.allCases, id: \.rawValue) { category in
                let bytes = iCloudSyncManager.shared.bytes(for: category) ?? 0
                let pct = min(Double(bytes) / 1_000_000.0, 1.0)
                HStack(spacing: 6) {
                    Text(iCloudSyncCategoryName(category))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .frame(width: 110, alignment: .leading)
                    ProgressView(value: pct)
                        .progressViewStyle(.linear)
                        .tint(pct >= 0.95 ? .red : (pct >= 0.8 ? .orange : .accentColor))
                    Text(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .frame(width: 64, alignment: .trailing)
                }
            }
        }
        .id(refreshTick)
        .onAppear {
            statusObserver = NotificationCenter.default.addObserver(
                forName: .iCloudSyncStatusDidChange,
                object: nil,
                queue: .main
            ) { _ in refreshTick &+= 1 }
        }
        .onDisappear {
            if let obs = statusObserver { NotificationCenter.default.removeObserver(obs) }
        }
    }
}

// MARK: - Restart Reason

/// Distinguishes restart context for appropriate UI messaging
enum RestartReason {
    case importSettings
    case resetToDefault
    
    var title: String {
        switch self {
        case .importSettings: return String(localized: "Import thành công!")
        case .resetToDefault: return String(localized: "Đã khôi phục mặc định!")
        }
    }
    
    var icon: String {
        switch self {
        case .importSettings: return "checkmark.circle.fill"
        case .resetToDefault: return "arrow.counterclockwise.circle.fill"
        }
    }
    
    var iconColor: Color {
        switch self {
        case .importSettings: return .green
        case .resetToDefault: return .orange
        }
    }
}

// MARK: - Restart Countdown View

struct RestartCountdownView: View {
    @Binding var seconds: Int
    let title: String
    let icon: String
    let iconColor: Color
    let onCancel: () -> Void
    let onRestart: () -> Void
    
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 36))
                .foregroundColor(iconColor)
            
            Text(title)
                .font(.headline)
            
            Text("XKey sẽ tự động khởi động lại sau")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            // Countdown display - compact
            HStack(spacing: 4) {
                Text("\(seconds)")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundColor(.accentColor)
                    .frame(width: 30)
                Text("giây")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 8)
            
            HStack(spacing: 12) {
                Button("Huỷ") {
                    onCancel()
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                
                Button("Khởi động lại ngay") {
                    onRestart()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
        }
        .padding(24)
        .frame(width: 280)
    }
}
