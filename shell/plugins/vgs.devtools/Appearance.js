.pragma library

// The Dev Tools window's own look, the table the manifest's `appearance`
// names and ThemeLogic.acceptAppearance judges (D023): each tool's brand
// colour, the tile each row draws its icon on, and the window's metrics.
// The window composes qs.Ui components, which follow the theme; what it
// draws itself reads this table alone. The active theme reaches it through
// `palette.accent`, `motion.scale` and its `scheme.mode`, which applies
// LIGHT. The metrics are the shipped theme's own values, from
// shell/Commons/Tokens.js: `inset.window` 16 for the padding,
// `hyprland.window.radius` 0 for the corner the content clears,
// `stack.group` 12 between the header, the sections and the foot,
// `stack.section` 24 between sections, `space.xs` 4 between lines,
// `stack.inline` 8 between a row's chips and actions,
// `row.twoLineHeight` 56 for a row, `size.window.width` 600 for the width
// and `size.panel.maxHeight` 600 for the height, `size.window.gutter` 12
// kept clear of a narrower or shorter screen's edges, so the window sits
// beside the shell's surfaces under that theme. The tile's size, corner and
// glyph are the window's own.

function color(value) { return { type: "color", value: value }; }
function length(value) { return { type: "length", value: value }; }
function number(value, min, max) { return { type: "number", value: value, min: min, max: max }; }

var TOKENS = {
    palette: {
        accent: color("#ff5a36")
    },
    motion: {
        scale: number(1, 0, 4)
    },
    brand: {
        claude: color("#D97757"),
        openai: color("#10A37F"),
        opencode: color("#14B8A6"),
        copilot: color("#6E40C9"),
        crush: color("#FF5C8A"),
        pi: color("#9DC4FF"),
        ohMyPi: color("#BF40FF"),
        google: color("#4285F4"),
        xai: color("#FFFFFF"),
        openrouter: color("#6467F2"),
        deepseek: color("#4D6BFE"),
        vercel: color("#FFFFFF"),
        cursor: color("#EDECEC"),
        hermes: color("#EDFF45"),
        meta: color("#0064E0"),
        herdr: color("#4A9EFF"),
        orca: color("#FFFFFF"),
        t3: color("#E24A8B"),
        cmux: color("#4285F4"),
        node: color("#5FA04E"),
        bun: color("#F9F1E1"),
        deno: color("#70FFAF"),
        go: color("#00ADD8"),
        python: color("#3776AB"),
        ruby: color("#CC342D"),
        java: color("#ED8B00"),
        zig: color("#F7A41D"),
        dotnet: color("#512BD4"),
        clojure: color("#5881D8"),
        scala: color("#DC322F"),
        elixir: color("#9B6BC7"),
        rust: color("#DEA584"),
        php: color("#777BB4"),
        laravel: color("#FF2D20"),
        symfony: color("#000000"),
        rails: color("#CC0000"),
        phoenix: color("#FD4F00"),
        ocaml: color("#EC6813"),
        vscode: color("#007ACC"),
        vscodium: color("#2F80ED"),
        zed: color("#084CCF"),
        sublime: color("#FF9800"),
        helix: color("#6B46C1"),
        neovim: color("#57A143"),
        emacs: color("#7F5AB6"),
        alacritty: color("#F46D01"),
        foot: color("#6E6E6E"),
        ghostty: color("#7C3AED"),
        kitty: color("#6C71C4"),
        mysql: color("#4479A1"),
        postgres: color("#4169E1"),
        redis: color("#FF4438"),
        mongodb: color("#47A248"),
        mariadb: color("#003545"),
        mssql: color("#CC2927")
    }
};

// A tile's glyph takes the colour that reads on its fill, black or white by
// ThemeLogic's `contrast`, so a white brand (xAI, Vercel) and a black one
// (Symfony) both read in either mode.
TOKENS.tile = {
    size: length(36),
    glyph: length(20),
    radius: length(6),
    neutral: color("#3f3f46"),
    neutralInk: color("contrast({tile.neutral})"),
    accent: color("{palette.accent}"),
    accentInk: color("contrast({tile.accent})"),
    ink: {}
};
Object.keys(TOKENS.brand).forEach(function (key) {
    TOKENS.tile.ink[key] = color("contrast({brand." + key + "})");
});

TOKENS.window = {
    width: length(600),
    maxHeight: length(600),
    gutter: length(12),
    padding: length(16),
    radius: length(0),
    gap: length(12),
    sectionGap: length(24)
};

// A row is at least `height` tall with `paddingY` above and below its
// tallest part; rows sit `spacing` apart, and a row's actions move under its
// text once they would take more than `stackShare` of the text's room.
TOKENS.row = {
    height: length(56),
    paddingY: length(8),
    spacing: length(4),
    gap: length(12),
    lineGap: length(4),
    actionGap: length(8),
    stackShare: number(0.5, 0, 1)
};

var LIGHT = {
    tile: {
        neutral: "#d4d4d8"
    }
};
