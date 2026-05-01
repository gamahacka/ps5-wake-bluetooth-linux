# Waking PS5 over Bluetooth on Linux

I wanted to power on my PS5 via Bluetooth from a Linux machine, the same way a DualSense controller does it. Turns out this is possible without a controller — you just need to page the PS5 from the right Bluetooth address. The PS5 checks the source MAC of the incoming page against its list of paired controllers and powers on if it matches, before any encryption or authentication happens. This works both from rest mode and when the console is fully powered off.

The trick is documented in [pywakepsXonbt](https://github.com/FreeTHX/pywakepsXonbt) and works fine on Broadcom and Intel adapters where you can freely change the BD_ADDR. The problem I ran into is that I only had a Realtek dongle (RTL8852BU), and BD_ADDR spoofing on Realtek under Linux is basically undocumented. This repo is about how I got it working.

## What you need

- A Linux machine with a Realtek Bluetooth adapter (see compatibility table below)
- The Bluetooth MAC of your PS5 and the MAC of a DualSense paired to it
- Root access

To get the MACs: plug your DualSense into any computer via USB and read HID feature report `0x09` (20 bytes). Bytes 1-6 are the controller MAC, bytes 10-15 are the paired PS5 MAC, both little endian reversed. Tools like `dualsensectl` or `hidraw` can do this.

## How to wake the PS5

```bash
# 1. Spoof your adapter's BD_ADDR to match the paired DualSense
sudo ./set-bdaddr.sh AA:BB:CC:DD:EE:FF

# 2. Page the PS5
hciconfig hci0 up
hciconfig hci0 piscan
hcitool -i hci0 cc --role=m 11:22:33:44:55:66
```

The PS5 should power on within a few seconds. See `examples/ps5-wake.sh` for a ready to use script.

To restore your adapter's original MAC afterwards:

```bash
sudo ./set-bdaddr.sh --restore
```

## The Realtek problem and how it is solved

Changing BD_ADDR on Realtek is the hard part. `bdaddr` from bluez doesn't support Realtek. `btrtl.c` in mainline has no `set_bdaddr` callback for any RTL chip. The config blob approach was known to work on older chips (RTL8761B, RTL8723D), but for the 8852 family the kernel marks `config_needed = false` and it was unclear whether the chip would honour an override blob at all.

When `btusb` initializes a Realtek chip it sends two files via vendor opcode `0xfc20`: firmware and a config blob. The config blob is a TLV structure where each entry has an offset into chip RAM, a length, and the data to write. On Gen 4 chips (RTL8852 family) the BD_ADDR field is at offset `0x0030`, 6 bytes, little endian.

On Ubuntu, `/lib/firmware/rtl_bt/rtl8852bu_config.bin.zst` is just a symlink to a 6 byte stub with zero entries. If you replace it with a 15 byte blob containing a single BD_ADDR entry, the chip comes up with whatever MAC you specified:

```
55 AB 23 87   ← signature
0A 00         ← 10 bytes of entries follow
30 00         ← offset 0x0030
06            ← 6 bytes
XX XX XX XX XX XX  ← BD_ADDR reversed (little endian)
```

Verified on Ubuntu 24.04, kernel 6.8.0-106:

```
$ hciconfig hci0
hci0:   Type: Primary  Bus: USB
        BD Address: AA:BB:CC:DD:EE:FF  ACL MTU: 1021:6  SCO MTU: 255:12
        UP RUNNING

$ dmesg | grep "RTL: cfg_sz"
[...] Bluetooth: hci0: RTL: cfg_sz 15, total sz 58012
```

The PS5 woke up when paged from that address, confirming the new BD_ADDR is used over the air.

## Adapter compatibility

| Chip | Offset | Status |
|------|--------|--------|
| RTL8852BU | 0x0030 | confirmed |
| RTL8852AU, RTL8852CU | 0x0030 | likely works, not tested |
| RTL8822CU | 0x0030 | likely works, not tested |
| RTL8761B, RTL8723D, RTL8821C | 0x0044 | confirmed (documented elsewhere) |
| RTL8723B, RTL8761A | 0x003C | confirmed (documented elsewhere) |

## Limitations

This only wakes the PS5. Full controller emulation is blocked by Sony's HID auth challenge (reports 0xF0 / 0xF1 / 0xF2) which requires the DualSense auth IC to sign. That is a separate unsolved problem and out of scope here.

## Links

- [pywakepsXonbt](https://github.com/FreeTHX/pywakepsXonbt) — the original PS5/PS4 wake tool, works on Broadcom and Intel
- [btrtl.c](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/plain/drivers/bluetooth/btrtl.c) — kernel driver that loads the config blob
- [rtk_btusb vendor headers](https://github.com/96boards-akebi96/rtk_btusb/blob/master/rtk_btusb.h) — original Realtek struct definitions

## Notes

If you test this on RTL8852AU, RTL8852CU, or any other chip not in the list above, open an issue with `dmesg | grep RTL` output. Would be good to know what else works.

MIT license.
