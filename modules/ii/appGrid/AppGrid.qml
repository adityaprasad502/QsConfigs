pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Qt.labs.folderlistmodel
import Quickshell
import Quickshell.Io
import Quickshell.Widgets
import Quickshell.Wayland
import Quickshell.Hyprland
import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions

Scope {
    id: root

    // Scan user's local applications directory (~/.local/share/applications)
    FolderListModel {
        id: localAppsFolder
        folder: Qt.resolvedUrl(`${Directories.home}/.local/share/applications`)
        nameFilters: ["*.desktop"]
        showDirs: false
    }

    readonly property var localDesktopIds: {
        const s = new Set();
        for (let i = 0; i < localAppsFolder.count; i++) {
            const fn = localAppsFolder.get(i, "fileName");
            if (fn) {
                s.add(fn);
                s.add(fn.replace(/\.desktop$/, ""));
            }
        }
        return s;
    }

    // Detailed package map: desktop_filename -> { pkg: "package-name", source: "AUR" | "Pacman" }
    property var appPackageMap: ({})

    Process {
        id: pkgDetectorProc
        running: true
        command: [
            "python3", "-c",
            "import os, subprocess\n" +
            "try:\n" +
            "    aur = set(subprocess.run(['pacman', '-Qmq'], capture_output=True, text=True).stdout.strip().splitlines())\n" +
            "except Exception:\n" +
            "    aur = set()\n" +
            "local_dir = '/var/lib/pacman/local'\n" +
            "if os.path.isdir(local_dir):\n" +
            "    for pkg in os.listdir(local_dir):\n" +
            "        pkgname = '-'.join(pkg.split('-')[:-2])\n" +
            "        source = 'AUR' if pkgname in aur else 'Pacman'\n" +
            "        fp = os.path.join(local_dir, pkg, 'files')\n" +
            "        if os.path.isfile(fp):\n" +
            "            with open(fp, 'r', errors='ignore') as f:\n" +
            "                for line in f:\n" +
            "                    line = line.strip()\n" +
            "                    if line.startswith('usr/share/applications/') and line.endswith('.desktop'):\n" +
            "                        fn = os.path.basename(line)\n" +
            "                        print(f'{fn}\\t{pkgname}\\t{source}')\n"
        ]

        stdout: SplitParser {
            splitMarker: "\n"
            onRead: data => {
                if (!data) return;
                const lines = data.trim().split("\n");
                const map = Object.assign({}, root.appPackageMap);
                for (const line of lines) {
                    const parts = line.trim().split("\t");
                    if (parts.length >= 3) {
                        const fn = parts[0];
                        const pkg = parts[1];
                        const src = parts[2];
                        const info = { pkg: pkg, source: src };
                        map[fn] = info;
                        map[fn.replace(/\.desktop$/, "")] = info;
                    }
                }
                root.appPackageMap = map;
            }
        }
    }

    function launchApp(entry, forceTerminal = false) {
        if (!entry) return;
        GlobalStates.appGridOpen = false;
        if (forceTerminal || entry.runInTerminal) {
            const cmd = entry.command && entry.command.length > 0 ? entry.command.join(' ') : entry.id;
            Quickshell.execDetached(["bash", "-c", `${Config.options.apps.terminal} -e ${cmd}`]);
        } else {
            entry.execute();
        }
    }

    function getAppSource(entry) {
        if (!entry) return "";
        const rawId = entry.id || "";
        const id = rawId.toLowerCase();
        const cleanId = rawId.replace(/\.desktop$/, "");
        const cmd = (entry.command ? entry.command.join(" ") : (entry.execString || "")).toLowerCase();

        if (cmd.includes("flatpak") || id.includes("flatpak")) return "Flatpak";
        if (cmd.includes(".appimage") || id.includes("appimage")) return "AppImage";
        if (cmd.includes("snap") || id.includes("snap")) return "Snap";
        if (root.localDesktopIds.has(rawId) || root.localDesktopIds.has(cleanId) || root.localDesktopIds.has(rawId + ".desktop")) return "Local";

        const pkgInfo = root.appPackageMap[rawId] || root.appPackageMap[cleanId] || root.appPackageMap[rawId + ".desktop"];
        if (pkgInfo && pkgInfo.source) {
            return pkgInfo.source; // "AUR" or "Pacman"
        }

        // Unowned desktop entry installed manually via terminal/CLI (e.g. Omen Space)
        return "kitty";
    }

    function getAppPackage(entry) {
        if (!entry) return "";
        const rawId = entry.id || "";
        const cleanId = rawId.replace(/\.desktop$/, "");
        const pkgInfo = root.appPackageMap[rawId] || root.appPackageMap[cleanId] || root.appPackageMap[rawId + ".desktop"];
        return pkgInfo ? (pkgInfo.pkg || "") : "";
    }

    function resolveAppIcon(entry) {
        if (!entry) return "";
        let iconName = entry.icon || "";

        // 1. Absolute path
        if (iconName.startsWith("/") || iconName.startsWith("file://")) {
            return iconName;
        }

        // 2. Direct Quickshell icon resolution
        if (iconName.length > 0) {
            let p = Quickshell.iconPath(iconName, true);
            if (p && p.length > 0 && !p.includes("image-missing")) return p;
        }

        // 3. Try AppSearch guess lookup (handles desktop class names, substitutions, etc.)
        if (entry.id) {
            let guessed = AppSearch.guessIcon(entry.id);
            if (guessed && guessed.length > 0) {
                let p = Quickshell.iconPath(guessed, true);
                if (p && p.length > 0 && !p.includes("image-missing")) return p;
            }

            // Try reverse domain name (e.g. org.kde.kdeconnect.app -> kdeconnect)
            let parts = entry.id.replace(/\.desktop$/, "").split('.');
            for (let i = parts.length - 1; i >= 0; i--) {
                let part = parts[i].toLowerCase();
                if (part !== "desktop" && part !== "app") {
                    let p = Quickshell.iconPath(part, true);
                    if (p && p.length > 0 && !p.includes("image-missing")) return p;
                }
            }
        }

        // 4. Try normalized name
        if (entry.name) {
            let cleanName = entry.name.toLowerCase().replace(/\s+/g, "-");
            let p = Quickshell.iconPath(cleanName, true);
            if (p && p.length > 0 && !p.includes("image-missing")) return p;
        }

        // 5. Specific common fallbacks
        if (entry.id && entry.id.toLowerCase().includes("kdeconnect")) {
            let p = Quickshell.iconPath("kdeconnect", true);
            if (p && p.length > 0) return p;
        }
        if (entry.id && entry.id.toLowerCase().includes("mpv")) {
            let p = Quickshell.iconPath("mpv", true);
            if (p && p.length > 0) return p;
        }

        // 6. Generic executable fallback
        let fallback = Quickshell.iconPath("application-x-executable", true);
        if (fallback && fallback.length > 0 && !fallback.includes("image-missing")) return fallback;

        return "";
    }

    Loader {
        id: drawerLoader
        active: GlobalStates.appGridOpen

        sourceComponent: PanelWindow {
            id: panelWindow
            readonly property HyprlandMonitor monitor: Hyprland.monitorFor(panelWindow.screen)
            property bool monitorIsFocused: (Hyprland.focusedMonitor?.id == monitor?.id)

            exclusionMode: ExclusionMode.Ignore
            WlrLayershell.namespace: "appGrid"
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand
            color: ColorUtils.transparentize(Appearance.colors.colLayer0, 0.45)

            anchors {
                top: true
                bottom: true
                left: true
                right: true
            }

            // Clicking outside the main card closes the drawer
            MouseArea {
                anchors.fill: parent
                onClicked: {
                    if (mainCard.contextApp != null) {
                        mainCard.contextApp = null;
                    } else {
                        GlobalStates.appGridOpen = false;
                    }
                }
            }

            Shortcut {
                sequence: "Escape"
                onActivated: {
                    if (mainCard.contextApp != null) {
                        mainCard.contextApp = null;
                    } else {
                        GlobalStates.appGridOpen = false;
                    }
                }
            }

            Keys.onPressed: event => {
                if (event.key === Qt.Key_Escape) {
                    if (mainCard.contextApp != null) {
                        mainCard.contextApp = null;
                    } else {
                        GlobalStates.appGridOpen = false;
                    }
                    event.accepted = true;
                    return;
                }

                // Keyboard letter navigation to jump via alphabet index when search is not focused
                if (!searchInput.activeFocus && (event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)) === 0) {
                    let char = "";
                    if (event.key >= Qt.Key_A && event.key <= Qt.Key_Z) {
                        char = String.fromCharCode(event.key);
                    } else if (event.key >= Qt.Key_0 && event.key <= Qt.Key_9) {
                        char = "#";
                    }
                    if (char.length > 0 && mainCard.jumpToLetter(char)) {
                        gridView.forceActiveFocus();
                        event.accepted = true;
                        return;
                    }
                }
            }

            Component.onCompleted: {
                GlobalFocusGrab.addDismissable(panelWindow);
            }
            Component.onDestruction: {
                GlobalFocusGrab.removeDismissable(panelWindow);
            }
            Connections {
                target: GlobalFocusGrab
                function onDismissed() {
                    GlobalStates.appGridOpen = false;
                }
            }

            // ================= MAIN CARD CONTAINER =================
            Item {
                id: mainCard
                anchors.centerIn: parent
                width: Math.min(940, parent.width - 48)
                height: Math.min(680, parent.height - 80)
                property var activeApp: null
                property var contextApp: null
                property point contextPos: Qt.point(0, 0)
                property bool sortAscending: true

                function jumpToLetter(char) {
                    if (!char || char.length === 0) return false;
                    const upper = char.toUpperCase();
                    const apps = gridArea.filteredApps;
                    if (!apps || apps.length === 0) return false;

                    const matchingIndices = [];
                    for (let i = 0; i < apps.length; i++) {
                        const app = apps[i];
                        const name = (app && app.name ? app.name.trim() : "");
                        if (!name) continue;
                        let firstChar = name[0].toUpperCase();
                        let letter = (firstChar >= 'A' && firstChar <= 'Z') ? firstChar : '#';
                        if (letter === upper) {
                            matchingIndices.push(i);
                        }
                    }

                    if (matchingIndices.length === 0) return false;

                    const currentPos = matchingIndices.indexOf(gridView.currentIndex);
                    let targetIdx;
                    let mode;
                    if (currentPos >= 0 && matchingIndices.length > 1) {
                        targetIdx = matchingIndices[(currentPos + 1) % matchingIndices.length];
                        mode = GridView.Contain;
                    } else {
                        targetIdx = matchingIndices[0];
                        mode = GridView.Beginning;
                    }

                    gridView.positionViewAtIndex(targetIdx, mode);
                    gridView.currentIndex = targetIdx;
                    mainCard.activeApp = apps[targetIdx];
                    return true;
                }

                // Smooth open animation
                Component.onCompleted: openAnim.start()

                ParallelAnimation {
                    id: openAnim
                    NumberAnimation {
                        target: mainCard
                        property: "scale"
                        from: 0.96
                        to: 1.0
                        duration: 180
                        easing.type: Easing.OutCubic
                    }
                    NumberAnimation {
                        target: mainCard
                        property: "opacity"
                        from: 0.0
                        to: 1.0
                        duration: 160
                        easing.type: Easing.OutQuad
                    }
                }

                // Absorb clicks on the card so it doesn't dismiss drawer
                MouseArea {
                    anchors.fill: parent
                    onClicked: {
                        if (mainCard.contextApp != null) {
                            mainCard.contextApp = null;
                        }
                    }
                }

                StyledRectangularShadow {
                    target: cardBackground
                }

                Rectangle {
                    id: cardBackground
                    anchors.fill: parent
                    radius: Appearance.rounding.large
                    color: ColorUtils.transparentize(Appearance.colors.colBackgroundSurfaceContainer, 0.08)
                    border.width: 1
                    border.color: Appearance.colors.colLayer0Border
                    clip: true

                    ColumnLayout {
                        anchors.fill: parent
                        anchors.margins: 24
                        spacing: 16

                        // ================= HEADER =================
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 10

                            // Search Field
                            Rectangle {
                                id: searchContainer
                                Layout.fillWidth: true
                                implicitHeight: 40
                                radius: Appearance.rounding.full
                                color: ColorUtils.transparentize(Appearance.colors.colLayer1, 0.08)
                                border.width: 1
                                border.color: searchInput.activeFocus ? Appearance.colors.colPrimary : Appearance.m3colors.m3outlineVariant

                                RowLayout {
                                    anchors.fill: parent
                                    anchors.leftMargin: 14
                                    anchors.rightMargin: 10
                                    spacing: 8

                                    MaterialSymbol {
                                        text: "search"
                                        iconSize: Appearance.font.pixelSize.normal
                                        color: searchInput.activeFocus ? Appearance.colors.colPrimary : Appearance.colors.colOutline
                                    }

                                    TextInput {
                                        id: searchInput
                                        Layout.fillWidth: true
                                        font.family: Appearance.font.family.main
                                        font.pixelSize: Appearance.font.pixelSize.small
                                        color: Appearance.colors.colOnLayer0
                                        selectionColor: Appearance.colors.colSecondaryContainer
                                        selectedTextColor: Appearance.colors.colOnSecondaryContainer
                                        clip: true
                                        verticalAlignment: TextInput.AlignVCenter

                                        Keys.onPressed: event => {
                                            if (event.key === Qt.Key_Escape) {
                                                if (mainCard.contextApp != null) {
                                                    mainCard.contextApp = null;
                                                } else {
                                                    GlobalStates.appGridOpen = false;
                                                }
                                                event.accepted = true;
                                            } else if (event.key === Qt.Key_Down) {
                                                if (gridArea.filteredApps.length > 0) {
                                                    gridView.forceActiveFocus();
                                                    if (gridView.currentIndex < 0 || gridView.currentIndex >= gridArea.filteredApps.length) {
                                                        gridView.currentIndex = 0;
                                                    }
                                                    event.accepted = true;
                                                }
                                            }
                                        }

                                        onTextChanged: {
                                            mainCard.activeApp = null;
                                            mainCard.contextApp = null;
                                        }

                                        onAccepted: {
                                            if (gridArea.filteredApps.length > 0) {
                                                root.launchApp(gridArea.filteredApps[0]);
                                            }
                                        }

                                        Text {
                                            text: Translation.tr("Search applications, keywords...")
                                            visible: !searchInput.text && !searchInput.activeFocus
                                            color: Appearance.colors.colOutline
                                            font: searchInput.font
                                            anchors.fill: parent
                                            verticalAlignment: Text.AlignVCenter
                                        }

                                        Component.onCompleted: {
                                            searchInput.forceActiveFocus();
                                        }
                                    }

                                    RippleButton {
                                        visible: searchInput.text.length > 0
                                        implicitWidth: 24
                                        implicitHeight: 24
                                        buttonRadius: Appearance.rounding.full
                                        onClicked: {
                                            searchInput.text = "";
                                            searchInput.forceActiveFocus();
                                        }

                                        MaterialSymbol {
                                            anchors.centerIn: parent
                                            text: "close"
                                            iconSize: Appearance.font.pixelSize.small
                                            color: Appearance.colors.colOutline
                                        }
                                    }
                                }
                            }

                            // Pamac Button
                            RippleButton {
                                id: pamacBtn
                                implicitHeight: 40
                                implicitWidth: 40
                                buttonRadius: Appearance.rounding.full
                                colBackground: Appearance.colors.colLayer1
                                colBackgroundHover: Appearance.colors.colLayer1Hover
                                colRipple: Appearance.colors.colLayer1Active

                                onClicked: {
                                    GlobalStates.appGridOpen = false;
                                    Quickshell.execDetached(["bash", "-c", "pamac-manager"]);
                                }

                                Rectangle {
                                    anchors.fill: parent
                                    radius: pamacBtn.buttonRadius
                                    color: "transparent"
                                    border.width: 1
                                    border.color: pamacBtn.hovered ? Appearance.colors.colPrimary : Appearance.m3colors.m3outlineVariant
                                    opacity: pamacBtn.hovered ? 1.0 : 0.6
                                    z: 10

                                    Behavior on opacity {
                                        NumberAnimation { duration: 120; easing.type: Easing.OutQuad }
                                    }
                                }

                                MaterialSymbol {
                                    anchors.centerIn: parent
                                    text: "inventory_2"
                                    iconSize: Appearance.font.pixelSize.larger
                                    color: pamacBtn.hovered ? Appearance.colors.colPrimary : Appearance.colors.colOnLayer0
                                }
                            }

                            // Close Button
                            RippleButton {
                                id: closeBtn
                                implicitHeight: 40
                                implicitWidth: 40
                                buttonRadius: Appearance.rounding.full
                                colBackground: Appearance.colors.colLayer1
                                colBackgroundHover: Appearance.colors.colLayer1Hover
                                colRipple: Appearance.colors.colLayer1Active

                                onClicked: GlobalStates.appGridOpen = false

                                Rectangle {
                                    anchors.fill: parent
                                    radius: closeBtn.buttonRadius
                                    color: "transparent"
                                    border.width: 1
                                    border.color: closeBtn.hovered ? Appearance.colors.colPrimary : Appearance.m3colors.m3outlineVariant
                                    opacity: closeBtn.hovered ? 1.0 : 0.6
                                    z: 10

                                    Behavior on opacity {
                                        NumberAnimation { duration: 120; easing.type: Easing.OutQuad }
                                    }
                                }

                                MaterialSymbol {
                                    anchors.centerIn: parent
                                    text: "close"
                                    iconSize: Appearance.font.pixelSize.larger
                                    color: closeBtn.hovered ? Appearance.colors.colPrimary : Appearance.colors.colOnLayer0
                                }
                            }
                        }

                        // ================= CATEGORIES ROW =================
                        RowLayout {
                            id: categoriesRow
                            Layout.alignment: Qt.AlignHCenter
                            spacing: 8

                            readonly property var categoryList: [
                                { name: Translation.tr("All"), icon: "apps", keys: [] },
                                { name: Translation.tr("Favorites"), icon: "push_pin", keys: [], isPinned: true },
                                { name: Translation.tr("Productivity"), icon: "work", keys: ["Office", "Development", "Education", "TextEditor"] },
                                { name: Translation.tr("Internet"), icon: "language", keys: ["Network", "WebBrowser", "Email", "Chat", "Feed"] },
                                { name: Translation.tr("Media"), icon: "palette", keys: ["AudioVideo", "Audio", "Video", "Graphics", "Music", "Player"] },
                                { name: Translation.tr("Utilities"), icon: "build", keys: ["Utility", "System", "Settings", "FileManager", "TerminalEmulator", "Archiving"] },
                                { name: Translation.tr("Games"), icon: "sports_esports", keys: ["Game"] }
                            ]
                            property int activeCategoryIndex: 0

                            Repeater {
                                model: categoriesRow.categoryList
                                delegate: RippleButton {
                                    id: catPill
                                    required property var modelData
                                    required property int index

                                    readonly property bool isSelected: categoriesRow.activeCategoryIndex === index

                                    implicitHeight: 32
                                    implicitWidth: pillLayout.implicitWidth + 24
                                    buttonRadius: Appearance.rounding.full

                                    colBackground: isSelected ? Appearance.colors.colPrimary : ColorUtils.transparentize(Appearance.colors.colLayer1, 0.08)
                                    colBackgroundHover: isSelected ? Appearance.colors.colPrimaryHover : Appearance.colors.colLayer1Hover
                                    colRipple: isSelected ? Appearance.colors.colPrimaryActive : Appearance.colors.colLayer1Active

                                    Rectangle {
                                        anchors.fill: parent
                                        radius: catPill.buttonRadius
                                        color: "transparent"
                                        border.width: 1
                                        border.color: catPill.hovered ? Appearance.colors.colPrimary : Appearance.m3colors.m3outlineVariant
                                        opacity: catPill.isSelected ? 0 : (catPill.hovered ? 1.0 : 0.6)
                                        z: 10

                                        Behavior on opacity {
                                            NumberAnimation { duration: 120; easing.type: Easing.OutQuad }
                                        }
                                    }

                                    contentItem: RowLayout {
                                        id: pillLayout
                                        anchors.centerIn: parent
                                        spacing: 6

                                        MaterialSymbol {
                                            text: catPill.modelData.icon
                                            iconSize: Appearance.font.pixelSize.normal
                                            color: catPill.isSelected ? Appearance.colors.colOnPrimary : (catPill.hovered ? Appearance.colors.colPrimary : Appearance.colors.colOutline)
                                        }

                                        StyledText {
                                            text: catPill.modelData.name
                                            font.pixelSize: Appearance.font.pixelSize.small
                                            font.weight: catPill.isSelected ? Font.DemiBold : Font.Normal
                                            color: catPill.isSelected ? Appearance.colors.colOnPrimary : (catPill.hovered ? Appearance.m3colors.m3onSurface : Appearance.colors.colOnLayer0)
                                        }
                                    }

                                    onClicked: {
                                        categoriesRow.activeCategoryIndex = index;
                                        searchInput.text = "";
                                        searchInput.forceActiveFocus();
                                    }
                                }
                            }

                            // Subtle divider before merged sort button
                            Rectangle {
                                implicitWidth: 1
                                implicitHeight: 18
                                color: Appearance.colors.colLayer0Border
                                Layout.alignment: Qt.AlignVCenter
                                Layout.leftMargin: 2
                                Layout.rightMargin: 2
                                opacity: 0.6
                            }

                            // Merged Sort Order Toggle Button
                            RippleButton {
                                id: sortBtn
                                implicitHeight: 32
                                implicitWidth: 32
                                buttonRadius: Appearance.rounding.full
                                colBackground: ColorUtils.transparentize(Appearance.colors.colLayer1, 0.08)
                                colBackgroundHover: Appearance.colors.colLayer1Hover
                                colRipple: Appearance.colors.colLayer1Active

                                onClicked: mainCard.sortAscending = !mainCard.sortAscending

                                StyledToolTip {
                                    text: mainCard.sortAscending ? Translation.tr("Sort: A to Z") : Translation.tr("Sort: Z to A")
                                }

                                Rectangle {
                                    anchors.fill: parent
                                    radius: sortBtn.buttonRadius
                                    color: "transparent"
                                    border.width: 1
                                    border.color: sortBtn.hovered ? Appearance.colors.colPrimary : Appearance.m3colors.m3outlineVariant
                                    opacity: sortBtn.hovered ? 1.0 : 0.6
                                    z: 10

                                    Behavior on opacity {
                                        NumberAnimation { duration: 120; easing.type: Easing.OutQuad }
                                    }
                                }

                                MaterialSymbol {
                                    anchors.centerIn: parent
                                    text: mainCard.sortAscending ? "arrow_downward" : "arrow_upward"
                                    iconSize: Appearance.font.pixelSize.small
                                    color: sortBtn.hovered ? Appearance.colors.colPrimary : Appearance.colors.colOnLayer0
                                }
                            }
                        }

                        // ================= APP GRID =================
                        Item {
                            id: gridArea
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            clip: true

                            // Deduplicated, sorted application catalog
                            readonly property var allApps: {
                                const list = Array.from(DesktopEntries.applications.values).filter(app => !app.noDisplay && app.name && app.name.trim().length > 0);
                                const deduped = list.filter((app, index, self) => 
                                    index === self.findIndex(t => t.id === app.id)
                                );
                                return deduped.sort((a, b) => {
                                    const cmp = a.name.localeCompare(b.name);
                                    return mainCard.sortAscending ? cmp : -cmp;
                                });
                            }

                            readonly property var filteredApps: {
                                const q = searchInput.text.trim().toLowerCase();
                                const activeCat = categoriesRow.categoryList[categoriesRow.activeCategoryIndex];

                                return allApps.filter(app => {
                                    // Pinned Favorites filter
                                    if (activeCat && activeCat.isPinned) {
                                        if (!LauncherApps.isPinned(app.id)) return false;
                                    } else if (activeCat && activeCat.keys && activeCat.keys.length > 0) {
                                        const appCats = app.categories || [];
                                        const hasCat = appCats.some(c => activeCat.keys.includes(c));
                                        if (!hasCat) return false;
                                    }

                                    // Comprehensive search filter
                                    if (q.length > 0) {
                                        const nameMatch = app.name && app.name.toLowerCase().includes(q);
                                        const commentMatch = app.comment && app.comment.toLowerCase().includes(q);
                                        const genericMatch = app.genericName && app.genericName.toLowerCase().includes(q);
                                        const idMatch = app.id && app.id.toLowerCase().includes(q);
                                        const keywordsMatch = app.keywords && app.keywords.some(k => k.toLowerCase().includes(q));
                                        return nameMatch || commentMatch || genericMatch || idMatch || keywordsMatch;
                                    }
                                    return true;
                                });
                            }

                            // Dynamic available unique letters for quick alphabet navigation
                            readonly property var availableLetters: {
                                const apps = gridArea.filteredApps;
                                if (!apps || apps.length === 0) return [];
                                const letterMap = new Map();
                                for (let i = 0; i < apps.length; i++) {
                                    const app = apps[i];
                                    const name = (app && app.name ? app.name.trim() : "");
                                    if (!name) continue;
                                    let firstChar = name[0].toUpperCase();
                                    let letter = (firstChar >= 'A' && firstChar <= 'Z') ? firstChar : '#';
                                    if (!letterMap.has(letter)) {
                                        letterMap.set(letter, i);
                                    }
                                }
                                const letters = Array.from(letterMap.keys());
                                letters.sort((a, b) => {
                                    if (a === '#') return 1;
                                    if (b === '#') return -1;
                                    return a.localeCompare(b);
                                });
                                if (!mainCard.sortAscending) {
                                    letters.reverse();
                                }
                                return letters.map(ch => ({
                                    letter: ch,
                                    index: letterMap.get(ch)
                                }));
                            }

                            GridView {
                                id: gridView
                                anchors.left: parent.left
                                anchors.top: parent.top
                                anchors.bottom: parent.bottom
                                anchors.right: alphabetBar.visible ? alphabetBar.left : parent.right
                                anchors.rightMargin: alphabetBar.visible ? 4 : 0
                                anchors.topMargin: 4
                                anchors.bottomMargin: 4
                                cellWidth: Math.floor(width / Math.max(1, Math.floor(width / 115)))
                                cellHeight: 110
                                model: gridArea.filteredApps
                                boundsBehavior: Flickable.StopAtBounds
                                clip: true
                                focus: true
                                keyNavigationEnabled: true

                                ScrollBar.vertical: StyledScrollBar {}

                                onCurrentIndexChanged: {
                                    if (gridView.activeFocus && gridView.currentIndex >= 0 && gridView.currentIndex < gridArea.filteredApps.length) {
                                        mainCard.activeApp = gridArea.filteredApps[gridView.currentIndex];
                                    }
                                }
                                onActiveFocusChanged: {
                                    if (gridView.activeFocus && gridView.currentIndex >= 0 && gridView.currentIndex < gridArea.filteredApps.length) {
                                        mainCard.activeApp = gridArea.filteredApps[gridView.currentIndex];
                                    }
                                }

                                Keys.onPressed: event => {
                                    if (mainCard.contextApp != null) {
                                        if (event.key === Qt.Key_Down) {
                                            if (contextMenuContainer.contextActions.length > 0) {
                                                contextMenuContainer.selectedActionIndex = (contextMenuContainer.selectedActionIndex + 1) % contextMenuContainer.contextActions.length;
                                            }
                                            event.accepted = true;
                                            return;
                                        } else if (event.key === Qt.Key_Up) {
                                            if (contextMenuContainer.contextActions.length > 0) {
                                                contextMenuContainer.selectedActionIndex = (contextMenuContainer.selectedActionIndex - 1 + contextMenuContainer.contextActions.length) % contextMenuContainer.contextActions.length;
                                            }
                                            event.accepted = true;
                                            return;
                                        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                                            if (contextMenuContainer.contextActions.length > contextMenuContainer.selectedActionIndex) {
                                                contextMenuContainer.contextActions[contextMenuContainer.selectedActionIndex].trigger();
                                            }
                                            event.accepted = true;
                                            return;
                                        } else if (event.key === Qt.Key_Escape || event.key === Qt.Key_Left || event.key === Qt.Key_Right) {
                                            mainCard.contextApp = null;
                                            event.accepted = true;
                                            return;
                                        }
                                    }

                                    // Keyboard letter navigation to jump via alphabet index
                                    if (!searchInput.activeFocus && (event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)) === 0) {
                                        let char = "";
                                        if (event.key >= Qt.Key_A && event.key <= Qt.Key_Z) {
                                            char = String.fromCharCode(event.key);
                                        } else if (event.key >= Qt.Key_0 && event.key <= Qt.Key_9) {
                                            char = "#";
                                        }
                                        if (char.length > 0 && mainCard.jumpToLetter(char)) {
                                            event.accepted = true;
                                            return;
                                        }
                                    }

                                    if (event.key === Qt.Key_Slash) {
                                        searchInput.forceActiveFocus();
                                        event.accepted = true;
                                        return;
                                    }

                                    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                                        if (gridArea.filteredApps.length > gridView.currentIndex && gridView.currentIndex >= 0) {
                                            root.launchApp(gridArea.filteredApps[gridView.currentIndex]);
                                            event.accepted = true;
                                        }
                                    } else if (event.key === Qt.Key_Menu || (event.key === Qt.Key_F10 && (event.modifiers & Qt.ShiftModifier))) {
                                        if (gridArea.filteredApps.length > gridView.currentIndex && gridView.currentIndex >= 0) {
                                            const app = gridArea.filteredApps[gridView.currentIndex];
                                            mainCard.activeApp = app;
                                            mainCard.contextApp = app;
                                            contextMenuContainer.selectedActionIndex = 0;
                                            const cols = Math.max(1, Math.floor(gridView.width / gridView.cellWidth));
                                            const col = gridView.currentIndex % cols;
                                            const row = Math.floor(gridView.currentIndex / cols);
                                            const targetX = col * gridView.cellWidth + gridView.cellWidth / 2;
                                            const targetY = row * gridView.cellHeight + gridView.cellHeight / 2 - gridView.contentY;
                                            mainCard.contextPos = Qt.point(
                                                Math.min(targetX, mainCard.width - 260),
                                                Math.min(Math.max(16, targetY), mainCard.height - 250)
                                            );
                                            event.accepted = true;
                                        }
                                    } else if (event.key === Qt.Key_Up) {
                                        const cols = Math.floor(gridArea.width / gridView.cellWidth);
                                        if (gridView.currentIndex < cols) {
                                            searchInput.forceActiveFocus();
                                            event.accepted = true;
                                        }
                                    }
                                }

                                delegate: Item {
                                    id: appItem
                                    required property var modelData
                                    required property int index
                                    width: gridView.cellWidth
                                    height: gridView.cellHeight

                                    readonly property bool isPinned: LauncherApps.isPinned(appItem.modelData.id)
                                    readonly property bool isContextTarget: mainCard.contextApp === appItem.modelData
                                    readonly property bool isSelected: isContextTarget || (mainCard.activeApp === appItem.modelData) || (gridView.currentIndex === appItem.index && gridView.activeFocus)

                                    // Staggered cascade entrance animation container
                                    Item {
                                        id: appItemContent
                                        anchors.fill: parent
                                        y: (appItem.index < 24) ? 14 : 0
                                        opacity: (appItem.index < 24) ? 0.0 : 1.0

                                        SequentialAnimation {
                                            id: entranceAnim
                                            PauseAnimation {
                                                duration: Math.min(appItem.index, 24) * 14
                                            }
                                            ParallelAnimation {
                                                NumberAnimation {
                                                    target: appItemContent
                                                    property: "y"
                                                    to: 0
                                                    duration: 200
                                                    easing.type: Easing.OutCubic
                                                }
                                                NumberAnimation {
                                                    target: appItemContent
                                                    property: "opacity"
                                                    to: 1.0
                                                    duration: 200
                                                    easing.type: Easing.OutCubic
                                                }
                                            }
                                        }

                                        Component.onCompleted: {
                                            if (appItem.index < 24) {
                                                entranceAnim.start();
                                            }
                                        }

                                        HoverHandler {
                                            onPointChanged: {
                                                if (hovered && mainCard.contextApp == null && gridView.currentIndex !== appItem.index) {
                                                    gridView.currentIndex = appItem.index;
                                                    mainCard.activeApp = appItem.modelData;
                                                }
                                            }
                                        }

                                        RippleButton {
                                            id: itemBtn
                                            anchors.fill: parent
                                            anchors.margins: 4
                                            buttonRadius: Appearance.rounding.normal
                                            colBackground: appItem.isSelected ? Appearance.colors.colSecondaryContainer : "transparent"
                                            colBackgroundHover: appItem.isSelected ? Appearance.colors.colSecondaryContainer : "transparent"
                                            colRipple: Appearance.colors.colPrimaryContainerActive

                                            scale: itemBtn.down ? 0.94 : (appItem.isSelected ? 1.04 : 1.0)
                                            Behavior on scale {
                                                NumberAnimation { duration: 120; easing.type: Easing.OutQuad }
                                            }

                                            onHoveredChanged: {
                                                if (hovered && mainCard.contextApp == null) {
                                                    gridView.currentIndex = appItem.index;
                                                    mainCard.activeApp = appItem.modelData;
                                                } else if (mainCard.activeApp === appItem.modelData && !appItem.isContextTarget && !gridView.activeFocus) {
                                                    mainCard.activeApp = null;
                                                }
                                            }

                                            onClicked: {
                                                if (mainCard.contextApp != null) {
                                                    mainCard.contextApp = null;
                                                    return;
                                                }
                                                root.launchApp(appItem.modelData);
                                            }

                                            altAction: event => {
                                                gridView.forceActiveFocus();
                                                gridView.currentIndex = appItem.index;
                                                mainCard.activeApp = appItem.modelData;
                                                mainCard.contextApp = appItem.modelData;
                                                contextMenuContainer.selectedActionIndex = 0;
                                                let mouseX = (event && event.x !== undefined) ? event.x : itemBtn.width / 2;
                                                let mouseY = (event && event.y !== undefined) ? event.y : itemBtn.height / 2;
                                                let pt = mainCard.mapFromItem(itemBtn, mouseX, mouseY);
                                                mainCard.contextPos = Qt.point(
                                                    Math.min(pt.x, mainCard.width - 260),
                                                    Math.min(pt.y, mainCard.height - 250)
                                                );
                                            }

                                            // Selection outline indicator (Unified 2px primary border for both hover and keyboard)
                                            Rectangle {
                                                anchors.fill: parent
                                                radius: itemBtn.buttonRadius
                                                color: "transparent"
                                                border.width: 2
                                                border.color: Appearance.colors.colPrimary
                                                opacity: appItem.isSelected ? 1.0 : 0.0
                                                visible: opacity > 0
                                                z: 10

                                                Behavior on opacity {
                                                    NumberAnimation {
                                                        duration: 120
                                                        easing.type: Easing.OutQuad
                                                    }
                                                }
                                            }

                                            // Terminal Application Indicator Badge
                                            Rectangle {
                                                anchors.top: parent.top
                                                anchors.left: parent.left
                                                anchors.margins: 6
                                                width: 18
                                                height: 18
                                                radius: 4
                                                color: Appearance.colors.colLayer1
                                                border.width: 1
                                                border.color: Appearance.m3colors.m3outlineVariant
                                                visible: !!appItem.modelData?.runInTerminal
                                                z: 11

                                                MaterialSymbol {
                                                    anchors.centerIn: parent
                                                    text: "terminal"
                                                    iconSize: 11
                                                    color: Appearance.colors.colPrimary
                                                }
                                            }

                                            // Pinned Favorite Indicator Badge
                                            MaterialSymbol {
                                                anchors.top: parent.top
                                                anchors.right: parent.right
                                                anchors.margins: 6
                                                visible: appItem.isPinned
                                                text: "push_pin"
                                                iconSize: 12
                                                color: Appearance.colors.colPrimary
                                            }

                                            ColumnLayout {
                                                anchors.centerIn: parent
                                                anchors.fill: parent
                                                anchors.margins: 6
                                                spacing: 6

                                                Item {
                                                    id: iconContainer
                                                    implicitWidth: 44
                                                    implicitHeight: 44
                                                    Layout.alignment: Qt.AlignHCenter
                                                    scale: appItem.isSelected ? 1.08 : 1.0

                                                    Behavior on scale {
                                                        NumberAnimation {
                                                            duration: 150
                                                            easing.type: Easing.OutQuad
                                                        }
                                                    }

                                                    readonly property string resolvedIcon: root.resolveAppIcon(appItem.modelData)
                                                    readonly property bool hasValidIcon: resolvedIcon.length > 0 && appIconImg.status !== Image.Error

                                                    IconImage {
                                                        id: appIconImg
                                                        anchors.fill: parent
                                                        source: iconContainer.resolvedIcon
                                                        visible: iconContainer.hasValidIcon
                                                        asynchronous: true
                                                    }

                                                    // Clean fallback badge if no system icon exists
                                                    Rectangle {
                                                        anchors.fill: parent
                                                        radius: Appearance.rounding.normal
                                                        color: Appearance.colors.colSecondaryContainer
                                                        visible: !iconContainer.hasValidIcon

                                                        MaterialSymbol {
                                                            anchors.centerIn: parent
                                                            text: {
                                                                const cats = appItem.modelData.categories || [];
                                                                if (cats.includes("Game")) return "sports_esports";
                                                                if (cats.includes("Development")) return "terminal";
                                                                if (cats.includes("AudioVideo") || cats.includes("Audio")) return "movie";
                                                                if (cats.includes("Graphics")) return "palette";
                                                                if (cats.includes("Network")) return "language";
                                                                return "deployed_code";
                                                            }
                                                            iconSize: 24
                                                            color: Appearance.colors.colOnSecondaryContainer
                                                        }
                                                    }
                                                }

                                                StyledText {
                                                    Layout.fillWidth: true
                                                    text: appItem.modelData.name
                                                    font.pixelSize: Appearance.font.pixelSize.smaller
                                                    font.weight: appItem.isSelected ? Font.Bold : Font.Medium
                                                    color: appItem.isSelected ? Appearance.colors.colOnSecondaryContainer : Appearance.colors.colOnLayer0
                                                    horizontalAlignment: Text.AlignHCenter
                                                    elide: Text.ElideRight
                                                    maximumLineCount: 2
                                                    wrapMode: Text.Wrap
                                                }
                                            }
                                        }
                                    }
                                }
                            }

                            // Empty State Placeholder with Reset Button
                            Item {
                                anchors.centerIn: parent
                                visible: gridArea.filteredApps.length === 0
                                width: 260
                                height: 160

                                ColumnLayout {
                                    anchors.centerIn: parent
                                    spacing: 12

                                    MaterialSymbol {
                                        Layout.alignment: Qt.AlignHCenter
                                        text: "search_off"
                                        iconSize: 42
                                        color: Appearance.colors.colOutline
                                    }

                                    StyledText {
                                        Layout.alignment: Qt.AlignHCenter
                                        text: Translation.tr("No applications found")
                                        font.pixelSize: Appearance.font.pixelSize.normal
                                        font.weight: Font.DemiBold
                                        color: Appearance.colors.colOnLayer0
                                    }

                                    RippleButton {
                                        Layout.alignment: Qt.AlignHCenter
                                        implicitHeight: 32
                                        implicitWidth: 120
                                        buttonRadius: Appearance.rounding.full
                                        colBackground: Appearance.colors.colSecondaryContainer
                                        colBackgroundHover: Appearance.colors.colSecondaryContainerHover
                                        colRipple: Appearance.colors.colSecondaryContainerActive

                                        RowLayout {
                                            anchors.centerIn: parent
                                            spacing: 6
                                            MaterialSymbol {
                                                text: "refresh"
                                                iconSize: Appearance.font.pixelSize.small
                                                color: Appearance.colors.colOnSecondaryContainer
                                            }
                                            StyledText {
                                                text: Translation.tr("Reset filters")
                                                font.pixelSize: Appearance.font.pixelSize.smaller
                                                color: Appearance.colors.colOnSecondaryContainer
                                            }
                                        }

                                        onClicked: {
                                            searchInput.text = "";
                                            categoriesRow.activeCategoryIndex = 0;
                                            searchInput.forceActiveFocus();
                                        }
                                    }
                                }
                            }

                            // ================= QUICK ALPHABET SCROLLER =================
                            Item {
                                id: alphabetBar
                                anchors.right: parent.right
                                anchors.top: parent.top
                                anchors.bottom: parent.bottom
                                anchors.topMargin: 8
                                anchors.bottomMargin: 8
                                width: 18
                                visible: gridArea.availableLetters.length > 1
                                z: 20

                                property int hoveredLetterIndex: -1

                                Column {
                                    id: letterColumn
                                    anchors.centerIn: parent
                                    spacing: 0

                                    Repeater {
                                        model: gridArea.availableLetters

                                        delegate: Item {
                                            id: letterItem
                                            required property var modelData
                                            required property int index
                                            width: 18
                                            height: Math.min(20, Math.max(13, Math.floor((alphabetBar.height - 8) / Math.max(1, gridArea.availableLetters.length))))

                                            readonly property bool isHovered: alphabetBar.hoveredLetterIndex === letterItem.index
                                            readonly property bool isActiveLetter: {
                                                if (!mainCard.activeApp) return false;
                                                const firstChar = (mainCard.activeApp.name || "").trim().charAt(0).toUpperCase();
                                                const appLetter = (firstChar >= 'A' && firstChar <= 'Z') ? firstChar : '#';
                                                return appLetter === letterItem.modelData.letter;
                                            }

                                            StyledText {
                                                anchors.centerIn: parent
                                                anchors.horizontalCenterOffset: letterItem.isHovered ? -8 : 0
                                                text: letterItem.modelData.letter
                                                font.pixelSize: letterItem.isHovered ? 12 : (letterItem.isActiveLetter ? 9.5 : 8)
                                                font.weight: letterItem.isHovered ? Font.Bold : (letterItem.isActiveLetter ? Font.DemiBold : Font.Normal)
                                                color: (letterItem.isHovered || letterItem.isActiveLetter)
                                                    ? Appearance.colors.colPrimary
                                                    : Appearance.colors.colOutline
                                                opacity: letterItem.isHovered ? 1.0 : (letterItem.isActiveLetter ? 0.9 : 0.4)

                                                Behavior on anchors.horizontalCenterOffset {
                                                    NumberAnimation { duration: 80; easing.type: Easing.OutQuad }
                                                }
                                                Behavior on color { ColorAnimation { duration: 80 } }
                                                Behavior on opacity { NumberAnimation { duration: 60 } }
                                            }
                                        }
                                    }
                                }

                                MouseArea {
                                    id: scrollerMouseArea
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    preventStealing: true
                                    cursorShape: Qt.PointingHandCursor

                                    function getIndexAt(mouseY) {
                                        const len = gridArea.availableLetters.length;
                                        if (len === 0 || letterColumn.height <= 0) return -1;
                                        const relY = mouseY - letterColumn.y;
                                        const itemH = letterColumn.height / len;
                                        if (itemH <= 0) return -1;
                                        const idx = Math.floor(relY / itemH);
                                        return Math.max(0, Math.min(len - 1, idx));
                                    }

                                    function jumpToIndex(letterIdx) {
                                        if (letterIdx < 0 || letterIdx >= gridArea.availableLetters.length) return;
                                        const entry = gridArea.availableLetters[letterIdx];
                                        if (entry && entry.index !== undefined) {
                                            gridView.positionViewAtIndex(entry.index, GridView.Beginning);
                                            gridView.currentIndex = entry.index;
                                            mainCard.activeApp = gridArea.filteredApps[entry.index];
                                        }
                                    }

                                    onPositionChanged: mouse => {
                                        const idx = getIndexAt(mouse.y);
                                        if (idx >= 0 && idx !== alphabetBar.hoveredLetterIndex) {
                                            alphabetBar.hoveredLetterIndex = idx;
                                            jumpToIndex(idx);
                                        }
                                    }

                                    onEntered: {
                                        const idx = getIndexAt(scrollerMouseArea.mouseY);
                                        if (idx >= 0) {
                                            alphabetBar.hoveredLetterIndex = idx;
                                            jumpToIndex(idx);
                                        }
                                    }

                                    onPressed: mouse => {
                                        const idx = getIndexAt(mouse.y);
                                        if (idx >= 0) {
                                            alphabetBar.hoveredLetterIndex = idx;
                                            jumpToIndex(idx);
                                        }
                                    }

                                    onExited: {
                                        alphabetBar.hoveredLetterIndex = -1;
                                    }
                                }
                            }
                        }

                        // ================= DESCRIPTION STATUS BAR =================
                        Rectangle {
                            id: descriptionBar
                            Layout.fillWidth: true
                            implicitHeight: 52
                            radius: Appearance.rounding.small
                            readonly property var displayedApp: mainCard.contextApp ?? mainCard.activeApp
                            readonly property string appSource: root.getAppSource(descriptionBar.displayedApp)
                            readonly property var appCategories: {
                                if (!displayedApp || !displayedApp.categories) return [];
                                const ignored = ["Application", "Qt", "GTK", "X-"];
                                const cats = [];
                                for (const c of displayedApp.categories) {
                                    if (!ignored.some(ig => c.startsWith(ig)) && cats.length < 2) {
                                        cats.push(c);
                                    }
                                }
                                return cats;
                            }
                            color: descriptionBar.displayedApp ? ColorUtils.transparentize(Appearance.colors.colLayer1, 0.08) : "transparent"
                            clip: true

                            Behavior on color {
                                animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
                            }

                            // Active App: Two-row spacious layout
                            ColumnLayout {
                                anchors.fill: parent
                                anchors.leftMargin: 14
                                anchors.rightMargin: 14
                                anchors.topMargin: 6
                                anchors.bottomMargin: 6
                                spacing: 4
                                visible: descriptionBar.displayedApp != null

                                // Row 1: App Identity, Tag Chips, and Options Hint
                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 8

                                    MaterialSymbol {
                                        text: mainCard.contextApp != null ? "list_alt" : "info"
                                        iconSize: 16
                                        color: Appearance.colors.colPrimary
                                    }

                                    StyledText {
                                        text: descriptionBar.displayedApp?.name ?? ""
                                        font.pixelSize: Appearance.font.pixelSize.smallie
                                        font.weight: Font.DemiBold
                                        color: Appearance.colors.colOnLayer0
                                        elide: Text.ElideRight
                                        Layout.maximumWidth: 300
                                    }

                                    // App Tag Pills
                                    RowLayout {
                                        spacing: 5

                                        // Source Tag (Pacman / AUR / Terminal / Local / Flatpak / AppImage)
                                        Rectangle {
                                            implicitHeight: 18
                                            implicitWidth: sourceRow.implicitWidth + 12
                                            radius: Appearance.rounding.full
                                            color: Appearance.colors.colLayer2
                                            border.width: 1
                                            border.color: Appearance.m3colors.m3outlineVariant

                                            RowLayout {
                                                id: sourceRow
                                                anchors.centerIn: parent
                                                spacing: 4

                                                MaterialSymbol {
                                                    visible: descriptionBar.appSource === "kitty" || descriptionBar.appSource === "Local"
                                                    text: descriptionBar.appSource === "kitty" ? "terminal" : "folder"
                                                    iconSize: 11
                                                    color: descriptionBar.appSource === "kitty" ? Appearance.colors.colPrimary : Appearance.colors.colOutline
                                                }

                                                StyledText {
                                                    id: sourceLabel
                                                    text: descriptionBar.appSource
                                                    font.pixelSize: Appearance.font.pixelSize.smaller
                                                    font.weight: Font.DemiBold
                                                    color: {
                                                        switch (descriptionBar.appSource) {
                                                            case "Pacman": return Appearance.colors.colPrimary;
                                                            case "AUR": return Appearance.colors.colPrimary;
                                                            case "Flatpak": return Appearance.colors.colSecondary;
                                                            case "AppImage": return Appearance.colors.colTertiary;
                                                            case "kitty": return Appearance.colors.colPrimary;
                                                            default: return Appearance.colors.colOutline;
                                                        }
                                                    }
                                                }
                                            }
                                        }

                                        // Terminal Run Tag (if app.runInTerminal)
                                        Rectangle {
                                            visible: !!descriptionBar.displayedApp?.runInTerminal
                                            implicitHeight: 18
                                            implicitWidth: termRow.implicitWidth + 8
                                            radius: Appearance.rounding.full
                                            color: Appearance.colors.colLayer2
                                            border.width: 1
                                            border.color: Appearance.m3colors.m3outlineVariant

                                            RowLayout {
                                                id: termRow
                                                anchors.centerIn: parent
                                                spacing: 3
                                                MaterialSymbol {
                                                    text: "terminal"
                                                    iconSize: 11
                                                    color: Appearance.colors.colPrimary
                                                }
                                                StyledText {
                                                    text: Translation.tr("TUI")
                                                    font.pixelSize: Appearance.font.pixelSize.smaller
                                                    font.weight: Font.DemiBold
                                                    color: Appearance.colors.colOutline
                                                }
                                            }
                                        }

                                        // Category Tags (up to 2)
                                        Repeater {
                                            model: descriptionBar.appCategories
                                            delegate: Rectangle {
                                                required property string modelData
                                                implicitHeight: 18
                                                implicitWidth: catLabel.implicitWidth + 10
                                                radius: Appearance.rounding.full
                                                color: Appearance.colors.colLayer2
                                                border.width: 1
                                                border.color: Appearance.m3colors.m3outlineVariant

                                                StyledText {
                                                    id: catLabel
                                                    anchors.centerIn: parent
                                                    text: modelData
                                                    font.pixelSize: Appearance.font.pixelSize.smaller
                                                    color: Appearance.colors.colOutline
                                                }
                                            }
                                        }
                                    }

                                    Item { Layout.fillWidth: true }

                                    // Interactive Hint Tag (Right-aligned)
                                    RowLayout {
                                        spacing: 4

                                        MaterialSymbol {
                                            text: mainCard.contextApp != null ? "menu_open" : "mouse"
                                            iconSize: 13
                                            color: Appearance.colors.colOutline
                                        }

                                        StyledText {
                                            text: mainCard.contextApp != null ? Translation.tr("Options open (↑↓ navigate, ↵ execute)") : Translation.tr("Right-click or Menu key for options")
                                            font.pixelSize: Appearance.font.pixelSize.smaller
                                            color: Appearance.colors.colOutline
                                        }
                                    }
                                }

                                // Row 2: Full width description
                                Item {
                                    Layout.fillWidth: true
                                    implicitHeight: descText.implicitHeight

                                    StyledText {
                                        id: descText
                                        anchors.left: parent.left
                                        anchors.right: parent.right
                                        anchors.leftMargin: 24
                                        text: descriptionBar.displayedApp?.comment || descriptionBar.displayedApp?.genericName || Translation.tr("No description available")
                                        font.pixelSize: Appearance.font.pixelSize.smaller
                                        color: Appearance.colors.colOutline
                                        elide: Text.ElideRight
                                        opacity: 0.85
                                    }
                                }
                            }

                            // Empty State: Single centered prompt
                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: 14
                                anchors.rightMargin: 14
                                visible: !descriptionBar.displayedApp
                                spacing: 8

                                MaterialSymbol {
                                    text: "info"
                                    iconSize: Appearance.font.pixelSize.normal
                                    color: Appearance.colors.colOutline
                                    opacity: 0.6
                                }

                                StyledText {
                                    Layout.fillWidth: true
                                    text: Translation.tr("Hover or select an application to see its description and details")
                                    font.pixelSize: Appearance.font.pixelSize.small
                                    color: Appearance.colors.colOutline
                                    opacity: 0.7
                                }
                            }
                        }

                        // ================= FOOTER =================
                        RowLayout {
                            Layout.fillWidth: true
                            Layout.topMargin: 2
                            spacing: 12

                            StyledText {
                                text: Translation.tr("%1 applications").arg(gridArea.filteredApps.length)
                                font.pixelSize: Appearance.font.pixelSize.smaller
                                color: Appearance.colors.colOutline
                            }

                            Item { Layout.fillWidth: true }

                            // Keyboard shortcuts helper badges
                            RowLayout {
                                spacing: 12

                                Repeater {
                                    model: [
                                        { key: "↑↓←→", label: Translation.tr("Navigate") },
                                        { key: "↵ Enter", label: Translation.tr("Launch") },
                                        { key: "Esc", label: Translation.tr("Back") },
                                        { key: "Super+Z", label: Translation.tr("Toggle") }
                                    ]

                                    delegate: RowLayout {
                                        required property var modelData
                                        spacing: 5

                                        Rectangle {
                                            implicitWidth: keyLabel.implicitWidth + 8
                                            implicitHeight: keyLabel.implicitHeight + 3
                                            radius: 4
                                            color: Appearance.colors.colLayer2
                                            border.width: 1
                                            border.color: Appearance.m3colors.m3outlineVariant

                                            StyledText {
                                                id: keyLabel
                                                anchors.centerIn: parent
                                                font.family: Appearance.font.family.monospace
                                                font.pixelSize: Appearance.font.pixelSize.smallest
                                                color: Appearance.colors.colOutline
                                                text: modelData.key
                                            }
                                        }

                                        StyledText {
                                            text: modelData.label
                                            font.pixelSize: Appearance.font.pixelSize.smaller
                                            color: Appearance.colors.colOutline
                                            opacity: 0.8
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // ================= CONTEXT MENU MODAL OVERLAY =================
                MouseArea {
                    anchors.fill: parent
                    visible: mainCard.contextApp != null
                    z: 98
                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                    onClicked: mainCard.contextApp = null
                }

                Item {
                    id: contextMenuContainer
                    visible: mainCard.contextApp != null
                    x: Math.min(Math.max(16, mainCard.contextPos.x), mainCard.width - width - 16)
                    y: Math.min(Math.max(16, mainCard.contextPos.y), mainCard.height - height - 16)
                    width: 250
                    height: contextCol.implicitHeight + 16
                    z: 99

                    property int selectedActionIndex: 0

                    readonly property var contextActions: {
                        if (!mainCard.contextApp) return [];
                        const app = mainCard.contextApp;
                        const actions = [
                            {
                                iconText: "play_arrow",
                                label: Translation.tr("Open Application"),
                                trigger: () => {
                                    mainCard.contextApp = null;
                                    root.launchApp(app);
                                }
                            },
                            {
                                iconText: "terminal",
                                label: Translation.tr("Run in Terminal"),
                                trigger: () => {
                                    mainCard.contextApp = null;
                                    root.launchApp(app, true);
                                }
                            },
                            {
                                iconText: "push_pin",
                                label: LauncherApps.isPinned(app.id) ? Translation.tr("Unpin from Favorites") : Translation.tr("Pin to Favorites"),
                                trigger: () => {
                                    LauncherApps.togglePin(app.id);
                                    mainCard.contextApp = null;
                                }
                            }
                        ];

                        if (app.actions && app.actions.length > 0) {
                            for (let i = 0; i < Math.min(3, app.actions.length); i++) {
                                const act = app.actions[i];
                                actions.push({
                                    iconText: "bolt",
                                    label: act.name,
                                    trigger: () => {
                                        GlobalStates.appGridOpen = false;
                                        mainCard.contextApp = null;
                                        act.execute();
                                    }
                                });
                            }
                        }

                        actions.push({
                            iconText: "inventory_2",
                            label: Translation.tr("Manage in Pamac"),
                            trigger: () => {
                                GlobalStates.appGridOpen = false;
                                mainCard.contextApp = null;
                                const rawId = app.id || "";
                                const cleanId = rawId.replace(/\.desktop$/, "");
                                const pkgName = root.getAppPackage(app);
                                const appName = (app.name || cleanId).replace(/"/g, '\\"');
                                const safePkg = pkgName.replace(/"/g, '\\"');

                                if (safePkg.length > 0) {
                                    Quickshell.execDetached([
                                        "bash", "-c",
                                        `pamac-manager --details="${safePkg}" 2>/dev/null || pamac-manager --search="${appName}" 2>/dev/null || pamac-manager`
                                    ]);
                                } else {
                                    Quickshell.execDetached([
                                        "bash", "-c",
                                        `pamac-manager --search="${appName}" 2>/dev/null || pamac-manager`
                                    ]);
                                }
                            }
                        });

                        actions.push({
                            iconText: "delete",
                            label: Translation.tr("Uninstall Application"),
                            isDestructive: true,
                            trigger: () => {
                                GlobalStates.appGridOpen = false;
                                mainCard.contextApp = null;
                                const rawId = app.id || "";
                                const cleanId = rawId.replace(/\.desktop$/, "");
                                const desktopFile = rawId.endsWith(".desktop") ? rawId : (rawId + ".desktop");
                                const pkgName = root.getAppPackage(app);
                                const appName = (app.name || cleanId).replace(/"/g, '\\"');
                                const safePkg = pkgName.replace(/"/g, '\\"');
                                const safeDesk = desktopFile.replace(/"/g, '\\"');
                                const safeClean = cleanId.replace(/"/g, '\\"');

                                Quickshell.execDetached([
                                    "bash", "-c",
                                    `${Config.options.apps.terminal} -e bash -c '` +
                                    `echo "========================================"; ` +
                                    `echo "  Uninstall Application: ${appName}"; ` +
                                    `echo "  Desktop File: ${safeDesk}"; ` +
                                    `echo "========================================"; ` +
                                    `echo ""; ` +
                                    `pkg="${safePkg}"; ` +
                                    `if [ -n "$pkg" ]; then ` +
                                    `  echo "Identified package via pacman/AUR: $pkg"; ` +
                                    `  sudo pacman -Rns "$pkg"; ` +
                                    `elif command -v flatpak >/dev/null 2>&1 && flatpak list --app --columns=application 2>/dev/null | grep -q "^${safeClean}\\$"; then ` +
                                    `  echo "Identified Flatpak application: ${safeClean}"; ` +
                                    `  flatpak uninstall "${safeClean}"; ` +
                                    `elif [ -f "$HOME/.local/share/applications/${safeDesk}" ]; then ` +
                                    `  read -p "Remove user desktop file $HOME/.local/share/applications/${safeDesk}? [y/N] " confirm; ` +
                                    `  if [[ $confirm == [yY] || $confirm == [yY][eE][sS] ]]; then ` +
                                    `    rm -v "$HOME/.local/share/applications/${safeDesk}"; ` +
                                    `  fi; ` +
                                    `elif [ -f "/usr/share/applications/${safeDesk}" ]; then ` +
                                    `  echo "Application entry found at /usr/share/applications/${safeDesk} (Manual/kitty install)"; ` +
                                    `  read -p "Remove system desktop entry /usr/share/applications/${safeDesk}? [y/N] " confirm; ` +
                                    `  if [[ $confirm == [yY] || $confirm == [yY][eE][sS] ]]; then ` +
                                    `    sudo rm -v "/usr/share/applications/${safeDesk}"; ` +
                                    `  fi; ` +
                                    `else ` +
                                    `  echo "Attempting package removal via pacman: ${safeClean}"; ` +
                                    `  sudo pacman -Rns "${safeClean}"; ` +
                                    `fi; ` +
                                    `echo ""; ` +
                                    `read -n 1 -s -r -p "Press any key to close this terminal..."' ; `
                                ]);
                            }
                        });

                        return actions;
                    }

                    StyledRectangularShadow { target: contextMenuCard }

                    Rectangle {
                        id: contextMenuCard
                        anchors.fill: parent
                        radius: Appearance.rounding.normal
                        color: Appearance.m3colors.m3surfaceContainerHigh
                        border.width: 1
                        border.color: Appearance.m3colors.m3outlineVariant

                        ColumnLayout {
                            id: contextCol
                            anchors.fill: parent
                            anchors.margins: 8
                            spacing: 4

                            // Header with app icon, bold title, and category/generic subtitle
                            RowLayout {
                                Layout.fillWidth: true
                                Layout.leftMargin: 8
                                Layout.rightMargin: 8
                                Layout.topMargin: 6
                                Layout.bottomMargin: 6
                                spacing: 10

                                Item {
                                    id: contextHeaderIconContainer
                                    implicitWidth: 32
                                    implicitHeight: 32
                                    Layout.alignment: Qt.AlignVCenter

                                    readonly property string resolvedIcon: root.resolveAppIcon(mainCard.contextApp)
                                    readonly property bool hasValidIcon: resolvedIcon.length > 0 && contextHeaderIcon.status !== Image.Error

                                    IconImage {
                                        id: contextHeaderIcon
                                        anchors.fill: parent
                                        source: contextHeaderIconContainer.resolvedIcon
                                        visible: contextHeaderIconContainer.hasValidIcon
                                        asynchronous: true
                                    }

                                    Rectangle {
                                        anchors.fill: parent
                                        radius: Appearance.rounding.small
                                        color: Appearance.colors.colSecondaryContainer
                                        visible: !contextHeaderIconContainer.hasValidIcon

                                        MaterialSymbol {
                                            anchors.centerIn: parent
                                            text: "deployed_code"
                                            iconSize: 18
                                            color: Appearance.colors.colOnSecondaryContainer
                                        }
                                    }
                                }

                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 2

                                    RowLayout {
                                        Layout.fillWidth: true
                                        spacing: 6

                                        StyledText {
                                            Layout.fillWidth: true
                                            text: mainCard.contextApp?.name ?? ""
                                            font.weight: Font.Bold
                                            font.pixelSize: Appearance.font.pixelSize.normal
                                            color: Appearance.m3colors.m3onSurface
                                            elide: Text.ElideRight
                                        }

                                        Rectangle {
                                            readonly property string sourceText: root.getAppSource(mainCard.contextApp)
                                            visible: sourceText.length > 0
                                            implicitHeight: 16
                                            implicitWidth: contextSourceRow.implicitWidth + 8
                                            radius: Appearance.rounding.full
                                            color: Appearance.colors.colLayer2
                                            border.width: 1
                                            border.color: Appearance.m3colors.m3outlineVariant

                                            RowLayout {
                                                id: contextSourceRow
                                                anchors.centerIn: parent
                                                spacing: 3

                                                MaterialSymbol {
                                                    visible: parent.parent.sourceText === "kitty" || parent.parent.sourceText === "Local"
                                                    text: parent.parent.sourceText === "kitty" ? "terminal" : "folder"
                                                    iconSize: 10
                                                    color: parent.parent.sourceText === "kitty" ? Appearance.colors.colPrimary : Appearance.colors.colOutline
                                                }

                                                StyledText {
                                                    text: parent.parent.sourceText
                                                    font.pixelSize: Appearance.font.pixelSize.smaller
                                                    font.weight: Font.DemiBold
                                                    color: {
                                                        switch (parent.parent.sourceText) {
                                                            case "Pacman": return Appearance.colors.colPrimary;
                                                            case "AUR": return Appearance.colors.colPrimary;
                                                            case "Flatpak": return Appearance.colors.colSecondary;
                                                            case "AppImage": return Appearance.colors.colTertiary;
                                                            case "kitty": return Appearance.colors.colPrimary;
                                                            default: return Appearance.colors.colOutline;
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }

                                    StyledText {
                                        Layout.fillWidth: true
                                        visible: text.length > 0
                                        text: mainCard.contextApp?.genericName || mainCard.contextApp?.comment || (mainCard.contextApp?.categories ? mainCard.contextApp.categories.join(", ") : "")
                                        font.pixelSize: Appearance.font.pixelSize.smaller
                                        color: Appearance.colors.colSubtext
                                        elide: Text.ElideRight
                                    }
                                }
                            }

                            Rectangle {
                                Layout.fillWidth: true
                                height: 1
                                color: Appearance.m3colors.m3outlineVariant
                            }

                            // Dynamic context actions with hover & keyboard highlight sync
                            Repeater {
                                model: contextMenuContainer.contextActions
                                delegate: ContextMenuItem {
                                    required property var modelData
                                    required property int index
                                    iconText: modelData.iconText
                                    label: modelData.label
                                    isDestructive: !!modelData.isDestructive
                                    isHighlighted: contextMenuContainer.selectedActionIndex === index
                                    onHoveredAction: {
                                        contextMenuContainer.selectedActionIndex = index;
                                    }
                                    onTriggered: {
                                        modelData.trigger();
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
