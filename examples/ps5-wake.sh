#!/bin/bash
# Wake a PS5 from rest mode by paging it from a spoofed paired-DualSense
# BD_ADDR. Demonstrates the practical use case of the BD_ADDR override
# in the parent repo.
#
# Step 0 (once, on a different machine with the DualSense plugged in via USB):
#   Read DualSense's BD_ADDR + paired-PS5 BD_ADDR via USB feature report 0x09
#   (use dualsensectl, hidraw, or any tool that decodes the 20-byte report).
#
# Edit the two MACs below, then run as root:
#   sudo ./ps5-wake.sh

DUALSENSE_BD="AA:BB:CC:DD:EE:FF"    # the controller paired with your PS5
PS5_BT="11:22:33:44:55:66"          # PS5's Bluetooth MAC (NOT its Wi-Fi MAC)

set -eu

# Spoof BD_ADDR (calls into the parent repo's set-bdaddr.sh)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
"$SCRIPT_DIR/../set-bdaddr.sh" "$DUALSENSE_BD"

echo "[*] Paging PS5 at $PS5_BT ..."
hciconfig hci0 up
hciconfig hci0 piscan
timeout 8 hcitool -i hci0 cc --role=m "$PS5_BT" >/dev/null 2>&1 || true
sleep 2
hcitool -i hci0 con

cat <<'EOF'
[+] Done. Check the PS5 — it should be powering up.

  Note: this only WAKES the PS5. Full controller emulation past wake
  would require Sony's HID-layer authentication challenge, which is
  not implemented here and not solvable without either:
    (a) a paired DualSense's link key (not extractable), or
    (b) the Sony auth-IC's private key (not public), or
    (c) a USB-attached real DualSense acting as auth-oracle proxy
        (architecturally clear but not yet implemented end-to-end —
         see jfedor2/paaas for the closest existing piece).
EOF
