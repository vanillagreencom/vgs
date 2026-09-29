.pragma library

function color(value) { return { type: "color", value: value }; }
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

var LIGHT = {};
