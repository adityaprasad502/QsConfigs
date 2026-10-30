pragma Singleton
pragma ComponentBehavior: Bound

import qs.modules.common
import QtQuick
import Quickshell
import Quickshell.Io

/**
 * Simple polled resource usage service with RAM, Swap, and CPU usage.
 */
Singleton {
    id: root
	property real memoryTotal: 1
	property real memoryFree: 0
	property real memoryUsed: memoryTotal - memoryFree
    property real memoryUsedPercentage: memoryUsed / memoryTotal
    property real swapTotal: 1
	property real swapFree: 0
	property real swapUsed: swapTotal - swapFree
    property real swapUsedPercentage: swapTotal > 0 ? (swapUsed / swapTotal) : 0
    property real cpuUsage: 0
    property var previousCpuStats

    // Network speed and total traffic tracking
    property real networkRxSpeed: 0
    property real networkTxSpeed: 0
    property real networkTotalRxBytes: 0
    property real networkTotalTxBytes: 0
    property real previousRxBytes: -1
    property real previousTxBytes: -1
    property real previousNetworkTimestamp: 0

    function formatNetworkSpeed(bytesPerSec) {
        const bitsPerSec = bytesPerSec * 8;
        if (bitsPerSec < 1000) return Math.round(bitsPerSec) + " bps";
        if (bitsPerSec < 1000 * 1000) {
            const kb = bitsPerSec / 1000;
            return (kb >= 100 ? Math.round(kb) : kb.toFixed(1)) + " Kbps";
        }
        const mb = bitsPerSec / (1000 * 1000);
        return (mb >= 100 ? Math.round(mb) : mb.toFixed(1)) + " Mbps";
    }

    function formatNetworkTotal(bytes) {
        if (bytes < 1024) return Math.round(bytes) + " B";
        if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + " KB";
        if (bytes < 1024 * 1024 * 1024) return (bytes / (1024 * 1024)).toFixed(1) + " MB";
        return (bytes / (1024 * 1024 * 1024)).toFixed(2) + " GB";
    }

    property string maxAvailableMemoryString: kbToGbString(ResourceUsage.memoryTotal)
    property string maxAvailableSwapString: kbToGbString(ResourceUsage.swapTotal)
    property string maxAvailableCpuString: "--"
    property string cpuTempString: "---"
    property string cpuCurrentFreqString: "---"

    readonly property int historyLength: Config?.options.resources.historyLength ?? 60
    property list<real> cpuUsageHistory: []
    property list<real> memoryUsageHistory: []
    property list<real> swapUsageHistory: []

    function kbToGbString(kb) {
        return (kb / (1024 * 1024)).toFixed(1) + " GB";
    }

    function updateMemoryUsageHistory() {
        if (memoryUsageHistory.length >= historyLength) memoryUsageHistory.splice(0, 1)
        memoryUsageHistory.push(memoryUsedPercentage)
        memoryUsageHistoryChanged()
    }
    function updateSwapUsageHistory() {
        if (swapUsageHistory.length >= historyLength) swapUsageHistory.splice(0, 1)
        swapUsageHistory.push(swapUsedPercentage)
        swapUsageHistoryChanged()
    }
    function updateCpuUsageHistory() {
        if (cpuUsageHistory.length >= historyLength) cpuUsageHistory.splice(0, 1)
        cpuUsageHistory.push(cpuUsage)
        cpuUsageHistoryChanged()
    }
    function updateHistories() {
        updateMemoryUsageHistory()
        updateSwapUsageHistory()
        updateCpuUsageHistory()
    }

    Timer {
        interval: Config.options?.resources?.updateInterval ?? 3000
        running: true
        repeat: true
        triggeredOnStart: true
        property int _cpuInfoTick: 0
        onTriggered: {
            // Reload files
            fileMeminfo.reload()
            fileStat.reload()
            fileNetDev.reload()
            // /proc/cpuinfo only changes on CPU freq scaling; read every 10th tick (~30s default)
            if (++_cpuInfoTick % 10 === 0) fileCpuInfo.reload()
            if (fileCpuTemp.path !== "") {
                fileCpuTemp.reload()
            }

            // Parse memory and swap usage
            const textMeminfo = fileMeminfo.text()
            memoryTotal = Number(textMeminfo.match(/MemTotal: *(\d+)/)?.[1] ?? 1)
            memoryFree = Number(textMeminfo.match(/MemAvailable: *(\d+)/)?.[1] ?? 0)
            swapTotal = Number(textMeminfo.match(/SwapTotal: *(\d+)/)?.[1] ?? 1)
            swapFree = Number(textMeminfo.match(/SwapFree: *(\d+)/)?.[1] ?? 0)

            // Parse CPU usage
            const textStat = fileStat.text()
            const cpuLine = textStat.match(/^cpu\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)/)
            if (cpuLine) {
                const stats = cpuLine.slice(1).map(Number)
                const total = stats.reduce((a, b) => a + b, 0)
                const idle = stats[3]

                if (previousCpuStats) {
                    const totalDiff = total - previousCpuStats.total
                    const idleDiff = idle - previousCpuStats.idle
                    cpuUsage = totalDiff > 0 ? (1 - idleDiff / totalDiff) : 0
                }

                previousCpuStats = { total, idle }
            }

            root.updateHistories()
        }
    }

	FileView { id: fileMeminfo; path: "/proc/meminfo" }
    FileView { id: fileStat; path: "/proc/stat" }
    FileView {
        id: fileNetDev
        path: "/proc/net/dev"
        onLoaded: {
            const textNetDev = text()
            if (textNetDev && textNetDev.length > 0) {
                const lines = textNetDev.split("\n")
                let totalRx = 0
                let totalTx = 0
                for (let i = 2; i < lines.length; i++) {
                    const line = lines[i].trim()
                    if (!line || line.startsWith("lo:")) continue
                    const colonIdx = line.indexOf(":")
                    if (colonIdx !== -1) {
                        const dataStr = line.substring(colonIdx + 1).trim()
                        const dataParts = dataStr.split(/\s+/)
                        if (dataParts.length >= 9) {
                            totalRx += Number(dataParts[0]) || 0
                            totalTx += Number(dataParts[8]) || 0
                        }
                    }
                }
                const now = Date.now()
                if (root.previousRxBytes >= 0 && root.previousTxBytes >= 0 && root.previousNetworkTimestamp > 0 && now > root.previousNetworkTimestamp) {
                    const dt = (now - root.previousNetworkTimestamp) / 1000
                    const rxDiff = totalRx - root.previousRxBytes
                    const txDiff = totalTx - root.previousTxBytes
                    if (rxDiff >= 0 && dt > 0) root.networkRxSpeed = rxDiff / dt
                    if (txDiff >= 0 && dt > 0) root.networkTxSpeed = txDiff / dt
                }
                root.networkTotalRxBytes = totalRx
                root.networkTotalTxBytes = totalTx
                root.previousRxBytes = totalRx
                root.previousTxBytes = totalTx
                root.previousNetworkTimestamp = now
            }
        }
    }

    Process {
        id: findTempPathProc
        environment: ({
            LANG: "C",
            LC_ALL: "C"
        })
        command: ["bash", "-c", "grep \"\" /sys/class/hwmon/hwmon*/name 2>/dev/null | awk -F: '/k10temp|coretemp/ {print $1}' | head -n 1 | sed 's/name/temp1_input/'"]
        running: true
        stdout: StdioCollector {
            onStreamFinished: {
                if (text.trim().length > 0) {
                    fileCpuTemp.path = text.trim()
                    fileCpuTemp.reload()
                }
            }
        }
    }

    FileView {
        id: fileCpuTemp
        onLoaded: {
            const val = parseInt(text())
            if (!isNaN(val)) {
                root.cpuTempString = (val / 1000).toFixed(1) + "°C"
            }
        }
    }

    FileView {
        id: fileCpuInfo
        path: "/proc/cpuinfo"
        onLoaded: {
            const txt = text()
            let sum = 0
            let count = 0
            const regex = /cpu MHz\s+:\s+([\d.]+)/g
            let match;
            while ((match = regex.exec(txt)) !== null) {
                sum += parseFloat(match[1])
                count++
            }
            if (count > 0) {
                root.cpuCurrentFreqString = (sum / count / 1000).toFixed(2) + " GHz"
            }
        }
    }
}
