import qs
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions
import qs.services
import qs.services.network
import QtQuick
import QtQuick.Layouts

DialogListItem {
    id: root
    required property WifiAccessPoint wifiNetwork
    enabled: !(Network.wifiConnectTarget === root.wifiNetwork && !wifiNetwork?.active)
    property bool expanded: false

    active: (wifiNetwork?.askingPassword || wifiNetwork?.active) ?? false
    pointingHandCursor: !wifiNetwork?.active || !expanded

    onClicked: {
        if (root.wifiNetwork?.active) {
            root.expanded = !root.expanded;
        } else {
            Network.connectToWifiNetwork(wifiNetwork);
        }
    }

    contentItem: ColumnLayout {
        anchors {
            fill: parent
            topMargin: root.verticalPadding
            bottomMargin: root.verticalPadding
            leftMargin: root.horizontalPadding
            rightMargin: root.horizontalPadding
        }
        spacing: 0

        RowLayout {
            spacing: 12

            MaterialSymbol {
                Layout.alignment: Qt.AlignVCenter
                iconSize: Appearance.font.pixelSize.larger + 2
                property int strength: root.wifiNetwork?.strength ?? 0
                text: strength > 80 ? "signal_wifi_4_bar" : strength > 60 ? "network_wifi_3_bar" : strength > 40 ? "network_wifi_2_bar" : strength > 20 ? "network_wifi_1_bar" : "signal_wifi_0_bar"
                color: root.wifiNetwork?.active ? Appearance.colors.colPrimary : Appearance.colors.colOnSurfaceVariant
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 2

                StyledText {
                    Layout.fillWidth: true
                    color: root.wifiNetwork?.active ? Appearance.colors.colPrimary : Appearance.colors.colOnSurface
                    font.weight: root.wifiNetwork?.active ? Font.DemiBold : Font.Normal
                    elide: Text.ElideRight
                    text: root.wifiNetwork?.ssid ?? Translation.tr("Unknown")
                    textFormat: Text.PlainText
                }

                StyledText {
                    Layout.fillWidth: true
                    font.pixelSize: Appearance.font.pixelSize.smaller
                    color: root.wifiNetwork?.active ? Appearance.colors.colPrimary : Appearance.colors.colSubtext
                    elide: Text.ElideRight
                    text: {
                        let parts = [];
                        if (root.wifiNetwork?.active) {
                            parts.push(Translation.tr("Connected"));
                        } else if (Network.wifiConnectTarget === root.wifiNetwork) {
                            parts.push(Translation.tr("Connecting..."));
                        }

                        const freq = root.wifiNetwork?.frequency ?? 0;
                        if (freq >= 5925) parts.push("6 GHz");
                        else if (freq >= 4900) parts.push("5 GHz");
                        else if (freq > 0) parts.push("2.4 GHz");

                        const strength = root.wifiNetwork?.strength;
                        if (strength !== undefined && strength !== null && strength >= 0) {
                            parts.push(`${strength}%`);
                        }

                        const sec = (root.wifiNetwork?.security ?? "").trim();
                        parts.push(sec.length > 0 ? sec : Translation.tr("Open"));

                        return parts.join(" • ");
                    }
                }
            }

            MaterialSymbol {
                Layout.alignment: Qt.AlignVCenter
                visible: (root.wifiNetwork?.isSecure || root.wifiNetwork?.active || Network.wifiConnectTarget === root.wifiNetwork) ?? false
                text: root.wifiNetwork?.active ? "check" : Network.wifiConnectTarget === root.wifiNetwork ? "sync" : "lock"
                iconSize: Appearance.font.pixelSize.larger
                color: root.wifiNetwork?.active ? Appearance.colors.colPrimary : Appearance.colors.colOnSurfaceVariant
            }
        }

        RowLayout {
            visible: (root.wifiNetwork?.active && root.expanded) ?? false
            Layout.topMargin: 8
            Layout.fillWidth: true
            spacing: 8

            DialogButton {
                id: copyIpBtn
                property bool justCopied: false
                visible: Network.ipAddress.length > 0
                buttonText: justCopied ? Translation.tr("Copied!") : Translation.tr("Copy IP")
                colBackground: justCopied ? Appearance.colors.colPrimary : ColorUtils.transparentize(Appearance.colors.colLayer1Hover, 0.5)
                colBackgroundHover: justCopied ? Appearance.colors.colPrimaryHover : Appearance.colors.colLayer1Hover
                colRipple: justCopied ? Appearance.colors.colPrimaryActive : Appearance.colors.colLayer1Active
                colText: justCopied ? Appearance.colors.colOnPrimary : Appearance.colors.colOnSurface
                onClicked: {
                    copyIpBtn.justCopied = true;
                    revertTimer.restart();
                    Network.copyIpAddress();
                }

                Timer {
                    id: revertTimer
                    interval: 1500
                    repeat: false
                    onTriggered: copyIpBtn.justCopied = false
                }
            }

            Item { Layout.fillWidth: true }

            DialogButton {
                buttonText: Translation.tr("Forget")
                colBackground: ColorUtils.transparentize(Appearance.colors.colError, 0.8)
                colBackgroundHover: ColorUtils.transparentize(Appearance.colors.colError, 0.6)
                colRipple: Appearance.colors.colErrorActive
                colText: Appearance.colors.colError
                onClicked: {
                    Network.forgetNetwork(root.wifiNetwork?.ssid);
                    root.expanded = false;
                }
            }

            DialogButton {
                buttonText: Translation.tr("Disconnect")
                colBackground: Appearance.colors.colError
                colBackgroundHover: Appearance.colors.colErrorHover
                colRipple: Appearance.colors.colErrorActive
                colText: Appearance.colors.colOnError
                onClicked: {
                    Network.disconnectWifiNetwork();
                    root.expanded = false;
                }
            }
        }

        ColumnLayout { // Password
            id: passwordPrompt
            Layout.topMargin: 8
            visible: root.wifiNetwork?.askingPassword ?? false
            property bool showPassword: false

            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                MaterialTextField {
                    id: passwordField
                    Layout.fillWidth: true
                    placeholderText: Translation.tr("Password")

                    echoMode: passwordPrompt.showPassword ? TextInput.Normal : TextInput.Password
                    inputMethodHints: Qt.ImhSensitiveData

                    onAccepted: {
                        Network.changePassword(root.wifiNetwork, passwordField.text);
                    }
                }

                RippleButton {
                    implicitWidth: 36
                    implicitHeight: 36
                    buttonRadius: 18
                    colBackground: "transparent"
                    colBackgroundHover: Appearance.colors.colLayer1Hover
                    colRipple: Appearance.colors.colLayer1Active
                    onClicked: passwordPrompt.showPassword = !passwordPrompt.showPassword

                    StyledToolTip {
                        text: passwordPrompt.showPassword ? Translation.tr("Hide password") : Translation.tr("Show password")
                    }

                    MaterialSymbol {
                        anchors.centerIn: parent
                        text: passwordPrompt.showPassword ? "visibility_off" : "visibility"
                        iconSize: Appearance.font.pixelSize.larger
                        color: Appearance.colors.colOnSurfaceVariant
                    }
                }
            }

            RowLayout {
                Layout.fillWidth: true

                Item {
                    Layout.fillWidth: true
                }

                DialogButton {
                    buttonText: Translation.tr("Cancel")
                    onClicked: {
                        root.wifiNetwork.askingPassword = false;
                    }
                }

                DialogButton {
                    buttonText: Translation.tr("Connect")
                    onClicked: {
                        Network.changePassword(root.wifiNetwork, passwordField.text);
                    }
                }
            }
        }

        ColumnLayout { // Public wifi login page
            id: publicWifiPortal
            Layout.topMargin: 8
            visible: (root.wifiNetwork?.active && (root.wifiNetwork?.security ?? "").trim().length === 0) ?? false

            RowLayout {
                DialogButton {
                    Layout.fillWidth: true
                    buttonText: Translation.tr("Open network portal")
                    colBackground: Appearance.colors.colLayer4
                    colBackgroundHover: Appearance.colors.colLayer4Hover
                    colRipple: Appearance.colors.colLayer4Active
                    onClicked: {
                        Network.openPublicWifiPortal()
                        GlobalStates.sidebarRightOpen = false
                    }
                }
            }
        }

        Item {
            Layout.fillHeight: true
        }
    }
}
