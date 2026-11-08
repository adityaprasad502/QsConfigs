pragma Singleton

import qs.modules.common
import qs.modules.common.functions
import Quickshell

/**
 * - Eases fuzzy searching for applications by name
 * - Guesses icon name for window class name
 */
Singleton {
    id: root
    property bool sloppySearch: Config.options?.search.sloppy ?? false
    property real scoreThreshold: 0.2
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

    function iconExists(iconName) {
        if (!iconName || iconName.length == 0) return false;
        return (Quickshell.iconPath(iconName, true).length > 0) 
            && !iconName.includes("image-missing");
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
