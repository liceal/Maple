import AppKit

/// 支持的界面语言
public enum AppLanguage: String, CaseIterable, Codable {
    case system = "system"
    case zhHans = "zh-Hans"
    case en     = "en"
    case zhHant = "zh-Hant"
    case ja     = "ja"

    public var title: String {
        switch self {
        case .system: return "跟随系统 (System)"
        case .zhHans: return "简体中文"
        case .en:     return "English"
        case .zhHant: return "繁體中文"
        case .ja:     return "日本語"
        }
    }
}

/// 集中多语言管理中心 (Lightweight Dynamic I18n Manager)
public final class I18n {
    public static let shared = I18n()

    private init() {}

    /// 当前实际生效的语言 (若为 system 则探测系统首选语言)
    public var currentLanguage: AppLanguage {
        let pref = AppSettings.language
        if pref != .system { return pref }
        let preferred = Locale.preferredLanguages.first ?? "en"
        if preferred.starts(with: "zh-Hant") || preferred.starts(with: "zh-TW") || preferred.starts(with: "zh-HK") {
            return .zhHant
        } else if preferred.starts(with: "zh") {
            return .zhHans
        } else if preferred.starts(with: "ja") {
            return .ja
        } else {
            return .en
        }
    }

    /// 获取本地化翻译
    public func localized(_ key: String) -> String {
        let lang = currentLanguage
        if lang == .zhHans {
            return key // 源代码中 key 默认采用中文表达，直接返回
        }

        if let dict = translations[lang], let val = dict[key] {
            return val
        }
        // 回退机制：若是繁体或日语没有对应词条，回退到英文或简体
        if lang == .zhHant, let val = translations[.zhHant]?[key] ?? translations[.en]?[key] {
            return val
        }
        if lang == .ja, let val = translations[.ja]?[key] ?? translations[.en]?[key] {
            return val
        }
        return translations[.en]?[key] ?? key
    }

