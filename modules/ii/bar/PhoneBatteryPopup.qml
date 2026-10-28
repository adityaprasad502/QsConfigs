import qs.modules.common
import qs.modules.common.widgets
import qs.services
import QtQuick
import QtQuick.Layouts

StyledPopup {
    id: root
    property var phone: null

    property real liveNow: Date.now()

    Column {
        anchors.centerIn: parent
        spacing: 8

        Timer {
            interval: 1000
            running: root.active && (root.phone?.reachable ?? false)
            repeat: true
            onTriggered: root.liveNow = Date.now()
        }

        StyledPopupHeaderRow {
            anchors.horizontalCenter: parent.horizontalCenter
            icon: root.phone?.reachable ? "smartphone" : "phonelink_erase"
            label: root.phone?.name ?? ""
        }

        GridLayout {
            columns: 2
            rowSpacing: 5
            columnSpacing: 5
            uniformCellWidths: true
            visible: root.phone?.reachable ?? false

            // Row 1: Current Live State
            StatCard {
                symbol: root.phone?.isCharging ? "battery_charging_full" : "battery_std"
                title: root.phone?.isCharging
                    ? (root.phone?.charge >= 100 ? "Full" : "Charging")
                    : "Battery"
                value: (root.phone?.charge ?? -1) >= 0 ? (root.phone.charge + "%") : "?"
            }

            StatCard {
                symbol: {
                    if ((root.phone?.netStrength ?? 0) <= 0) return "signal_cellular_off"
                    const bars = ["signal_cellular_0_bar", "signal_cellular_1_bar",
                                  "signal_cellular_2_bar", "signal_cellular_3_bar",
                                  "signal_cellular_4_bar"]
                    return bars[Math.max(0, Math.min(4, root.phone?.netStrength ?? 0))]
                }
                title: "Network"
                value: {
                    if ((root.phone?.netStrength ?? 0) <= 0) return "No Signal"
                    if (!root.phone?.networkType || root.phone.networkType === "Unknown") return "Standby"
                    return root.phone.networkType
                }
            }

            // Row 2: Session Context (How long, how much)
            StatCard {
                symbol: "link"
                title: Translation.tr("Connected")
                value: {
                    void(root.liveNow)
                    const secs = (root.liveNow - (root.phone?.sessionStartTime ?? root.liveNow)) / 1000
                    const h = Math.floor(secs / 3600)
                    const m = Math.floor((secs % 3600) / 60)
                    return h > 0 ? `${h}h ${m}m` : `${m}m`
                }
            }

            StatCard {
                symbol: "history"
                title: Translation.tr("This Session")
                value: {
                    const curCharge = root.phone?.charge ?? -1
                    const startCharge = root.phone?.sessionStartCharge ?? -1
                    if (curCharge < 0 || startCharge < 0) return "---"
                    const delta = curCharge - startCharge
                    return (delta > 0 ? "+" : "") + delta + "%"
                }
            }

            // Row 3: Current Estimates & Pace
            StatCard {
                visible: (root.phone?.isCharging ?? false) || (Math.abs(root.phone?.chargeRate || root.phone?.avgChargeRate || 0) >= 0.03)
                symbol: "avg_pace"
                title: root.phone?.isCharging ? Translation.tr("Avg Rate") : Translation.tr("Discharge Rate")
                value: {
                    void(root.liveNow)
                    const isCharging = root.phone?.isCharging ?? false
                    const avg = root.phone?.avgChargeRate || root.phone?.chargeRate || 0
                    const curCharge = root.phone?.charge ?? -1
                    const startCharge = root.phone?.sessionStartCharge ?? -1
                    const delta = (curCharge >= 0 && startCharge >= 0) ? (curCharge - startCharge) : 0
                    const mins = (root.liveNow - (root.phone?.sessionStartTime ?? root.liveNow)) / 60000

                    if (Math.abs(avg) >= 0.05) {
                        return (avg > 0 ? "+" : "") + avg.toFixed(1) + "%/min"
                    }
                    if (isCharging && mins < 0.75 && delta === 0) {
                        return Translation.tr("Calculating…")
                    }
                    if (delta !== 0 && mins > 0) {
                        let r = delta / mins
                        return (r > 0 ? "+" : "") + r.toFixed(1) + "%/min"
                    }
                    return "---"
                }
            }

            StatCard {
                visible: (root.phone?.isCharging ?? false) || (Math.abs(root.phone?.chargeRate || root.phone?.avgChargeRate || 0) >= 0.03)
                symbol: root.phone?.isCharging
                    ? ((root.phone?.charge ?? 0) >= 100 ? "task_alt" : "schedule")
                    : "timelapse"
                title: root.phone?.isCharging
                    ? ((root.phone?.charge ?? 0) >= 100 ? Translation.tr("Full For") : Translation.tr("Time to Full"))
                    : Translation.tr("Time to Empty")
                value: {
                    void(root.liveNow)
                    const isCharging = root.phone?.isCharging ?? false
                    const curCharge = root.phone?.charge ?? -1
                    if (curCharge < 0) return "---"

                    if (isCharging) {
                        if (curCharge >= 100 && root.phone?.timeReachedFull) {
                            const secs = (root.liveNow - root.phone.timeReachedFull) / 1000
                            const h = Math.floor(secs / 3600)
                            const m = Math.floor((secs % 3600) / 60)
                            return h > 0 ? `${h}h ${m}m` : `${m}m`
                        }
                        const rate = root.phone?.chargeRate || 0
                        const avg = root.phone?.avgChargeRate || 0
                        const effectiveRate = (rate > 0 && avg > 0) ? (0.7 * rate + 0.3 * avg) : (rate > 0 ? rate : avg)
                        if (effectiveRate < 0.05) {
                            const mins = (root.liveNow - (root.phone?.sessionStartTime ?? root.liveNow)) / 60000
                            return mins < 1.0 ? Translation.tr("Estimating…") : "---"
                        }
                        const rem = Math.max(0, 100 - curCharge)
                        const remMins = Math.round(rem / effectiveRate)
                        if (remMins <= 0) return Translation.tr("Almost Full")
                        const h = Math.floor(remMins / 60)
                        const m = remMins % 60
                        return h > 0 ? `${h}h ${m}m` : `${m}m`
                    } else {
                        const rate = Math.abs(root.phone?.chargeRate || root.phone?.avgChargeRate || 0)
                        if (rate < 0.03) return "---"
                        const remMins = Math.round(curCharge / rate)
                        if (remMins <= 0) return "---"
                        const h = Math.floor(remMins / 60)
                        const m = remMins % 60
                        return h > 0 ? `${h}h ${m}m` : `${m}m`
                    }
                }
            }

            // Row 4: Session Extremes (Hidden when discharging)
            StatCard {
                visible: root.phone?.isCharging ?? false
                symbol: "trending_up"
                title: Translation.tr("Peak Rate")
                value: {
                    const peak = root.phone?.peakChargeRate ?? 0
                    if (peak < 0.05) return "---"
                    return "+" + peak.toFixed(1) + "%/min"
                }
            }

            StatCard {
                visible: root.phone?.isCharging ?? false
                symbol: "trending_down"
                title: Translation.tr("Low Rate")
                value: {
                    const low = root.phone?.minChargeRate ?? 0
                    if (low < 0.05) return "---"
                    return "+" + low.toFixed(1) + "%/min"
                }
            }
        }

        StyledText {
            visible: !(root.phone?.reachable ?? false)
            text: "Not reachable"
            color: Appearance.colors.colSubtext
            font.pixelSize: Appearance.font.pixelSize.small
            anchors.horizontalCenter: parent.horizontalCenter
        }

        StyledText {
            visible: root.phone?.reachable ?? false
            text: Translation.tr("Middle-click to ring phone")
            color: Appearance.colors.colSubtext
            font.pixelSize: Appearance.font.pixelSize.smaller
            anchors.horizontalCenter: parent.horizontalCenter
        }
    }
}
