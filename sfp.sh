#!/bin/bash
# SFP EEPROM tool for CH341 I2C adapter

set -e

find_bus() {
    for d in /sys/bus/i2c/devices/i2c-*/name; do
        grep -q ch341 "$d" 2>/dev/null && echo "$d" | sed 's|.*/i2c-\([0-9]*\)/.*|\1|' && return
    done
}

read_str() {
    local bus=$1 start=$2 len=$3
    for i in $(seq $start $((start + len - 1))); do
        printf "\\x$(sudo i2cget -y $bus 0x50 $i | sed 's/0x//')"
    done
}

do_decode() {
    local bus=$1
    echo "=== SFP Module Info (bus $bus) ==="

    id=$(sudo i2cget -y $bus 0x50 0x00 2>/dev/null) || { echo "No SFP detected"; exit 1; }
    case $id in 0x03) type="SFP";; 0x0d) type="QSFP+";; 0x11) type="QSFP28";; *) type="Unknown ($id)";; esac

    cn=$(sudo i2cget -y $bus 0x50 0x02)
    case $cn in
        0x01) conn="SC";;
        0x07) conn="LC";;
        0x0b) conn="Optical Pigtail";;
        0x21) conn="Copper Pigtail";;
        0x22) conn="RJ45";;
        0x23) conn="No Separable Connector";;
        *) conn="Unknown ($cn)";;
    esac

    # Cable technology (byte 8)
    cable=$(sudo i2cget -y $bus 0x50 0x08)
    case $cable in
        0x00) cable_type="";;
        0x04) cable_type="Passive Copper";;
        0x08) cable_type="Active Copper";;
        *) cable_type="($cable)";;
    esac

    # Bit rate
    br=$(sudo i2cget -y $bus 0x50 0x0c)
    if [ "$br" = "0xff" ]; then
        br_max=$(sudo i2cget -y $bus 0x50 0x42)
        bitrate="$((br_max * 250)) Mbps"
    else
        bitrate="$((br * 100)) Mbps"
    fi

    # Encoding
    enc=$(sudo i2cget -y $bus 0x50 0x0b)
    case $enc in
        0x00) encoding="Unspecified";;
        0x01) encoding="8B/10B";;
        0x02) encoding="4B/5B";;
        0x03) encoding="NRZ";;
        0x06) encoding="PAM4";;
        *) encoding="($enc)";;
    esac

    # Lengths
    len_smf_km=$(sudo i2cget -y $bus 0x50 0x0e)
    len_smf=$(sudo i2cget -y $bus 0x50 0x0f)
    len_om2=$(sudo i2cget -y $bus 0x50 0x10)
    len_om1=$(sudo i2cget -y $bus 0x50 0x11)
    len_cu=$(sudo i2cget -y $bus 0x50 0x12)
    len_om3=$(sudo i2cget -y $bus 0x50 0x13)

    # Vendor OUI
    oui_raw="$(sudo i2cget -y $bus 0x50 0x25)$(sudo i2cget -y $bus 0x50 0x26)$(sudo i2cget -y $bus 0x50 0x27)"
    if [ "$oui_raw" = "0x000x000x00" ]; then
        oui="N/A"
    else
        oui=$(printf "%02X:%02X:%02X" $(sudo i2cget -y $bus 0x50 0x25) $(sudo i2cget -y $bus 0x50 0x26) $(sudo i2cget -y $bus 0x50 0x27))
    fi

    # Revision
    rev=$(read_str $bus 0x38 4 | tr -d ' ')

    # Print basic info
    echo "Type:        $type"
    echo "Connector:   $conn"
    [ -n "$cable_type" ] && echo "Cable:       $cable_type"
    echo "Bit Rate:    $bitrate"
    echo "Encoding:    $encoding"
    echo ""
    echo "Vendor:      $(read_str $bus 0x14 16 | tr -d ' ')"
    echo "OUI:         $oui"
    echo "Part Number: $(read_str $bus 0x28 16 | tr -d ' ')"
    echo "Revision:    $rev"
    echo "Serial:      $(read_str $bus 0x44 16 | tr -d ' ')"
    echo "Date Code:   $(read_str $bus 0x54 8)"

    # Print lengths (only non-zero)
    echo ""
    echo "Length:"
    [ "$len_smf_km" != "0x00" ] && echo "  SMF:    $((len_smf_km)) km"
    [ "$len_smf" != "0x00" ] && echo "  SMF:    $((len_smf * 100)) m"
    [ "$len_om3" != "0x00" ] && echo "  OM3:    $((len_om3 * 10)) m"
    [ "$len_om2" != "0x00" ] && echo "  OM2:    $((len_om2 * 10)) m"
    [ "$len_om1" != "0x00" ] && echo "  OM1:    $((len_om1 * 10)) m"
    [ "$len_cu" != "0x00" ] && echo "  Copper: $((len_cu)) m"

    # Vendor specific (if contains printable text)
    vs1=$(read_str $bus 0x80 32 | tr -cd '[:alnum:]-_.' | head -c 32)
    vs2=$(read_str $bus 0xc0 22 | tr -cd '[:alnum:]-_.' | head -c 22)
    if [ -n "$vs1" ] || [ -n "$vs2" ]; then
        echo ""
        echo "Vendor Specific:"
        [ -n "$vs1" ] && echo "  $vs1"
        [ -n "$vs2" ] && echo "  $vs2"
    fi
}

