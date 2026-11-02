#!/usr/bin/env python3
import glob
import json
import os

res = {}

# 1. CPU temp
for h in glob.glob("/sys/class/hwmon/hwmon*"):
    try:
        n = open(os.path.join(h, "name")).read().strip()
        if n in ("k10temp", "coretemp", "zenpower", "cpu_thermal"):
            t = os.path.join(h, "temp1_input")
            if os.path.isfile(t):
                res["cpuTemp"] = t
                break
    except Exception:
        pass

# 2. Battery Power & Status
for b in glob.glob("/sys/class/power_supply/BAT*"):
    p = os.path.join(b, "power_now")
    s = os.path.join(b, "status")
    if os.path.isfile(p):
        res["powerBat"] = p
    if os.path.isfile(s):
        res["powerBatStatus"] = s
    if "powerBat" in res:
        break

# 3. SoC / Package Power (hwmon)
for h in glob.glob("/sys/class/hwmon/hwmon*"):
    try:
        n = open(os.path.join(h, "name")).read().strip()
        if n in ("amdgpu", "coretemp", "intel-rapl"):
            for p_name in ("power1_average", "power1_input"):
                p = os.path.join(h, p_name)
                if os.path.isfile(p):
                    res["powerHwmon"] = p
                    break
            if "powerHwmon" in res:
                break
    except Exception:
        pass

# 4. AMD / Intel GPU Load
for c in glob.glob("/sys/class/drm/card*/device/gpu_busy_percent"):
    res["gpuLoad"] = c
    break

# 5. NVIDIA Status
for p in glob.glob("/sys/bus/pci/devices/*"):
    try:
        v = open(os.path.join(p, "vendor")).read().strip()
        if v == "0x10de":
            s = os.path.join(p, "power/runtime_status")
            if os.path.isfile(s):
                res["nvidiaStatus"] = s
                break
    except Exception:
        pass

# 6. Fan inputs
fans = []
for h in glob.glob("/sys/class/hwmon/hwmon*"):
    try:
        f_list = sorted(glob.glob(os.path.join(h, "fan*_input")))
        if f_list:
            fans.extend(f_list)
    except Exception:
        pass
if fans:
    res["fanInputs"] = fans

# 7. AMD / iGPU temp
for h in glob.glob("/sys/class/hwmon/hwmon*"):
    try:
        n = open(os.path.join(h, "name")).read().strip()
        if n == "amdgpu":
            t = os.path.join(h, "temp1_input")
            if os.path.isfile(t):
                res["gpuTemp"] = t
                break
    except Exception:
        pass

print(json.dumps(res))
