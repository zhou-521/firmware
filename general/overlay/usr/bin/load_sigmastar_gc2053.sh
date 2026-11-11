#!/bin/sh
# ============================================================
# load_sigmastar_gc2053.sh   Rev1.1
# 模块加载脚本（OpenIPC infinity6c / SSC377D，GC2053 为外置 .ko）
# 安装位置：/usr/bin/load_sigmastar_gc2053.sh（buildroot overlay 打包）
#
# 顺序铁律：① 星宸私有 ISP/MIPI 底层驱动 → ② sensor_gc2053_mipi.ko（必须最后）
#           绝不先加载 sensor 再加载底层驱动，否则 probe 失败。
# 红线：GC2053 不换型号；2-Lane MIPI；MCLK 24MHz；不使用 Linux Media/V4L2。
#
# ★ Rev1.1 修订依据（官方 lite 板端实测）：
#   - 官方 /lib/modules/5.10.61/sigmastar/ 里是【单一 mi.ko(2.48MB) +
#     sensor_config.ko + 12 个 sensor_*.ko】，并非拆分的 mi_sys/mi_common/...；
#     自建固件产物形态尚未确定，因此本脚本自动兼容两种形态。
#   - 官方 /usr/bin/load_sigmastar 的 insert_ko 实际是：
#       insmod mi.ko drv_codec40_common.fw_load_path=/etc/firmware/chagall.bin
#       echo isproot /etc/firmware > /dev/ispmid
#     这两步原脚本缺失，现补齐。
#   - 官方 S70vendor 会先执行 load_sigmastar -i 加载 mi.ko；本脚本检测到
#     已加载就跳过，避免重复 insmod 冲突。
#   - 官方 set_sensor 的 case 列表【不含 gc2053】，会打印 UNSUPPORTED；
#     只要 U-Boot ENV 里有 sensor=gc2053，它就不会走 autodetect 覆写 sensor，
#     GC2053 外置 ko 仍由本脚本（经 S90sensor）独立加载。
# ============================================================

KMOD=/lib/modules/5.10.61/sigmastar
FW=/etc/firmware
GC2053_KO=${KMOD}/sensor_gc2053_mipi.ko
MI_ONE=${KMOD}/mi.ko
MI_SPLIT="mi_sys mi_common mi_isp mi_vif mi_sensor"
# 可选：驱动 insmod 参数。默认留空，避免传入未支持的参数导致 insmod 失败。
# 若自建固件的 sensor_gc2053_mipi.ko 需要 chmap / lane_num，先 modinfo 确认后
# 再按需传入，例如：GC2053_KO_ARGS="chmap=1 lane_num=2" S90sensor start
GC2053_KO_ARGS=${GC2053_KO_ARGS:-}

# ---------- 厂商底层驱动是否已加载（两种形态都有 mi_common）----------
vendor_loaded() {
    [ -d /sys/module/mi_common ] && return 0
    grep -qE '^(mi|mi_common|mi_sys) ' /proc/modules 2>/dev/null && return 0
    return 1
}

# ---------- ① 加载星宸私有 ISP/MIPI 底层驱动 ----------
load_vendor() {
    if vendor_loaded; then
        echo "[GC2053] 厂商 ISP/MIPI 驱动已加载（S70vendor / load_sigmastar 已完成），跳过"
        return 0
    fi

    if [ -f "$MI_ONE" ]; then
        echo "[GC2053] 形态 A：单一 mi.ko（官方 lite 实测形态）"
        insmod "$MI_ONE" drv_codec40_common.fw_load_path=${FW}/chagall.bin \
            || echo "  WARN: insmod mi.ko 失败（继续，稍后请看 Unknown symbol）"
        if [ -e /dev/ispmid ]; then
            echo isproot ${FW} > /dev/ispmid || echo "  WARN: isproot 写入失败"
        else
            echo "  WARN: /dev/ispmid 不存在，ISP root 未初始化（检查 mi.ko 是否加载成功）"
        fi
    else
        echo "[GC2053] 形态 B：拆分 mi_*.ko"
        for n in ${MI_SPLIT}; do
            m="${KMOD}/${n}.ko"
            if [ -f "$m" ]; then
                insmod "$m" || echo "  WARN: insmod $m 失败（可能已内置）"
            else
                echo "  WARN: 缺少 $m"
            fi
        done
    fi

    if vendor_loaded; then
        echo "[GC2053] 厂商 ISP/MIPI 驱动就绪"
        return 0
    fi
    echo "  ERROR: 厂商驱动未就绪；sensor ko 大概率会 Unknown symbol"
    return 1
}

# ---------- ② 最后加载 GC2053 外置 sensor 模块 ----------
load_gc2053() {
    echo "[GC2053] 加载外置 sensor_gc2053_mipi.ko ..."
    if [ ! -f "$GC2053_KO" ]; then
        echo "  ERROR: 找不到 $GC2053_KO（overlay 未打包 / 内核版本目录不符）"
        return 1
    fi
    # restart 幂等：已加载则先卸载
    if grep -q '^sensor_gc2053_mipi ' /proc/modules 2>/dev/null; then
        rmmod sensor_gc2053_mipi 2>/dev/null || true
    fi
    insmod "$GC2053_KO" ${GC2053_KO_ARGS} \
        || { echo "  ERROR: GC2053 模块加载失败（查 dmesg / vermagic / 参数）"; return 1; }

    # 通道注册（mipi0/sr0）；官方镜像可能没有 sensor_tool，缺失时静默跳过
    if command -v sensor_tool >/dev/null 2>&1; then
        sensor_tool -n gc2053 -c 0 2>/dev/null || true
    fi
    echo "[GC2053] 加载完成（dmesg | grep -i gc2053 应出现 SnrName）"
    return 0
}

# ---------- 卸载（逆序，兼容两种形态）----------
unload_all() {
    echo "[GC2053] 卸载 ..."
    rmmod sensor_gc2053_mipi 2>/dev/null || true
    if [ -f "$MI_ONE" ] || grep -q '^mi ' /proc/modules 2>/dev/null; then
        # 形态 A 的 mi.ko 可能是 S70vendor 加载的，卸载失败属正常（仍被占用）
        rmmod mi 2>/dev/null || echo "  (mi 仍被占用，跳过)"
    else
        for n in mi_sensor mi_vif mi_isp mi_common mi_sys; do
            rmmod "$n" 2>/dev/null || true
        done
    fi
    echo "[GC2053] 卸载完成"
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
        echo "用法: $0 {start|stop|restart}"
        exit 1
        ;;
esac

# ============================================================
# 手动调试命令（两种形态择一，顺序不可颠倒）
# 形态 A（官方 lite / 单一 mi.ko）：
#   insmod /lib/modules/5.10.61/sigmastar/mi.ko \
#       drv_codec40_common.fw_load_path=/etc/firmware/chagall.bin
#   echo isproot /etc/firmware > /dev/ispmid
#   insmod /lib/modules/5.10.61/sigmastar/sensor_gc2053_mipi.ko
# 形态 B（拆分模块）：
#   insmod mi_sys.ko; insmod mi_common.ko; insmod mi_isp.ko
#   insmod mi_vif.ko; insmod mi_sensor.ko
#   insmod sensor_gc2053_mipi.ko
# 检查：
#   lsmod | grep -E 'mi|gc2053'
#   dmesg | grep -i gc2053
#   i2cdetect -y 0     # 驱动上电后才会出现 0x37；未加载时三条总线全空属正常
# ============================================================
