#!/bin/bash
# Override Bluetooth BD_ADDR on Realtek RTL8852-class (and other Gen-3/4)
# chips by writing a crafted /lib/firmware/rtl_bt/<chip>_config.bin and
# reloading the btusb driver.
#
# Usage:
#   sudo ./set-bdaddr.sh AA:BB:CC:DD:EE:FF
#   sudo ./set-bdaddr.sh --restore
#
# Requires: bluez-tools (hciconfig), kmod (rmmod/modprobe), root.
#
# This is documented to work on:
#   RTL8852BU (verified)
#   RTL8852AU, RTL8852CU, RTL8822CU (Gen-4, untested but same offset 0x0030)
#   RTL8761B, RTL8723D, RTL8821C   (Gen-3, offset 0x0044)
#   RTL8723B, RTL8761A             (Gen-1/2, offset 0x003C)

set -e

FW_DIR=/lib/firmware/rtl_bt
SIGNATURE='\x55\xAB\x23\x87'

if [ "$EUID" -ne 0 ]; then
    echo "Run as root (sudo)." >&2
    exit 1
fi

# Detect the running Realtek BT chip via dmesg / sysfs to pick the right
# config filename. We look at the latest hci0 init.
detect_chip() {
    if [ ! -e /sys/class/bluetooth/hci0 ]; then
        echo "No hci0 — is btusb loaded and a Realtek device attached?" >&2
        exit 1
    fi
    # lmp_subver from hciconfig -a → maps to chip family
    local subver
    subver=$(hciconfig -a hci0 2>/dev/null | awk '/Subversion:/ {print $2; exit}')
    case "${subver,,}" in
        0xb20f) echo rtl8852bu ;;
        0x870b) echo rtl8761b ;;
        0x8822) echo rtl8822cu ;;
        0xc822) echo rtl8852cu ;;
        0xa852) echo rtl8852au ;;
        0xb723) echo rtl8723d ;;
        *)
            # Fall back to dmesg's last "loading rtl_bt/..._fw.bin" hint.
            local hint
            hint=$(dmesg | awk '/RTL: loading rtl_bt\/.+_fw\.bin/ {gsub(/.*rtl_bt\//,""); gsub(/_fw\.bin.*/,""); last=$0} END{print last}')
            if [ -n "$hint" ]; then echo "$hint"; else
                echo "Unrecognised lmp_subver=$subver. Edit script to add it." >&2
                exit 1
            fi
            ;;
    esac
}

# Pick the BD_ADDR offset based on the chip family.
detect_offset() {
    case "$1" in
        rtl8852*|rtl8822c*) echo 0x0030 ;;     # Gen-4
        rtl8761b*|rtl8723d*|rtl8821c*) echo 0x0044 ;;  # Gen-3
        rtl8723b*|rtl8761a*) echo 0x003C ;;    # Gen-1/2
        *) echo 0x0030 ;;
    esac
}

CHIP=$(detect_chip)
OFFSET=$(detect_offset "$CHIP")
CFG_BIN=$FW_DIR/${CHIP}_config.bin
CFG_ZST=$FW_DIR/${CHIP}_config.bin.zst
BACKUP_ZST=$FW_DIR/${CHIP}_config.bin.zst.bak

restore() {
    if [ -f "$BACKUP_ZST" ] || [ -L "$BACKUP_ZST" ]; then
        rm -f "$CFG_BIN" "$CFG_ZST"
        mv "$BACKUP_ZST" "$CFG_ZST"
        echo "Restored original $CFG_ZST"
    else
        echo "No backup found at $BACKUP_ZST. If you never ran this script before," >&2
        echo "reinstall linux-firmware to recover the symlinked stub." >&2
        exit 1
    fi
    reload_btusb
}

reload_btusb() {
    echo "[*] Reloading btusb..."
    rmmod btusb 2>/dev/null || true
    sleep 1
    modprobe btusb
    sleep 3
    hciconfig hci0 up >/dev/null 2>&1 || true
    sleep 1
    echo "[*] hci0 BD_ADDR now: $(hciconfig hci0 | awk '/BD Address/{print $3}')"
}

if [ "$1" = "--restore" ] || [ "$1" = "-r" ]; then
    restore
    exit 0
fi

NEW_BDADDR="$1"
if [[ ! "$NEW_BDADDR" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]; then
    echo "Usage: $0 AA:BB:CC:DD:EE:FF | --restore" >&2
    exit 2
fi

# Convert MAC to little-endian byte sequence for printf
LE_BYTES=$(echo "$NEW_BDADDR" | tr ':' '\n' | tac | awk '{printf "\\x%s", $0}')

echo "[*] Detected chip:  $CHIP"
echo "[*] BD_ADDR offset: $OFFSET (Gen-$([ "$OFFSET" = "0x0030" ] && echo 4 || ([ "$OFFSET" = "0x0044" ] && echo 3 || echo "1/2")))"
echo "[*] Setting BD_ADDR to $NEW_BDADDR (LE bytes follow)"

# Backup existing .zst (only on first run)
if [ -e "$CFG_ZST" ] && [ ! -e "$BACKUP_ZST" ]; then
    cp -P "$CFG_ZST" "$BACKUP_ZST"
    echo "[*] Backed up original to $BACKUP_ZST"
fi

# Build 15-byte blob:
#   sig(4) | data_len(2 LE) | offset(2 LE) | len(1) | bd_addr(6 LE)
OFF_LO=$(printf '\\x%02x' $((OFFSET & 0xFF)))
OFF_HI=$(printf '\\x%02x' $(((OFFSET >> 8) & 0xFF)))
rm -f "$CFG_BIN" "$CFG_ZST"
printf "${SIGNATURE}\x0A\x00${OFF_LO}${OFF_HI}\x06${LE_BYTES}" > "$CFG_BIN"
chmod 644 "$CFG_BIN"

echo "[*] Wrote $CFG_BIN ($(wc -c < "$CFG_BIN") bytes):"
xxd "$CFG_BIN"

reload_btusb

GOT=$(hciconfig hci0 | awk '/BD Address/{print $3}')
if [ "${GOT,,}" = "${NEW_BDADDR,,}" ]; then
    echo "[+] OK — BD_ADDR is now $GOT"
    exit 0
else
    echo "[!] FAIL — chip reports $GOT, expected $NEW_BDADDR" >&2
    echo "    Check 'dmesg | grep RTL' for clues. The chip may not honour" >&2
    echo "    the override (some Realtek generations have authoritative EFUSE)." >&2
    exit 3
fi
