import qs.modules.common
import qs.modules.common.models.quickToggles
import qs.modules.common.widgets
import Quickshell
import Quickshell.Io

QuickToggleButton {
    id: root
    buttonIcon: "shield_lock"
    toggled: false
    visible: false

    onClicked: {
        if (toggled) {
            Quickshell.execDetached(["nextdns", "stop"])
            root.toggled = false
        } else {
            Quickshell.execDetached(["nextdns", "start"])
            root.toggled = true
        }
        fetchActiveState.running = true
    }

    Process {
        id: fetchActiveState
        running: true
        command: ["bash", "-c", "command -v nextdns >/dev/null 2>&1 && nextdns status"]
        stdout: StdioCollector {
            id: nextDnsStatusCollector
            onStreamFinished: {
                if (nextDnsStatusCollector.text.trim().length > 0) {
                    root.visible = true
                }
                const text = nextDnsStatusCollector.text.trim().toLowerCase();
                if (text.includes("running")) {
                    root.toggled = true;
                } else if (text.includes("stopped")) {
                    root.toggled = false;
                }
            }
        }
    }

    StyledToolTip {
        text: Translation.tr("NextDNS")
    }
}
