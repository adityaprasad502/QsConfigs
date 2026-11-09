pragma Singleton

import qs.modules.common
import qs.modules.common.functions
import QtQuick
import Quickshell
import Quickshell.Io

/**
 * - Eases fuzzy searching for applications by name
 * - Guesses icon name for window class name
 */
Singleton {
    id: root
    property bool sloppySearch: Config.options?.search.sloppy ?? false
    property real scoreThreshold: 0.2
    property int fallbackRevision: 0
    property var fallbackIconUrls: ({})
    property var _pendingFallbackMap: ({})
    property var _pendingFallbackQueue: []
    property var _activeFallbackBatch: []
    readonly property string _iconLookupScript: `
import configparser, json, os, sys
from urllib.parse import quote

xdg_data_home = os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share")
xdg_data_dirs = [d for d in os.environ.get("XDG_DATA_DIRS", "/usr/local/share:/usr/share").split(":") if d]
icon_roots = [os.path.join(xdg_data_home, "icons"), os.path.expanduser("~/.icons")] + [os.path.join(d, "icons") for d in xdg_data_dirs]
pixmap_roots = [os.path.join(xdg_data_home, "pixmaps")] + [os.path.join(d, "pixmaps") for d in xdg_data_dirs]

themes = []
cfg_home = os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config")
kdeglobals = os.path.join(cfg_home, "kdeglobals")
if os.path.isfile(kdeglobals):
    cp = configparser.ConfigParser(interpolation=None, strict=False)
    try:
        cp.read(kdeglobals)
        t = cp.get("Icons", "Theme", fallback="").strip()
        if t:
            themes.append(t)
    except Exception:
        pass
gtk_ini = os.path.join(cfg_home, "gtk-3.0", "settings.ini")
if os.path.isfile(gtk_ini):
    cp = configparser.ConfigParser(interpolation=None, strict=False)
    try:
        cp.read(gtk_ini)
        t = cp.get("Settings", "gtk-icon-theme-name", fallback="").strip()
        if t and t not in themes:
            themes.append(t)
    except Exception:
        pass
for t in ("breeze-plus-dark", "breeze-dark", "breeze", "hicolor"):
    if t not in themes:
        themes.append(t)

seen_t = []
theme_dirs_map = {}
queue = list(themes)
while queue:
    t = queue.pop(0)
    if not t or t in seen_t:
        continue
    seen_t.append(t)
    extra_dirs = []
    for r in icon_roots:
        it = os.path.join(r, t, "index.theme")
        if os.path.isfile(it):
            cp = configparser.ConfigParser(interpolation=None, strict=False)
            try:
                cp.read(it)
                for inh in cp.get("Icon Theme", "Inherits", fallback="").split(","):
                    inh = inh.strip()
                    if inh and inh not in seen_t and inh not in queue:
                        queue.append(inh)
                for d in cp.get("Icon Theme", "Directories", fallback="").split(","):
                    d = d.strip()
                    if d and d not in extra_dirs:
                        extra_dirs.append(d)
            except Exception:
                pass
    theme_dirs_map[t] = extra_dirs
if "hicolor" not in seen_t:
    seen_t.append("hicolor")
    theme_dirs_map.setdefault("hicolor", [])

preferred_subdirs = [
    "scalable/apps", "scalable", "512x512/apps", "256x256/apps", "192x192/apps",
    "128x128/apps", "96x96/apps", "64x64/apps", "48x48/apps", "32x32/apps",
    "24x24/apps", "22x22/apps", "16x16/apps",
    "apps/scalable", "apps/256", "apps/128", "apps/64", "apps/48", "apps/32",
    "apps/24", "apps/22", "apps/16", "symbolic/apps",
    "scalable/categories", "scalable/places", "scalable/devices",
    "scalable/status", "scalable/mimetypes", "48x48/status", "22x22/status",
]
exts = (".svg", ".png", ".svgz", ".xpm")

def find_icon(name):
    if not name:
        return ""
    if os.path.isabs(name):
        return "file://" + quote(name) if os.path.isfile(name) else ""
    if "/" in name:
        return ""
    candidates = (name,) if name.lower().endswith(exts) else tuple(name + e for e in exts)
    for pass_all in (False, True):
        for theme in seen_t:
            subdirs = preferred_subdirs if not pass_all else theme_dirs_map.get(theme, [])
            for r in icon_roots:
                tdir = os.path.join(r, theme)
                if not os.path.isdir(tdir):
                    continue
                for sd in subdirs:
                    sdir = os.path.join(tdir, sd)
                    if not os.path.isdir(sdir):
                        continue
                    for cand in candidates:
                        p = os.path.join(sdir, cand)
                        if os.path.isfile(p):
                            return "file://" + quote(p)
        if not pass_all:
            for pdir in pixmap_roots:
                if not os.path.isdir(pdir):
                    continue
                for cand in candidates:
                    p = os.path.join(pdir, cand)
                    if os.path.isfile(p):
                        return "file://" + quote(p)
    return ""

print(json.dumps({n: find_icon(n) for n in sys.argv[1:]}))
`
    property var substitutions: ({
        "code-url-handler": "visual-studio-code",
        "Code": "visual-studio-code",
        "codium": "vscodium",
        "codium-url-handler": "vscodium",
        "gnome-tweaks": "org.gnome.tweaks",
        "pavucontrol-qt": "pavucontrol",
        "wps": "wps-office2019-kprometheus",
        "wpsoffice": "wps-office2019-kprometheus",
        "footclient": "foot",
        "Spotify": "spotify",
        "spotify": "spotify",
        "helium": "helium-browser",
        "desktop-plus": "gh-desktop-plus",
        "dolphin": "org.kde.dolphin",
        "yukigram": "io.github.yukigram",
        "antigravity": "antigravity",
        "Antigravity": "antigravity",
    })
    property var regexSubstitutions: [
        {
            "regex": /^steam_app_(\d+)$/,
            "replace": "steam_icon_$1"
        },
        {
            "regex": /Minecraft.*/,
            "replace": "minecraft"
        },
        {
            "regex": /.*polkit.*/,
            "replace": "system-lock-screen"
        },
        {
            "regex": /gcr.prompter/,
            "replace": "system-lock-screen"
        }
    ]

    // Deduped list to fix double icons
    readonly property list<DesktopEntry> list: Array.from(DesktopEntries.applications.values)
        .filter((app, index, self) => 
            index === self.findIndex((t) => (
                t.id === app.id
            ))
    )
    
    readonly property var preppedNames: list.map(a => ({
        name: Fuzzy.prepare(`${a.name} `),
        entry: a
    }))

    readonly property var preppedIcons: list.map(a => ({
        name: Fuzzy.prepare(`${a.icon} `),
        entry: a
    }))

    function fuzzyQuery(search: string): var { // Idk why list<DesktopEntry> doesn't work
        if (root.sloppySearch) {
            const results = list.map(obj => ({
                entry: obj,
                score: Levendist.computeScore(obj.name.toLowerCase(), search.toLowerCase())
            })).filter(item => item.score > root.scoreThreshold)
                .sort((a, b) => b.score - a.score)
            return results
                .map(item => item.entry)
        }

        return Fuzzy.go(search, preppedNames, {
            all: true,
            key: "name"
        }).map(r => {
            return r.obj.entry
        });
    }

    function _queueFallbackLookup(iconName) {
        if (!iconName || iconName === "image-missing") return;
        if (Object.prototype.hasOwnProperty.call(root.fallbackIconUrls, iconName)) return;
        if (root._pendingFallbackMap[iconName]) return;
        root._pendingFallbackMap[iconName] = true;
        root._pendingFallbackQueue.push(iconName);
        Qt.callLater(root._flushFallbackLookups);
    }

    function _flushFallbackLookups() {
        if (iconFallbackProc.running || root._pendingFallbackQueue.length === 0) return;
        const batch = root._pendingFallbackQueue.slice();
        root._pendingFallbackQueue = [];
        root._activeFallbackBatch = batch;
        iconFallbackProc.command = ["python3", "-c", root._iconLookupScript, ...batch];
        iconFallbackProc.running = true;
    }

    function resolveIconSource(iconName, fallback) {
        const _rev = root.fallbackRevision;
        const effectiveFallback = (fallback === undefined) ? "image-missing" : fallback;
        if (!iconName || typeof iconName !== "string") {
            return effectiveFallback ? Quickshell.iconPath(effectiveFallback) : "";
        }
        const trimmed = iconName.trim();
        if (!trimmed || trimmed === "image-missing") {
            return effectiveFallback ? Quickshell.iconPath(effectiveFallback) : "";
        }
        if (trimmed.startsWith("/")) {
            return "file://" + trimmed;
        }
        if (trimmed.startsWith("file://") || trimmed.startsWith("image://") || trimmed.startsWith("qrc:/")) {
            return trimmed;
        }
        if (Quickshell.iconPath(trimmed, true).length > 0) {
            return effectiveFallback ? Quickshell.iconPath(trimmed, effectiveFallback) : Quickshell.iconPath(trimmed);
        }
        if (Object.prototype.hasOwnProperty.call(root.fallbackIconUrls, trimmed)) {
            const resolved = root.fallbackIconUrls[trimmed];
            if (resolved && resolved.length > 0) return resolved;
            return effectiveFallback ? Quickshell.iconPath(effectiveFallback) : "";
        }
        root._queueFallbackLookup(trimmed);
        return "";
    }

    Process {
        id: iconFallbackProc
        stdout: StdioCollector {
            id: iconFallbackCollector
            onStreamFinished: {
                const batch = root._activeFallbackBatch;
                root._activeFallbackBatch = [];
                let parsed = ({});
                const raw = iconFallbackCollector.text.trim();
                if (raw.length > 0) {
                    try {
                        parsed = JSON.parse(raw) || ({});
                    } catch (e) {
                        console.warn("[AppSearch] Failed to parse fallback icon lookup:", e);
                    }
                }
                const next = Object.assign({}, root.fallbackIconUrls);
                for (let i = 0; i < batch.length; ++i) {
                    const name = batch[i];
                    delete root._pendingFallbackMap[name];
                    next[name] = (typeof parsed[name] === "string") ? parsed[name] : "";
                }
                root.fallbackIconUrls = next;
                root.fallbackRevision += 1;
                if (root._pendingFallbackQueue.length > 0) {
                    Qt.callLater(root._flushFallbackLookups);
                }
            }
        }
    }

    function iconExists(iconName) {
        if (!iconName || iconName.length == 0 || iconName.includes("image-missing")) return false;
        if (Quickshell.iconPath(iconName, true).length > 0) return true;
        return Object.prototype.hasOwnProperty.call(root.fallbackIconUrls, iconName)
            && Boolean(root.fallbackIconUrls[iconName]);
    }

    function getReverseDomainNameAppName(str) {
        return str.split('.').slice(-1)[0]
    }

    function getKebabNormalizedAppName(str) {
        return str.toLowerCase().replace(/\s+/g, "-");
    }

    function getUndescoreToKebabAppName(str) {
        return str.toLowerCase().replace(/_/g, "-");
    }

    function guessIcon(str) {
        if (!str || str.length == 0) return "image-missing";

        const trimmed = str.trim();
        const lower = trimmed.toLowerCase();

        // Direct desktop entry lookup
        const entry = DesktopEntries.byId(trimmed) || DesktopEntries.byId(lower);
        if (entry && entry.icon) return entry.icon;

        // Normal substitutions
        if (substitutions[trimmed]) return substitutions[trimmed];
        if (substitutions[lower]) return substitutions[lower];

        // Regex substitutions
        for (let i = 0; i < regexSubstitutions.length; i++) {
            const substitution = regexSubstitutions[i];
            const replacedName = trimmed.replace(
                substitution.regex,
                substitution.replace,
            );
            if (replacedName != trimmed) return replacedName;
        }

        // Heuristic lookup (matches WM_CLASS, StartupWMClass, binary)
        const heuristicEntry = DesktopEntries.heuristicLookup(trimmed) || DesktopEntries.heuristicLookup(lower);
        if (heuristicEntry && heuristicEntry.icon) return heuristicEntry.icon;

        // Icon exists in theme -> return as is
        if (iconExists(trimmed)) return trimmed;
        if (iconExists(lower)) return lower;

        // Reverse domain name guesses (org.kde.dolphin -> dolphin, io.github.yukigram -> yukigram)
        const reverseDomainNameAppName = getReverseDomainNameAppName(trimmed);
        if (iconExists(reverseDomainNameAppName)) return reverseDomainNameAppName;

        const lowercasedDomainNameAppName = reverseDomainNameAppName.toLowerCase();
        if (iconExists(lowercasedDomainNameAppName)) return lowercasedDomainNameAppName;

        const reverseEntry = DesktopEntries.byId(reverseDomainNameAppName) || DesktopEntries.byId(lowercasedDomainNameAppName) || DesktopEntries.heuristicLookup(reverseDomainNameAppName);
        if (reverseEntry && reverseEntry.icon) return reverseEntry.icon;

        const kebabNormalizedGuess = getKebabNormalizedAppName(trimmed);
        if (iconExists(kebabNormalizedGuess)) return kebabNormalizedGuess;

        const undescoreToKebabGuess = getUndescoreToKebabAppName(trimmed);
        if (iconExists(undescoreToKebabGuess)) return undescoreToKebabGuess;

        // Search in desktop entries
        const iconSearchResults = Fuzzy.go(trimmed, preppedIcons, {
            all: true,
            key: "name"
        }).map(r => {
            return r.obj.entry
        });
        if (iconSearchResults.length > 0) {
            const guess = iconSearchResults[0].icon
            if (iconExists(guess)) return guess;
        }

        const nameSearchResults = root.fuzzyQuery(trimmed);
        if (nameSearchResults.length > 0) {
            const guess = nameSearchResults[0].icon
            if (iconExists(guess)) return guess;
        }

        // Give up
        if (iconExists("application-x-executable")) return "application-x-executable";
        return "image-missing";
    }
}