    // MARK: - 词条对照字典表
    private let translations: [AppLanguage: [String: String]] = [
        .en: [
            // 应用主菜单与通用
            "关于 Maple": "About Maple",
            "设置与权限管理…": "Settings & Permissions…",
            "偏好设置…": "Preferences…",
            "隐藏 Maple": "Hide Maple",
            "隐藏其他": "Hide Others",
            "退出 Maple": "Quit Maple",
            "文件": "File",
            "新建窗口": "New Window",
            "新建文件夹": "New Folder",
            "重命名": "Rename",
            "移到废纸篓": "Move to Trash",
            "拷贝路径": "Copy Path",
            "在终端中打开": "Open in Terminal",
            "在 Finder 中显示": "Reveal in Finder",
            "刷新": "Refresh",
            "显示简介": "Get Info",
            "关闭窗口": "Close Window",
            "编辑": "Edit",
            "撤销": "Undo",
            "重做": "Redo",
            "剪切": "Cut",
            "拷贝": "Copy",
            "粘贴": "Paste",
            "全选": "Select All",
            "显示": "View",
            "窗口": "Window",
            "帮助": "Help",
            "最小化": "Minimize",
            "缩放": "Zoom",
            "全部置于顶层": "Bring All to Front",
            "列表": "List",
            "图标": "Icons",
            "分栏": "Columns",
            "显示隐藏文件": "Show Hidden Files",
            "好": "OK",
            "取消": "Cancel",
            "确定": "Confirm",
            "完成": "Done",
            "删除": "Delete",
            "搜索": "Search",
            "信息": "Info",
            "更多": "More",
            "更少": "Fewer",

            // 布局模式
            "四宫格": "2x2 Grid",
            "左右两栏": "2 Columns",
            "左二右一": "2 Left, 1 Right",
            "左一右二": "1 Left, 2 Right",
            "上整下二": "Top 1, Bottom 2",
            "上二下整": "Top 2, Bottom 1",
            "上下两行": "2 Rows",
            "单窗格": "Single Pane",
            "窗口排列方式": "Window Layout",

            // 侧边栏与分类
            "个人收藏": "Favorites",
            "位置": "Locations",
            "服务器": "Servers",
            "标签": "Tags",
            "应用程序": "Applications",
            "桌面": "Desktop",
            "文稿": "Documents",
            "下载": "Downloads",
            "图片": "Pictures",
            "影片": "Movies",
            "音乐": "Music",
            "主目录": "Home",
            "废纸篓": "Trash",
            "连接服务器…": "Connect to Server…",
            "浏览网络邻居 (/Network)": "Browse Network (/Network)",
            "展示分类": "Show Categories",
            "显示全部分类": "Show All Categories",
            "展开全部分组": "Expand All Groups",
            "偏好设置与权限管理 (⌘,)": "Preferences & Permissions (⌘,)",
            "侧栏选项与操作": "Sidebar Options & Actions",

            // 窗格操作与提示
            "后退": "Back",
            "前进": "Forward",
            "窗格操作": "Pane Actions",
            "显示/隐藏右侧预览窗格": "Toggle Preview Pane",
            "文件夹为空": "Folder is Empty",
            "大小": "Size",
            "种类": "Kind",
            "创建时间": "Created",
            "修改时间": "Modified",
            "最后打开时间": "Last Opened",
            "上次打开时间": "Last Opened",
            "标题": "Title",
            "作者": "Authors",
            "页数": "Pages",
            "安全性": "Security",
            "内容创作者": "Content Creator",
            "编码软件": "Encoding Software",
            "尺寸": "Dimensions",
            "分辨率": "Resolution",
            "色彩空间": "Color Space",
            "颜色描述文件": "Color Profile",
            "相机制造商标": "Make",
            "焦距": "Focal Length",
            "光圈": "F-Number",
            "曝光时间": "Exposure Time",
            "ISO 速度": "ISO Speed",
            "时长": "Duration",
            "表演者": "Artist",
            "专辑": "Album",
            "流派": "Genre",
            "音频声道": "Audio Channels",
            "采样速率": "Sample Rate",
            "比特率": "Bitrate",
            "版权": "Copyright",
            "设备型号": "Device Model",
            "颜色空间": "Color Space",
            "编解码器": "Codecs",
            "链接目标": "Link Target",
            "架构": "Architecture",
            "通用": "Universal",
            "Apple 芯片": "Apple Silicon",
            "Intel 64 位": "Intel 64-bit",
            "Alpha 通道": "Alpha channel",
            "是": "Yes",
            "否": "No",
            "正在计算…": "Calculating…",
            "零个项目": "Zero items",
            "项": "items",
            "已选择": "Selected",
            "可用空间": "Available",

            // 设置面板
            "常规": "General",
            "使用习惯": "Habits",
            "权限": "Permissions",
            "右键菜单": "Context Menu",
            "新建文件": "New File",
            "快捷键": "Shortcuts",
            "版本": "About",
            "外观": "Appearance",
            "语言": "Language",
            "跟随系统": "System",
            "深色": "Dark",
            "浅色": "Light",
            "显示边框": "Show Borders",
            "高亮地址栏": "Highlight Path Bar",
            "圆角": "Corner Radius",
            "显示项目信息": "Show Item Info",
            "默认隐藏": "Hide by Default",
            "在底部状态栏显示选择项目大小": "Show Selected Size in Status Bar",
            "计算并显示文件夹大小": "Calculate and Display Folder Sizes",
            "显示以点（.）开头的隐藏文件（快捷键 ⌘⇧.）": "Show Hidden Files Starting with '.' (⌘⇧.)",
            "在列表视图中显示交替行底色（斑马线）": "Show Zebra Stripes in List View",
            "图标大小": "Icon Size",
            "列表行高": "List Row Height",
            "恢复默认": "Restore Defaults",
            "设置为默认": "Set as Default",
            "彩色图标": "Colorful Icons",
            "简约图标": "Minimalist Icons"
        ],
        .zhHant: [
            "关于 Maple": "關於 Maple",
            "设置与权限管理…": "設定與權限管理…",
            "隐藏 Maple": "隱藏 Maple",
            "隐藏其他": "隱藏其他",
            "退出 Maple": "結束 Maple",
            "文件": "檔案",
            "新建窗口": "新增視窗",
            "新建文件夹": "新增資料夾",
            "重命名": "重新命名",
            "移到废纸篓": "移至垃圾桶",
            "拷贝路径": "拷貝路徑",
            "在终端中打开": "在終端機中開啟",
            "在 Finder 中显示": "在 Finder 中顯示",
            "刷新": "重新整理",
            "显示简介": "取得資訊",
            "关闭窗口": "關閉視窗",
            "编辑": "編輯",
            "撤销": "復原",
            "重做": "重做",
            "剪切": "剪下",
            "拷贝": "拷貝",
            "粘贴": "貼上",
            "全选": "全選",
            "显示": "顯示",
            "窗口": "視窗",
            "帮助": "輔助說明",
            "最小化": "縮到最小",
            "缩放": "縮放",
            "列表": "列表",
            "图标": "圖像",
            "分栏": "直欄",
            "显示隐藏文件": "顯示隱藏檔案",
            "好": "好",
            "取消": "取消",
            "确定": "確定",
            "文件夹为空": "資料夾為空",
            "个人收藏": "常用項目",
            "位置": "位置",
            "常规": "一般",
            "外观": "外觀",
            "语言": "語言",
            "跟随系统": "系統偏好",
            "深色": "深色",
            "浅色": "淺色",
            "更多": "更多",
            "更少": "更少",
            "信息": "資訊",
            "大小": "大小",
            "创建时间": "製作時間",
            "修改时间": "修改時間",
            "上次打开时间": "上次打開時間",
            "标题": "標題",
            "作者": "作者",
            "版本": "版本",
            "页数": "頁數",
            "安全性": "安全性",
            "内容创作者": "內容創作者",
            "编码软件": "編碼軟體",
            "尺寸": "尺寸",
            "分辨率": "解析度",
            "色彩空间": "色彩空間",
            "颜色描述文件": "色彩描述",
            "相机制造商标": "製造商",
            "焦距": "焦距",
            "光圈": "光圈",
            "曝光时间": "曝光時間",
            "ISO 速度": "ISO 速度",
            "时长": "時間",
            "表演者": "演出者",
            "专辑": "專輯",
            "流派": "樂風",
            "音频声道": "音訊聲道",
            "采样速率": "取樣速率",
            "比特率": "位元率",
            "版权": "版權",
            "设备型号": "設備型號",
            "颜色空间": "色彩空間",
            "编解码器": "轉碼器",
            "链接目标": "連結目標",
            "架构": "架構",
            "通用": "通用",
            "Apple 芯片": "Apple 晶片",
            "Intel 64 位": "Intel 64 位元",
            "Alpha 通道": "Alpha 色板",
            "是": "是",
            "否": "否"
        ],
        .ja: [
            "关于 Maple": "Maple について",
            "设置与权限管理…": "設定と権限…",
            "隐藏 Maple": "Maple を隠す",
            "隐藏其他": "ほかを隠す",
            "退出 Maple": "Maple を終了",
            "文件": "ファイル",
            "新建窗口": "新規ウインドウ",
            "新建文件夹": "新規フォルダ",
            "重命名": "名前を変更",
            "移到废纸篓": "ゴミ箱に入れる",
            "拷贝路径": "パスをコピー",
            "在终端中打开": "ターミナルで開く",
            "在 Finder 中显示": "Finder で表示",
            "刷新": "更新",
            "显示简介": "情報を見る",
            "关闭窗口": "ウインドウを閉じる",
            "编辑": "編集",
            "撤销": "取り消す",
            "重做": "やり直す",
            "剪切": "カット",
            "拷贝": "コピー",
            "粘贴": "ペースト",
            "全选": "すべてを選択",
            "显示": "表示",
            "窗口": "ウインドウ",
            "帮助": "ヘルプ",
            "列表": "リスト",
            "图标": "アイコン",
            "分栏": "カラム",
            "显示隐藏文件": "不可視ファイルを表示",
            "好": "OK",
            "取消": "キャンセル",
            "确定": "確認",
            "文件夹为空": "空のフォルダ",
            "个人收藏": "よく使う項目",
            "位置": "場所",
            "常规": "一般",
            "外观": "外観",
            "语言": "言語",
            "跟随系统": "システム設定に従う",
            "深色": "ダーク",
            "浅色": "ライト",
            "更多": "詳細",
            "更少": "簡易",
            "信息": "情報",
            "大小": "サイズ",
            "创建时间": "作成日",
            "修改时间": "変更日",
            "上次打开时间": "最後に開いた日時",
            "标题": "タイトル",
            "作者": "作成者",
            "版本": "バージョン",
            "页数": "ページ数",
            "安全性": "セキュリティ",
            "内容创作者": "コンテンツ作成者",
            "编码软件": "エンコードソフトウェア",
            "尺寸": "寸法",
            "分辨率": "解像度",
            "色彩空间": "カラープロファイル",
            "颜色描述文件": "カラープロファイル",
            "相机制造商标": "製造元",
            "焦距": "焦点距離",
            "光圈": "絞り値",
            "曝光时间": "露出時間",
            "ISO 速度": "ISO スピード",
            "时长": "再生時間",
            "表演者": "アーティスト",
            "专辑": "アルバム",
            "流派": "ジャンル",
            "音频声道": "オーディオチャンネル",
            "采样速率": "サンプルレート",
            "比特率": "ビットレート",
            "版权": "著作権",
            "设备型号": "機器の型式",
            "颜色空间": "カラープロファイル",
            "编解码器": "コーデック",
            "链接目标": "リンク先",
            "架构": "アーキテクチャ",
            "通用": "Universal",
            "Apple 芯片": "Apple シリコン",
            "Intel 64 位": "Intel 64 ビット",
            "Alpha 通道": "アルファチャンネル",
            "是": "はい",
            "否": "いいえ"
        ]
    ]
}

// MARK: - 快捷 String 语法糖
public extension String {
    var localized: String {
        return I18n.shared.localized(self)
    }
}

public struct L10n {
    public static func t(_ key: String) -> String {
        return I18n.shared.localized(key)
    }
}
