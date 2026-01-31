# SFP EEPROM Read/Write Tool

Tool for reading/writing SFP EEPROM via CH341 USB-I2C adapter. These are sold in China ether with or without case for <80$. They apparently have no microcontroller or firmware, which helps us here. 
Original software was encrypted, so I could not run it in trusted environment. 
The only missing feature of original software is database of vendor-specific passwords, but for OEM SFP modules it should not be needed.

## Prerequisites

- `i2c-tools` package
- `i2c-ch341-usb` kernel module (installation below)

## Usage

```
Usage: sfp.sh [OPTIONS] COMMAND [FILE]

Commands:
  --decode, -d          Decode and display SFP module info
  --read, -r FILE       Read SFP EEPROM to binary file
  --write, -w FILE      Write binary file to SFP EEPROM

Options:
  --bus, -b BUS         I2C bus number (default: autodetect CH341)
  --help, -h            Show this help
```

## Examples

### Decode SFP Info

```bash
./sfp.sh --decode
```

Output:
```
=== SFP Module Info (bus 17) ===
Type:        SFP
Connector:   Copper
Vendor:      OEM
Part Number: SFP-25G-CU1M
Serial:      2508220101
Date:        251118
Length:      1m (copper)
```

### Read EEPROM to File

```bash
./sfp.sh --read backup.bin
```

### Write File to EEPROM

```bash
./sfp.sh --write modified.bin
```

### Override Bus Number

```bash
./sfp.sh -b 17 --decode
```

## Low-Level Commands

Direct i2c-tools usage if needed:

```bash
# Find CH341 bus
grep -l ch341 /sys/bus/i2c/devices/i2c-*/name

# Scan for SFP
sudo i2cdetect -y 17

# Dump EEPROM
sudo i2cdump -y 17 0x50 b

# Read single byte
sudo i2cget -y 17 0x50 0x14

# Write single byte
sudo i2cset -y 17 0x50 0x60 0xAB
```

## Field Reference (SFF-8472 A0 Page)

| Offset | Length | Field |
|--------|--------|-------|
| 0x00 | 1 | Identifier (0x03=SFP) |
| 0x01 | 1 | Extended Identifier |
| 0x02 | 1 | Connector Type |
| 0x03-0x0A | 8 | Transceiver Compliance |
| 0x0B | 1 | Encoding |
| 0x0C | 1 | Bit Rate (units of 100 Mbps) |
| 0x0E | 1 | Length (SMF km) |
| 0x0F | 1 | Length (SMF 100m) |
| 0x10 | 1 | Length (OM2 10m) |
| 0x11 | 1 | Length (OM1 10m) |
| 0x12 | 1 | Length (Copper 1m) |
| 0x13 | 1 | Length (OM3 10m) |
| 0x14-0x23 | 16 | Vendor Name |
| 0x24 | 1 | Transceiver Code |
| 0x25-0x27 | 3 | Vendor OUI |
| 0x28-0x37 | 16 | Vendor Part Number |
| 0x38-0x3B | 4 | Vendor Revision |
| 0x3C-0x3D | 2 | Wavelength |
| 0x3F | 1 | CC_BASE (checksum 0x00-0x3E) |
| 0x44-0x53 | 16 | Vendor Serial Number |
| 0x54-0x5B | 8 | Date Code (YYMMDD) |
| 0x5C | 1 | Diagnostic Monitoring Type |
| 0x5D | 1 | Enhanced Options |
| 0x5E | 1 | SFF-8472 Compliance |
| 0x5F | 1 | CC_EXT (checksum 0x40-0x5E) |
| 0x60-0x7F | 32 | Vendor Specific |
| 0x80-0xFF | 128 | Vendor Specific (upper half) |

## I2C Addresses

| Address | Page | Content |
|---------|------|---------|
| 0x50 | A0 | Base ID, vendor info, serial |
| 0x51 | A2 | Diagnostics (DOM) - empty on passive cables |

