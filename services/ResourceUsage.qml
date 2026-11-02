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

    // Power & GPU telemetry
    property string systemPowerTitle: Translation.tr("Power Draw")
    property string systemPowerIcon: "bolt"
    property string systemPowerString: "---"
    property real systemPowerWatts: 0
    property string gpuUsageString: "---"
    property string gpuTempString: "---"
    property string gpuActiveName: "AMD"
    property real gpuUsage: 0
    property int _nvUsagePercent: 0
    property int _nvTemp: 0
    property int _nvPollTick: 0
    property string fanSpeedString: "---"
    property string fanSpeedTitle: Translation.tr("Fan Speed")
    property int fanSpeedRPM: 0
    property int fan1RPM: 0
    property int fan2RPM: 0

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
            if (filePowerBat.path !== "") filePowerBat.reload()
            if (filePowerBatStatus.path !== "") filePowerBatStatus.reload()
            if (filePowerHwmon.path !== "") filePowerHwmon.reload()
            if (fileGpuLoad.path !== "") fileGpuLoad.reload()
            if (fileGpuTemp.path !== "") fileGpuTemp.reload()
            if (fileFan1.path !== "") fileFan1.reload()
            if (fileFan2.path !== "") fileFan2.reload()
            if (fileNvidiaStatus.path !== "") fileNvidiaStatus.reload()
            root.updateHardwareStats()

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

    function updateHardwareStats() {
        let batVal = parseInt(filePowerBat.text()) || 0
        let batStatus = filePowerBatStatus.text().trim()
        let hwmonVal = parseInt(filePowerHwmon.text()) || 0

        if (batStatus === "Charging" && batVal > 0) {
            let w = batVal / 1000000
            root.systemPowerWatts = w
            root.systemPowerString = w.toFixed(1) + " W"
            root.systemPowerTitle = Translation.tr("Charge Rate")
            root.systemPowerIcon = "battery_charging_full"
        } else if (batStatus === "Discharging" && batVal > 0) {
            let w = batVal / 1000000
            root.systemPowerWatts = w
            root.systemPowerString = w.toFixed(1) + " W"
            root.systemPowerTitle = Translation.tr("Power Draw")
            root.systemPowerIcon = "bolt"
        } else if (hwmonVal > 0) {
            let w = hwmonVal / 1000000
            root.systemPowerWatts = w
            root.systemPowerString = w.toFixed(1) + " W"
            root.systemPowerTitle = Translation.tr("SoC Power")
            root.systemPowerIcon = "memory"
        } else {
            root.systemPowerWatts = 0
            root.systemPowerString = "---"
            root.systemPowerTitle = Translation.tr("Power Draw")
            root.systemPowerIcon = "bolt"
        }

        // GPU load & active card
        let amdVal = parseInt(fileGpuLoad.text())
        let amdUsage = (!isNaN(amdVal) && amdVal >= 0) ? Math.min(1.0, amdVal / 100.0) : 0
        let amdString = (!isNaN(amdVal) && amdVal >= 0) ? Math.round(amdVal) + "%" : "---"

        let nvStatus = fileNvidiaStatus.text().trim()
        let isNvActive = (nvStatus === "active")
        if (isNvActive) {
            // Poll nvidia-smi every 5th tick (~5-15s) so the GPU can idle and autosuspend if unused
            if (++root._nvPollTick % 5 === 0 && !nvQueryProc.running) {
                nvQueryProc.running = true
            }
            // If NVIDIA has active compute/render workload (> 0%), showcase NVIDIA;
            // Otherwise show AMD since it is actively driving the display and desktop.
            if (root._nvUsagePercent > 0) {
                root.gpuActiveName = "NVIDIA"
                root.gpuUsage = root._nvUsagePercent / 100.0
                root.gpuUsageString = root._nvUsagePercent + "%"
            } else {
                root.gpuActiveName = "AMD"
                root.gpuUsage = amdUsage
                root.gpuUsageString = amdString
            }
        } else {
            root._nvPollTick = 0
            root._nvUsagePercent = 0
            root.gpuActiveName = "AMD"
            root.gpuUsage = amdUsage
            root.gpuUsageString = amdString
        }

        // GPU temperature
        let amdTempRaw = parseInt(fileGpuTemp.text())
        let amdTemp = (!isNaN(amdTempRaw) && amdTempRaw > 0) ? (amdTempRaw / 1000).toFixed(1) + "°C" : "---"
        if (root.gpuActiveName === "NVIDIA" && root._nvTemp > 0) {
            root.gpuTempString = root._nvTemp + "°C"
        } else if (amdTemp !== "---") {
            root.gpuTempString = amdTemp
        } else {
            root.gpuTempString = "---"
        }

        // Fan speeds
        let f1 = parseInt(fileFan1.text()) || 0
        let f2 = parseInt(fileFan2.text()) || 0
        root.fan1RPM = f1
        root.fan2RPM = f2
        if (fileFan1.path !== "" && fileFan2.path !== "") {
            if (f1 === f2) {
                root.fanSpeedString = `${f1} RPM`
                root.fanSpeedTitle = Translation.tr("Fan Speed")
            } else {
                root.fanSpeedString = `${f1} / ${f2} RPM`
                root.fanSpeedTitle = Translation.tr("Fans (CPU / GPU)")
            }
        } else if (f1 > 0 || f2 > 0) {
            root.fanSpeedString = `${Math.max(f1, f2)} RPM`
            root.fanSpeedTitle = Translation.tr("Fan Speed")
        } else if (fileFan1.path !== "" || fileFan2.path !== "") {
            root.fanSpeedString = "0 RPM"
            root.fanSpeedTitle = Translation.tr("Fan Speed")
        } else {
            root.fanSpeedString = "---"
            root.fanSpeedTitle = Translation.tr("Fan Speed")
        }
    }

    Process {
        id: findHardwarePathsProc
        environment: ({
            LANG: "C",
            LC_ALL: "C"
        })
        command: ["python3", Quickshell.shellPath("scripts/hardware-paths.py")]
        running: true
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    let d = JSON.parse(text.trim())
                    if (d.cpuTemp) { fileCpuTemp.path = d.cpuTemp; fileCpuTemp.reload(); }
                    if (d.powerBat) { filePowerBat.path = d.powerBat; filePowerBat.reload(); }
                    if (d.powerBatStatus) { filePowerBatStatus.path = d.powerBatStatus; filePowerBatStatus.reload(); }
                    if (d.powerHwmon) { filePowerHwmon.path = d.powerHwmon; filePowerHwmon.reload(); }
                    if (d.gpuLoad) { fileGpuLoad.path = d.gpuLoad; fileGpuLoad.reload(); }
                    if (d.gpuTemp) { fileGpuTemp.path = d.gpuTemp; fileGpuTemp.reload(); }
                    if (d.fanInputs && d.fanInputs.length > 0) {
                        fileFan1.path = d.fanInputs[0]; fileFan1.reload();
                        if (d.fanInputs.length > 1) { fileFan2.path = d.fanInputs[1]; fileFan2.reload(); }
                    }
                    if (d.nvidiaStatus) { fileNvidiaStatus.path = d.nvidiaStatus; fileNvidiaStatus.reload(); }
                    root.updateHardwareStats()
                } catch(e) {}
            }
        }
    }

    Process {
        id: nvQueryProc
        command: ["nvidia-smi", "--query-gpu=utilization.gpu,temperature.gpu", "--format=csv,noheader,nounits"]
        stdout: StdioCollector {
            onStreamFinished: {
                let parts = text.trim().split(",")
                let val = parseInt(parts[0])
                let temp = parts.length > 1 ? parseInt(parts[1]) : 0
                root._nvUsagePercent = (!isNaN(val) && val >= 0) ? Math.round(val) : 0
                root._nvTemp = (!isNaN(temp) && temp > 0) ? temp : 0
                if (root._nvUsagePercent > 0) {
                    root.gpuActiveName = "NVIDIA"
                    root.gpuUsage = Math.min(1.0, root._nvUsagePercent / 100.0)
                    root.gpuUsageString = root._nvUsagePercent + "%"
                    if (root._nvTemp > 0) root.gpuTempString = root._nvTemp + "°C"
                } else {
                    root.gpuActiveName = "AMD"
                    let amdVal = parseInt(fileGpuLoad.text())
                    if (!isNaN(amdVal) && amdVal >= 0) {
                        root.gpuUsage = Math.min(1.0, amdVal / 100.0)
                        root.gpuUsageString = Math.round(amdVal) + "%"
                    }
                }
            }
        }
    }

    FileView { id: filePowerBat; path: "" }
    FileView { id: filePowerBatStatus; path: "" }
    FileView { id: filePowerHwmon; path: "" }
    FileView { id: fileGpuLoad; path: "" }
    FileView { id: fileGpuTemp; path: "" }
    FileView { id: fileFan1; path: "" }
    FileView { id: fileFan2; path: "" }
    FileView { id: fileNvidiaStatus; path: "" }

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
