import qs.modules.common
import qs.modules.common.widgets
import qs.services
import QtQuick
import QtQuick.Layouts

StyledPopup {
    id: root

    // Helper function to format KB to GB
    function formatKB(kb) {
        if (kb === 0) return "0 GB";
        return (kb / (1024 * 1024)).toFixed(1) + " GB";
    }

    Column {
        anchors.centerIn: parent
        spacing: 8

        StyledPopupHeaderRow {
            anchors.horizontalCenter: parent.horizontalCenter
            icon: "memory"
            label: Translation.tr("System Resources")
        }

        GridLayout {
            columns: 3
            rowSpacing: 5
            columnSpacing: 5
            uniformCellWidths: true

            // RAM & Swap
            StatCard {
                symbol: "clock_loader_60"
                title: Translation.tr("RAM Used")
                value: root.formatKB(ResourceUsage.memoryUsed)
            }
            StatCard {
                symbol: "check_circle"
                title: Translation.tr("RAM Free")
                value: root.formatKB(ResourceUsage.memoryFree)
            }
            StatCard {
                visible: ResourceUsage.swapTotal > 0
                symbol: "check_circle"
                title: Translation.tr("Swap Free")
                value: root.formatKB(ResourceUsage.swapFree)
                Layout.columnSpan: 1
            }

            // GPU & Cooling
            StatCard {
                symbol: "developer_board"
                title: ResourceUsage.gpuActiveName.length > 0 ? Translation.tr("GPU (%1)").arg(ResourceUsage.gpuActiveName) : Translation.tr("GPU Load")
                value: ResourceUsage.gpuUsageString
            }
            StatCard {
                symbol: "thermostat"
                title: Translation.tr("GPU Temp")
                value: ResourceUsage.gpuTempString
            }
            StatCard {
                symbol: "mode_fan"
                title: Translation.tr("Fans (CPU / GPU)")
                value: ResourceUsage.fanSpeedString
            }

            // CPU
            StatCard {
                symbol: "planner_review"
                title: Translation.tr("CPU Load")
                value: `${Math.round(ResourceUsage.cpuUsage * 100)}%`
            }
            StatCard {
                symbol: "speed"
                title: Translation.tr("CPU Freq")
                value: ResourceUsage.cpuCurrentFreqString
            }
            StatCard {
                symbol: "thermostat"
                title: Translation.tr("CPU Temp")
                value: ResourceUsage.cpuTempString
            }
        }
    }
}
