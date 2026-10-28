pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

Item {
    id: root

    // List of device objects: { id, name, reachable, charge, isCharging, networkType, netStrength }
    property var devices: []

    function findPhone(deviceId) {
        if (!deviceId) return;
        Quickshell.execDetached(["kdeconnect-cli", "-d", deviceId, "--ring"]);
    }

    function removeDevice(deviceId) {
        if (!devices.some(d => d.id === deviceId)) return;
        devices = devices.filter(d => d.id !== deviceId);
    }

    function updateDevice(data) {
        if (!data || !data.id) return;
        let list = devices.slice();
        let idx = list.findIndex(d => d.id === data.id);
        if (idx === -1) {
            list.push(data);
            devices = list;
            return;
        }

        // Avoid reallocating array and notifying bindings when no values actually changed
        let current = list[idx];
        let hasChanges = false;
        for (let key in data) {
            if (current[key] !== data[key]) {
                hasChanges = true;
                break;
            }
        }
        if (!hasChanges) return;

        list[idx] = Object.assign({}, current, data);
        devices = list;
    }

    Process {
        id: listenerProc
        running: true
        command: ["python3", Quickshell.shellPath("scripts/kdeconnect-listen.py")]

        stdout: SplitParser {
            onRead: line => {
                try {
                    let data = JSON.parse(line);
                    if (data.event === "nodevices") {
                        if (root.devices.length > 0) root.devices = [];
                        return;
                    }
                    if (data.event === "device_removed") {
                        root.removeDevice(data.id);
                        return;
                    }
                    if (data.event === "name") {
                        root.updateDevice({ id: data.id, name: data.name });
                        return;
                    }
                    if (data.event === "state") {
                        const prev = root.devices.find(d => d.id === data.id);
                        const wasDisconnected = prev && !prev.reachable && data.reachable;
                        const wasDisconnectedTooLong = prev && prev.disconnectTime && (Date.now() - prev.disconnectTime > 300000);
                        const chargingFlipped = !prev || (prev.isCharging !== data.charging) || wasDisconnectedTooLong || wasDisconnected;
                        const now = Date.now();
                        const validCharge = data.charge >= 0 ? data.charge : (prev?.charge >= 0 ? prev.charge : null);

                        const prevStartInvalid = !prev || prev.sessionStartCharge == null || prev.sessionStartCharge <= 0;
                        const newSessionStartCharge = (chargingFlipped || prevStartInvalid) ? validCharge : prev.sessionStartCharge;
                        const newSessionStartTime = (chargingFlipped || !prev?.sessionStartTime) ? now : prev.sessionStartTime;

                        let history = chargingFlipped ? [] : (prev?.batteryHistory ? prev.batteryHistory.slice() : []);
                        if (data.charge >= 0 && (history.length === 0 || history[history.length - 1].charge !== data.charge)) {
                            history.push({ time: now, charge: data.charge });
                            if (history.length > 15) history.shift();
                        }

                        root.updateDevice({
                            id:                   data.id,
                            name:                 data.name,
                            reachable:            data.reachable,
                            charge:               data.charge,
                            isCharging:           data.charging,
                            networkType:          data.netType,
                            netStrength:          data.netStrength,

                            chargeRate:           chargingFlipped ? 0 : (prev?.chargeRate ?? 0),
                            avgChargeRate:        chargingFlipped ? 0 : (prev?.avgChargeRate ?? 0),
                            lastBatteryTime:      now,
                            lastChargeChangeTime: chargingFlipped ? now : (prev?.lastChargeChangeTime ?? now),
                            batteryHistory:       history,
                            sessionStartCharge:   newSessionStartCharge,
                            sessionStartTime:     newSessionStartTime,
                            timeReachedFull:      (data.charging && data.charge >= 100)
                                ? (chargingFlipped ? now : (prev?.timeReachedFull ?? now))
                                : null,
                            peakChargeRate:       chargingFlipped ? 0 : (prev?.peakChargeRate ?? 0),
                            minChargeRate:        chargingFlipped ? 0 : (prev?.minChargeRate ?? 0),
                            disconnectTime:       data.reachable ? 0 : (prev?.disconnectTime ?? now)
                        });
                        return;
                    }
                    if (data.event === "battery") {
                        const prev = root.devices.find(d => d.id === data.id);
                        const now = Date.now();
                        const isCharging = data.charging;
                        const newCharge = data.charge;

                        const wasDisconnectedTooLong = prev && prev.disconnectTime && (now - prev.disconnectTime > 300000);
                        const chargingFlipped = !prev || (prev.isCharging !== isCharging) || wasDisconnectedTooLong;
                        const validCharge = newCharge >= 0 ? newCharge : (prev?.charge >= 0 ? prev.charge : null);

                        const prevStartInvalid = !prev || prev.sessionStartCharge == null || prev.sessionStartCharge <= 0;
                        const newSessionStartCharge = (chargingFlipped || prevStartInvalid) ? validCharge : prev.sessionStartCharge;
                        const newSessionStartTime = (chargingFlipped || !prev?.sessionStartTime) ? now : prev.sessionStartTime;

                        let timeReachedFull = prev?.timeReachedFull ?? null;
                        if (isCharging && newCharge >= 100) {
                            if (!timeReachedFull) timeReachedFull = now;
                        } else {
                            timeReachedFull = null;
                        }

                        let history = chargingFlipped ? [] : (prev?.batteryHistory ? prev.batteryHistory.slice() : []);
                        let chargeRate = chargingFlipped ? 0 : (prev?.chargeRate ?? 0);
                        let lastChangeTime = chargingFlipped ? now : (prev?.lastChargeChangeTime ?? now);

                        if (newCharge >= 0) {
                            let chargeChanged = (history.length === 0 || history[history.length - 1].charge !== newCharge);
                            if (chargeChanged) {
                                history.push({ time: now, charge: newCharge });
                                if (history.length > 15) history.shift();
                                lastChangeTime = now;

                                if (history.length >= 2) {
                                    let oldest = history[0];
                                    for (let i = history.length - 2; i >= 0; i--) {
                                        if ((now - history[i].time) >= 45000) {
                                            oldest = history[i];
                                            break;
                                        }
                                    }
                                    let dSec = (now - oldest.time) / 1000;
                                    let dCharge = newCharge - oldest.charge;
                                    if (dSec >= 30 && dSec <= 1800 && dCharge !== 0) {
                                        let rawRate = (dCharge / dSec) * 60; // %/min
                                        if (chargeRate !== 0 && ((chargeRate > 0) === (rawRate > 0))) {
                                            chargeRate = 0.7 * rawRate + 0.3 * chargeRate;
                                        } else {
                                            chargeRate = rawRate;
                                        }
                                    }
                                }
                            }
                        }

                        let avgChargeRate = 0;
                        if (newSessionStartCharge != null && newCharge >= 0) {
                            let sessionMins = (now - newSessionStartTime) / 60000;
                            let stepMins = (lastChangeTime - newSessionStartTime) / 60000;
                            let sessionDelta = newCharge - newSessionStartCharge;

                            if (sessionDelta !== 0 && stepMins >= 0.5) {
                                avgChargeRate = sessionDelta / stepMins;
                            } else if (sessionDelta !== 0 && sessionMins >= 0.5) {
                                avgChargeRate = sessionDelta / sessionMins;
                            } else if (chargeRate !== 0) {
                                avgChargeRate = chargeRate;
                            }
                        }

                        let peakRate = chargingFlipped ? 0 : (prev?.peakChargeRate ?? 0);
                        let minRate = chargingFlipped ? 0 : (prev?.minChargeRate ?? 0);
                        if (isCharging && chargeRate > 0) {
                            peakRate = Math.max(peakRate, chargeRate);
                            minRate = (minRate > 0) ? Math.min(minRate, chargeRate) : chargeRate;
                        }

                        root.updateDevice({
                            id:                   data.id,
                            charge:               newCharge,
                            isCharging:           isCharging,
                            chargeRate:           chargeRate,
                            avgChargeRate:        avgChargeRate,
                            lastBatteryTime:      now,
                            lastChargeChangeTime: lastChangeTime,
                            batteryHistory:       history,
                            sessionStartCharge:   newSessionStartCharge,
                            sessionStartTime:     newSessionStartTime,
                            timeReachedFull:      chargingFlipped ? ((isCharging && newCharge >= 100) ? now : null) : timeReachedFull,
                            peakChargeRate:       peakRate,
                            minChargeRate:        minRate
                        });
                        return;
                    }
                    if (data.event === "network") {
                        root.updateDevice({ id: data.id, networkType: data.netType, netStrength: data.netStrength });
                        return;
                    }
                    if (data.event === "reachable") {
                        const prev = root.devices.find(d => d.id === data.id);
                        const now = Date.now();
                        const justConnected = prev && !prev.reachable && data.reachable;
                        const wasDisconnectedTooLong = prev && prev.disconnectTime && (now - prev.disconnectTime > 300000);
                        const shouldResetSession = justConnected && (wasDisconnectedTooLong || !prev.sessionStartTime || !prev.sessionStartCharge || prev.sessionStartCharge <= 0);

                        root.updateDevice({
                            id:                   data.id,
                            name:                 data.name,
                            reachable:            data.reachable,
                            disconnectTime:       data.reachable ? 0 : (prev?.disconnectTime || now),
                            sessionStartTime:     shouldResetSession ? now : (prev?.sessionStartTime ?? now),
                            sessionStartCharge:   shouldResetSession ? (prev?.charge >= 0 ? prev.charge : null) : (prev?.sessionStartCharge ?? null),
                            chargeRate:           shouldResetSession ? 0 : (prev?.chargeRate ?? 0),
                            avgChargeRate:        shouldResetSession ? 0 : (prev?.avgChargeRate ?? 0),
                            peakChargeRate:       shouldResetSession ? 0 : (prev?.peakChargeRate ?? 0),
                            minChargeRate:        shouldResetSession ? 0 : (prev?.minChargeRate ?? 0),
                            batteryHistory:       shouldResetSession ? (prev?.charge >= 0 ? [{ time: now, charge: prev.charge }] : []) : (prev?.batteryHistory ?? []),
                            lastChargeChangeTime: shouldResetSession ? now : (prev?.lastChargeChangeTime ?? now)
                        });
                        return;
                    }
                } catch (e) {}
            }
        }

        // Auto-restart if the script exits unexpectedly
        onExited: {
            if (running === false) {
                restartTimer.start();
            }
        }
    }

    Timer {
        id: restartTimer
        interval: 5000
        onTriggered: listenerProc.running = true
    }
}