# i2c-ch341-usb Driver Installation for SFP Access

This guide covers building, signing, and installing the i2c-ch341-usb driver on systems with Secure Boot enabled.

## Prerequisites

```bash
sudo apt install build-essential linux-headers-$(uname -r) i2c-tools mokutil
```

## 1. Create MOK Signing Key

Generate a Machine Owner Key for signing out-of-tree modules:

```bash
mkdir -p ~/mok-keys && cd ~/mok-keys

openssl req -new -x509 -newkey rsa:2048 -keyout MOK.priv -outform DER -out MOK.der -days 36500 -subj "/CN=SFP Module Signing Key" -nodes

# Enroll the key (requires reboot)
sudo mokutil --import MOK.der
# Set a one-time password when prompted

# Reboot and complete enrollment in MOK Manager
sudo reboot
```

After reboot, select "Enroll MOK" → "Continue" → "Yes" → enter password → reboot.

Verify enrollment:
```bash
mokutil --list-enrolled | grep "SFP Module"
```

## 2. Build the Driver

```bash
git clone https://github.com/allanbian1017/i2c-ch341-usb.git
cd i2c-ch341-usb
make
```

## 3. Sign the Module

```bash
/usr/src/linux-headers-$(uname -r)/scripts/sign-file sha256 \
    ~/mok-keys/MOK.priv \
    ~/mok-keys/MOK.der \
    i2c-ch341-usb.ko

# Verify signature
modinfo i2c-ch341-usb.ko | grep signer
```

## 4. Install the Module

```bash
# Copy to kernel modules directory
sudo cp i2c-ch341-usb.ko /lib/modules/$(uname -r)/kernel/drivers/i2c/busses/

# Update module database
sudo depmod -a

# Blacklist competing SPI driver
echo "blacklist spi-ch341" | sudo tee /etc/modprobe.d/ch341-i2c.conf

# Enable autoload at boot
echo "i2c-ch341-usb" | sudo tee /etc/modules-load.d/ch341-i2c.conf
```

## 5. Load and Test

```bash
# Load the module
sudo modprobe i2c-ch341-usb

# Find the I2C bus number
grep -l ch341 /sys/bus/i2c/devices/i2c-*/name
# Example output: /sys/bus/i2c/devices/i2c-17/name

# Scan for SFP (replace 17 with your bus number)
sudo i2cdetect -y 17
```

Expected output for SFP:
```
     0  1  2  3  4  5  6  7  8  9  a  b  c  d  e  f
...
50: 50 51 -- -- -- -- -- -- -- -- -- -- -- -- -- --
```

## 6. Read SFP EEPROM

```bash
# Read base ID (A0 page)
sudo i2cdump -y 17 0x50 b

# Read specific fields
sudo i2cget -y 17 0x50 0x14  # Vendor name start
```

## Kernel Updates

After kernel updates, rebuild and reinstall:

```bash
cd ~/i2c-ch341-usb
make clean && make

/usr/src/linux-headers-$(uname -r)/scripts/sign-file sha256 \
    ~/mok-keys/MOK.priv ~/mok-keys/MOK.der i2c-ch341-usb.ko

sudo cp i2c-ch341-usb.ko /lib/modules/$(uname -r)/kernel/drivers/i2c/busses/
sudo depmod -a
```

## Troubleshooting

**Module won't load (key rejected):**
- Verify MOK is enrolled: `mokutil --list-enrolled`
- Re-sign the module with correct key paths

**No I2C adapter appears:**
- Check if spi-ch341 grabbed the device: `lsusb -t | grep ch341`
- Manually unbind: `echo "X-Y:1.0" | sudo tee /sys/bus/usb/drivers/spi-ch341/unbind`

**SFP not detected at 0x50:**
- Verify physical connection
- Check adapter wiring (SDA/SCL to correct SFP pins)
