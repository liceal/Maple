import AppKit

public final class UpdateChecker {
    public static let shared = UpdateChecker()

    /// 当前应用版本号，默认为 1.0.0
    public static var currentVersion: String {
        if let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String, !ver.isEmpty {
            return ver
        }
        return "1.0.0"
    }

    private let repoOwner = "liceal"
    private let repoName = "maple"

    private init() {}

    /// 检查更新
    /// - Parameter isUserInitiated: 是否为用户主动点击。如果为 true，当是最新版或失败时会弹窗告知用户；若为静默后台检查则不打扰用户。
    public func checkForUpdates(isUserInitiated: Bool = true) {
        guard let url = URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest") else {
            return
        }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue("Maple-App/\(UpdateChecker.currentVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }

            if let error = error {
                if isUserInitiated {
                    DispatchQueue.main.async {
                        self.showErrorAlert(message: "检查更新失败", detail: "网络连接异常，请检查网络后再试：\(error.localizedDescription)")
                    }
                }
                return
            }

            guard let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200, let data = data else {
                if isUserInitiated {
                    DispatchQueue.main.async {
                        // 404 说明还没有任何发布版本，属于初创阶段正常情况
                        self.showUpToDateAlert()
                    }
                }
                return
            }

            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let tagName = json["tag_name"] as? String {
                    
                    let remoteVer = tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
                    let localVer = UpdateChecker.currentVersion.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
                    let releaseNotes = (json["body"] as? String) ?? "修复若干已知问题，提升使用体验。"
                    let htmlUrl = (json["html_url"] as? String) ?? "https://maple.linxianao.com"

                    DispatchQueue.main.async {
                        if self.isVersion(remoteVer, newerThan: localVer) {
                            self.showNewVersionAlert(newVersion: remoteVer, currentVersion: localVer, notes: releaseNotes, downloadUrl: htmlUrl)
                        } else if isUserInitiated {
                            self.showUpToDateAlert()
                        }
                    }
                } else if isUserInitiated {
                    DispatchQueue.main.async {
                        self.showUpToDateAlert()
                    }
                }
            } catch {
                if isUserInitiated {
                    DispatchQueue.main.async {
                        self.showUpToDateAlert()
                    }
                }
            }
        }.resume()
    }

    /// 比较两个版本号：remote > local 返回 true
    private func isVersion(_ remote: String, newerThan local: String) -> Bool {
        let rParts = remote.split(separator: ".").compactMap { Int($0) }
        let lParts = local.split(separator: ".").compactMap { Int($0) }

        let count = max(rParts.count, lParts.count)
        for i in 0..<count {
            let r = i < rParts.count ? rParts[i] : 0
            let l = i < lParts.count ? lParts[i] : 0
            if r > l { return true }
            if r < l { return false }
        }
        return false
    }

    private func showNewVersionAlert(newVersion: String, currentVersion: String, notes: String, downloadUrl: String) {
        let alert = NSAlert()
        alert.messageText = "发现新版本 Maple v\(newVersion) 🍁"
        
        let trimmedNotes = notes.count > 300 ? String(notes.prefix(300)) + "\n..." : notes
        alert.informativeText = "当前版本：v\(currentVersion)\n\n更新说明：\n\(trimmedNotes)"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "前往下载")
        alert.addButton(withTitle: "稍后提示")

        if let appIcon = NSApp.applicationIconImage {
            alert.icon = appIcon
        }

        let resp = alert.runModal()
        if resp == .alertFirstButtonReturn {
            if let url = URL(string: "https://maple.linxianao.com") ?? URL(string: downloadUrl) {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func showUpToDateAlert() {
        let alert = NSAlert()
        alert.messageText = "已是最新版本"
        alert.informativeText = "Maple v\(UpdateChecker.currentVersion) 目前已是最新版本，无需更新。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好")

        if let appIcon = NSApp.applicationIconImage {
            alert.icon = appIcon
        }

        alert.runModal()
    }

    private func showErrorAlert(message: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}
