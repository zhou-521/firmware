#!/bin/sh
# load_sigmastar_gc2053.sh  Rev1.2 (shipping, ASCII log)
# OpenIPC infinity6c / SSC377D + GC2053 (external ko)
# Order: vendor ISP/MIPI driver first, sensor_gc2053_mipi.ko last.
# GC2053 sits on sr0 / sensor pad 0 -> chmap = 2^0 = 1, 2-lane MIPI.
# chmap=4 would bind pad2: the sensor still registers, but majestic only
# queries pad0 and fails with "Cannot query sensor index".
KMOD=/lib/modules/5.10.61/sigmastar
FW=/etc/firmware
GC2053_KO=${KMOD}/sensor_gc2053_mipi.ko
MI_ONE=${KMOD}/mi.ko
MI_SPLIT="mi_sys mi_common mi_isp mi_vif mi_sensor"
GC2053_KO_ARGS=${GC2053_KO_ARGS:-chmap=1 lane_num=2}

vendor_loaded() {
    [ -d /sys/module/mi_common ] && return 0
    grep -qE '^(mi|mi_common|mi_sys) ' /proc/modules 2>/dev/null && return 0
    return 1
}

load_vendor() {
    if vendor_loaded; then
        echo "[GC2053] vendor ISP/MIPI already loaded (S70vendor), skip"
        return 0
    fi

    if [ -f "$MI_ONE" ]; then
        echo "[GC2053] form A: single mi.ko"
        insmod "$MI_ONE" drv_codec40_common.fw_load_path=${FW}/chagall.bin \
            || echo "  WARN: insmod mi.ko failed"
        if [ -e /dev/ispmid ]; then
            echo isproot ${FW} > /dev/ispmid || echo "  WARN: isproot write failed"
        else
            echo "  WARN: /dev/ispmid missing, ISP root not initialized"
        fi
    else
        echo "[GC2053] form B: split mi_*.ko"
        for n in ${MI_SPLIT}; do
            m="${KMOD}/${n}.ko"
            if [ -f "$m" ]; then
                insmod "$m" || echo "  WARN: insmod $m failed"
            else
                echo "  WARN: missing $m"
            fi
        done
    fi

    if vendor_loaded; then
        echo "[GC2053] vendor ISP/MIPI ready"
        return 0
    fi
    echo "  ERROR: vendor driver not ready, sensor ko will hit Unknown symbol"
    return 1
}

load_gc2053() {
    echo "[GC2053] loading sensor_gc2053_mipi.ko args='${GC2053_KO_ARGS}'"
    if [ ! -f "$GC2053_KO" ]; then
        echo "  ERROR: $GC2053_KO not found"
        return 1
    fi
    if grep -q '^sensor_gc2053_mipi ' /proc/modules 2>/dev/null; then
        rmmod sensor_gc2053_mipi 2>/dev/null || true
    fi
    insmod "$GC2053_KO" ${GC2053_KO_ARGS} \
        || { echo "  ERROR: gc2053 module load failed (see dmesg)"; return 1; }

    if command -v sensor_tool >/dev/null 2>&1; then
        sensor_tool -n gc2053 -c 0 2>/dev/null || true
    fi
    echo "[GC2053] loaded"
    return 0
}

# mi.ko is loaded by S70vendor at boot. NEVER rmmod it here:
# a half-initialized mi leaves the module in a broken state, later insmod
# of any sensor gets Unknown symbol and shutdown callbacks panic.
unload_all() {
    echo "[GC2053] unload ..."
    rmmod sensor_gc2053_mipi 2>/dev/null || true
    if [ -f "$MI_ONE" ] || grep -q '^mi ' /proc/modules 2>/dev/null; then
        echo "  (mi kept, managed by S70vendor)"
    else
        for n in mi_sensor mi_vif mi_isp mi_common mi_sys; do
            rmmod "$n" 2>/dev/null || true
        done
    fi
    echo "[GC2053] unload done"
}

case "$1" in
    start|"")
        load_vendor
        load_gc2053
        ;;
    stop)
        unload_all
        ;;
    restart)
        unload_all
        load_vendor
        load_gc2053
        ;;
    *)
        echo "usage: $0 {start|stop|restart}"
        exit 1
        ;;
esac
