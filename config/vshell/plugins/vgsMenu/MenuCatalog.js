.pragma library

var categories = [
    {
        id: "all",
        label: "All",
        icon: "\uf00a",
        description: "Apps, actions, files, and folders"
    },
    {
        id: "apps",
        label: "Apps",
        icon: "\uf40e",
        description: "Installed applications"
    },
    {
        id: "files",
        label: "Files",
        icon: "\uf07b",
        description: "Find files, folders, and text"
    },
    {
        id: "capture",
        label: "Capture",
        icon: "\uf030",
        description: "Screenshots, OCR and screen recording"
    },
    {
        id: "appearance",
        label: "Appearance",
        icon: "\uf1fc",
        description: "Themes, wallpapers and screensaver"
    },
    {
        id: "shell",
        label: "Shell",
        icon: "\uea86",
        description: "VGS apps, settings and session controls"
    },
    {
        id: "system",
        label: "System",
        icon: "\uef1c",
        description: "Packages, maintenance and diagnostics"
    }
]

var items = [
    {
        category: "shell",
        title: "Cloud Sync",
        subtitle: "Manage cloud accounts and synced folders",
        icon: "\uebaa",
        keywords: ["cloud", "sync", "drive", "dropbox", "onedrive", "rclone", "backup", "vgs"],
        requiresCapability: "cloudsync",
        argv: ["{vshell}", "ipc", "call", "cloudsync", "open"]
    },
    {
        category: "shell",
        title: "VGS settings",
        subtitle: "Open shell settings",
        icon: "\ue8b8",
        keywords: ["vshell", "settings", "quickshell"],
        argv: ["{vshell}", "ipc", "call", "settings", "open"]
    },
    {
        category: "appearance",
        title: "Themes",
        subtitle: "Browse and apply themes",
        icon: "\uf1fc",
        keywords: ["theme", "picker", "dark", "light", "preview", "vgs"],
        argv: ["{vshell}", "ipc", "call", "theme-picker", "open"]
    },
    {
        category: "appearance",
        title: "Wallpapers",
        subtitle: "Browse and set wallpapers",
        icon: "\uf03e",
        keywords: ["wallpaper", "background", "browse", "vgs"],
        argv: ["{vshell}", "ipc", "call", "theme-picker", "openWallpapers"]
    },
    {
        category: "appearance",
        title: "Theme settings",
        subtitle: "App theming, imports, and saving themes",
        icon: "\uf186",
        keywords: ["theme", "dark", "light", "blueprint", "vgs"],
        argv: ["{vshell}", "ipc", "call", "settings", "openWith", "theme"]
    },
    {
        category: "appearance",
        title: "Wallpaper settings",
        subtitle: "Wallpaper behavior and theme-from-image tools",
        icon: "\uf03e",
        keywords: ["wallpaper", "background", "palette", "vgs"],
        argv: ["{vshell}", "ipc", "call", "settings", "openWith", "wallpaper"]
    },
    {
        category: "shell",
        title: "Plugin settings",
        subtitle: "Open bundled plugin controls",
        icon: "\uea86",
        keywords: ["plugins", "extensions", "settings", "vgs"],
        argv: ["{vshell}", "ipc", "call", "settings", "focusOrToggleWith", "plugins"]
    },
    {
        category: "shell",
        title: "Switch user",
        subtitle: "Open active-session switcher",
        icon: "\ue748",
        keywords: ["switch", "user", "session", "login", "tty", "seat"],
        argv: ["{vshell}", "ipc", "call", "sessions", "open"]
    },
    {
        category: "shell",
        title: "Restart VGS",
        subtitle: "Restart vshell.service",
        icon: "\uf021",
        keywords: ["restart", "reload", "service", "vshell"],
        argv: ["systemctl", "--user", "restart", "vshell.service"]
    },
    {
        category: "capture",
        title: "Capture",
        subtitle: "Choose screenshot, timer, OCR or recording options",
        icon: "\uf030",
        keywords: ["capture", "screenshot", "grim", "region", "window"],
        argv: ["{vshell}", "ipc", "call", "capture", "open"]
    },
    {
        category: "capture",
        title: "Screenshot region",
        subtitle: "Drag a region and copy the image",
        icon: "\uf125",
        keywords: ["capture", "screenshot", "region", "crop"],
        argv: ["{vshell}", "capture", "screenshot", "region"]
    },
    {
        category: "capture",
        title: "Screenshot fullscreen",
        subtitle: "Capture the focused monitor",
        icon: "\uf31e",
        keywords: ["capture", "screenshot", "fullscreen", "monitor"],
        argv: ["{vshell}", "capture", "screenshot", "fullscreen"]
    },
    {
        category: "capture",
        title: "Extract text",
        subtitle: "OCR a selected region and copy text",
        icon: "\uf031",
        keywords: ["ocr", "text", "screenshot", "tesseract"],
        argv: ["{vshell}", "capture", "text"]
    },
    {
        category: "capture",
        title: "Toggle screen recording",
        subtitle: "Start or stop GPU screen recording",
        icon: "\uf03d",
        keywords: ["record", "video", "gpu-screen-recorder", "screen"],
        argv: ["{vshell}", "capture", "screenrecording"]
    },
    {
        category: "system",
        title: "System update",
        subtitle: "Run configured repo package update",
        icon: "\uf0aa",
        keywords: ["pacman", "update", "upgrade", "system"],
        argv: ["{vshell}", "terminal", "exec", "--tui", "--hold", "--", "{vshell}", "update", "run", "system"]
    },
    {
        category: "system",
        title: "AUR update",
        subtitle: "Run configured AUR package update if available",
        icon: "\uf0ab",
        keywords: ["aur", "paru", "update", "upgrade"],
        argv: ["{vshell}", "terminal", "exec", "--tui", "--hold", "--", "{vshell}", "update", "run", "aur"]
    },
    {
        category: "system",
        title: "Dependency status",
        subtitle: "Show VGS feature dependency status",
        icon: "\uf05a",
        keywords: ["deps", "dependencies", "features", "status"],
        argv: ["{vshell}", "terminal", "exec", "--tui", "--hold", "--", "{vshell}", "deps", "status"]
    },
    {
        category: "apps",
        title: "Terminal",
        subtitle: "Open default terminal",
        icon: "\uf120",
        keywords: ["terminal", "shell"],
        argv: ["{vshell}", "terminal", "open"]
    },
    {
        category: "apps",
        title: "File manager",
        subtitle: "Open default file manager",
        icon: "\uf07b",
        keywords: ["files", "folder", "file manager"],
        argv: ["xdg-open", "{home}"]
    }
]