do_read() {
    local bus=$1 output=$2
    echo "Reading SFP A0 page from bus $bus to $output..."
    sudo i2cdump -y -r 0x00-0xff $bus 0x50 b | \
        grep -E "^[0-9a-f]" | cut -c5-52 | tr -d ' ' | xxd -r -p > "$output"

    if [ -s "$output" ]; then
        echo "Success: $(wc -c < "$output") bytes written to $output"
    else
        echo "Failed to read SFP"
        exit 1
    fi
}

do_write() {
    local bus=$1 input=$2

    if [ ! -f "$input" ]; then
        echo "Error: File $input not found"
        exit 1
    fi

    local size=$(wc -c < "$input")
    if [ "$size" -ne 256 ]; then
        echo "Warning: File is $size bytes (expected 256)"
    fi

    echo "Writing $input to SFP A0 page on bus $bus..."
    echo "Press Ctrl+C within 3 seconds to cancel..."
    sleep 3

    for offset in $(seq 0 $((size - 1))); do
        byte=$(xxd -p -s $offset -l 1 "$input")
        sudo i2cset -y $bus 0x50 $offset 0x$byte
        sleep 0.005
        printf "\rWriting byte %d/%d" $((offset + 1)) $size
    done
    echo ""
    echo "Done."
}

usage() {
    cat <<EOF
Usage: $(basename $0) [OPTIONS] COMMAND [FILE]

SFP EEPROM tool for CH341 I2C adapter

Commands:
  --decode, -d          Decode and display SFP module info
  --read, -r FILE       Read SFP EEPROM to binary file
  --write, -w FILE      Write binary file to SFP EEPROM

Options:
  --bus, -b BUS         I2C bus number (default: autodetect CH341)
  --help, -h            Show this help

Examples:
  $(basename $0) --decode
  $(basename $0) --read sfp_backup.bin
  $(basename $0) --write sfp_new.bin
  $(basename $0) -b 17 --decode
EOF
    exit 0
}

# Parse arguments
BUS=""
CMD=""
FILE=""

while [ $# -gt 0 ]; do
    case $1 in
        --decode|-d) CMD="decode"; shift ;;
        --read|-r) CMD="read"; FILE="$2"; shift 2 ;;
        --write|-w) CMD="write"; FILE="$2"; shift 2 ;;
        --bus|-b) BUS="$2"; shift 2 ;;
        --help|-h) usage ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

[ -z "$CMD" ] && usage

# Autodetect bus if not specified
if [ -z "$BUS" ]; then
    BUS=$(find_bus)
    [ -z "$BUS" ] && { echo "Error: No CH341 I2C adapter found"; exit 1; }
fi

# Execute command
case $CMD in
    decode) do_decode $BUS ;;
    read) [ -z "$FILE" ] && { echo "Error: No output file specified"; exit 1; }; do_read $BUS "$FILE" ;;
    write) [ -z "$FILE" ] && { echo "Error: No input file specified"; exit 1; }; do_write $BUS "$FILE" ;;
esac
