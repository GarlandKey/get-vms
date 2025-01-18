#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

#=========================================================
# Check if VirtualBox (VBoxManage) is installed.
#=========================================================
if ! command -v VBoxManage &>/dev/null
then
  echo ":: [ERROR] VirtualBox is NOT installed or VBoxManage is not in your PATH."
  exit 1
else
  echo ":: [INFO] VirtualBox is installed on this system."
fi

#=========================================================
# Check if nmap is installed.
#=========================================================
if ! command -v nmap &>/dev/null
then
  echo ":: [ERROR] nmap is NOT installed or not in your PATH."
  exit 1
else
  echo ":: [INFO] nmap is installed on this system."
fi

#=========================================================
# Get name & UUID of all running virtual machines.
#=========================================================
RUNNING_VMS_OUTPUT="$(VBoxManage list runningvms)"

declare -a VM_NAMES=()
declare -a VM_UUIDS=()

while IFS= read -r line; do
  vm_name="$(echo "$line" | sed -nE 's/^"([^"]+)"[[:space:]]*\{([^}]+)\}/\1/p')"
  vm_uuid="$(echo "$line" | sed -nE 's/^"([^"]+)"[[:space:]]*\{([^}]+)\}/\2/p')"

  [ -z "$vm_name" ] && continue
  [ -z "$vm_uuid" ] && continue

  VM_NAMES+=("$vm_name")
  VM_UUIDS+=("$vm_uuid")

done <<< "$RUNNING_VMS_OUTPUT"

#=========================================================
# Get MAC address of all running virtual machines.
#=========================================================
declare -a VM_MACS=()

for i in "${!VM_UUIDS[@]}"; do
  uuid="${VM_UUIDS[$i]}"

  # e.g., Grab the first "MAC:...Bridged Interface" line
  mac_line="$(VBoxManage showvminfo --details "$uuid" \
             | grep -i "MAC" \
             | head -n1)"

  [ -z "$mac_line" ] && continue

  raw_mac="$(echo "$mac_line" | sed -nE 's/.*MAC:\s*([^,]+),.*/\1/p')"

  VM_MACS[$i]="$raw_mac"
done

#=========================================================
# Compute the local subnet (bitwise approach).
#=========================================================
DEFAULT_IFACE="$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')"
if [ -z "${DEFAULT_IFACE:-}" ]; then
  echo ":: [ERROR] Could not determine default interface."
  exit 1
fi

IP_CIDR="$(ip -4 addr show dev "$DEFAULT_IFACE" | awk '/inet / {print $2; exit}')"
if [ -z "${IP_CIDR:-}" ]; then
  echo ":: [ERROR] No IPv4 address found on interface '$DEFAULT_IFACE'."
  exit 1
fi

IP_PART="${IP_CIDR%/*}"
PREFIX="${IP_CIDR#*/}"

function ip_to_int() {
  local IFS=. ip_a ip_b ip_c ip_d
  read -r ip_a ip_b ip_c ip_d <<< "$1"
  echo $(( (ip_a << 24) + (ip_b << 16) + (ip_c << 8) + ip_d ))
}
function prefix_to_maskint() {
  local p="$1"
  echo $(( 0xFFFFFFFF << (32 - p) & 0xFFFFFFFF ))
}
function int_to_ip() {
  local ip_int="$1"
  printf "%d.%d.%d.%d" \
    $(((ip_int >> 24) & 0xFF)) \
    $(((ip_int >> 16) & 0xFF)) \
    $(((ip_int >>  8) & 0xFF)) \
    $(( ip_int        & 0xFF ))
}

ip_int="$(ip_to_int "$IP_PART")"
mask_int="$(prefix_to_maskint "$PREFIX")"
network_int="$(( ip_int & mask_int ))"
network_dotted="$(int_to_ip "$network_int")"

SUBNET="${network_dotted}/${PREFIX}"
echo ":: [INFO] Local subnet: $SUBNET"

#=========================================================
# Discover MAC/IP pairs.
#=========================================================
echo ":: [WORKING] Scanning network... Please wait."
echo

NMAP_OUTPUT="$(sudo nmap -sn "$SUBNET" 2>/dev/null)"

declare -a SCAN_MACS=()
declare -a SCAN_IPS=()
current_ip=""

while IFS= read -r line; do

  # Check if line matches "Nmap scan report for ..."
  if [[ "$line" =~ ^Nmap\ scan\ report\ for\ (.+)$ ]]; then
    full_target="${BASH_REMATCH[1]}"
    # Attempt to extract IP if in parentheses
    ip_in_paren="$(echo "$full_target" | sed -nE 's/.*\(([^)]+)\)$/\1/p')"
    if [ -n "$ip_in_paren" ]; then
      current_ip="$ip_in_paren"
    else
      current_ip="$full_target"
    fi
  fi

  # Check if line matches "MAC Address: XX:XX:XX:XX:XX:XX"
  if [[ "$line" =~ MAC\ Address:\ ([0-9A-Fa-f:]+) ]]; then
    found_mac="${BASH_REMATCH[1]}"
    if [ -n "$current_ip" ]; then
      found_mac_uc="$(echo "$found_mac" | tr '[:lower:]' '[:upper:]')"
      SCAN_MACS+=("$found_mac_uc")
      SCAN_IPS+=("$current_ip")
      current_ip=""
    fi
  fi

done <<< "$NMAP_OUTPUT"

#=========================================================
# Cross-reference VM_MACS[]
# with SCAN_MACS[] to populate VM_IPS[].
#=========================================================
declare -A MAC_TO_IPLIST=()  # Each key is a MAC, each value is a SPACE-SEPARATED list of IPs

# (A) Normalize SCAN_MACS => uppercase, no colons
for j in "${!SCAN_MACS[@]}"; do
  SCAN_MACS[j]="$(echo "${SCAN_MACS[j]}" | tr -d ':' | tr '[:lower:]' '[:upper:]')"
done

# (B) Convert VM_MACS => uppercase, no colons
for i in "${!VM_MACS[@]}"; do
  VM_MACS[$i]="$(echo "${VM_MACS[$i]}" | tr -d ':' | tr '[:lower:]' '[:upper:]')"
done

# (C) Build a dictionary of arrays, but stored as space-separated in a single string
for (( j=0; j<${#SCAN_MACS[@]}; j++ )); do
  MAC="${SCAN_MACS[j]}"
  IP="${SCAN_IPS[j]}"
  # Append IP to the existing string, or create a new one if none exists
  MAC_TO_IPLIST["$MAC"]="${MAC_TO_IPLIST[$MAC]:-} $IP"
done

# (D) Create final array VM_IPS[], initialized to "Unknown"
declare -a VM_IPS=()
for (( i=0; i<${#VM_MACS[@]}; i++ )); do
  VM_IPS[$i]="Unknown"
done

# (E) For each VM, if MAC has an IP list, assign the FIRST IP
#     then remove it from the list (so next VM with that MAC
#     gets the next IP, if any).
for i in "${!VM_MACS[@]}"; do
  vm_mac="${VM_MACS[i]}"
  # If the MAC is in the dictionary
  if [ -n "${MAC_TO_IPLIST[$vm_mac]+x}" ]; then
    # Trim leading/trailing whitespace
    mac_iplist="$(echo "${MAC_TO_IPLIST[$vm_mac]}" | xargs)"
    # Split into an array
    IFS=' ' read -r -a ip_array <<< "$mac_iplist"
    if [ ${#ip_array[@]} -gt 0 ]; then
      # Assign the first IP in the array to this VM
      VM_IPS[$i]="${ip_array[0]}"

      # Remove that first IP from the array
      ip_array=("${ip_array[@]:1}")

      # Store the updated list
      # If we leave it empty, the next VM with this MAC won't get an IP
      MAC_TO_IPLIST[$vm_mac]="${ip_array[*]}"
    fi
  fi
done

#=========================================================
# Print Final VM Info
#=========================================================
for i in "${!VM_NAMES[@]}"; do

  echo "    NAME:  ${VM_NAMES[i]}"
  echo "    UUID:  ${VM_UUIDS[i]}"
  echo "    MAC:   ${VM_MACS[i]}"
  echo "    IP:    ${VM_IPS[i]}"
  echo
done

echo ":: [INFO] Done."
