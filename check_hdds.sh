#!/bin/bash
#
# MIT License
#
# Copyright (c) 2025 Alexander Zinchenko <alexander@zinchenko.com>
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
#
# ------------------------------------------------------------------------------
# This script checks all detected HDDs and displays key S.M.A.R.T. parameters
# in a compact table format with fixed column widths. It extracts disk model,
# serial number, size (from "User Capacity:" or "Total NVM Capacity:"), WWN (as
# reported by smartctl), overall health status, key S.M.A.R.T. values (R, P, U, S),
# head parking count (Load_Cycle_Count), work time (from Power_On_Hours) using a space
# delimiter between days and hours, temperature, and an advisory message.
#
# For drives that are connected via USB bridges, the script automatically uses the
# "-d sat" option. The initial disk scan is performed using both "-d sat" and "-d nvme"
# so that proper device types are detected.
#
# Requires smartmontools (smartctl)
#
# Column Explanations:
# Disk   : Device file for the HDD (e.g., /dev/sda)
# Model  : The disk model name
# Serial : The disk serial number
# Size   : Disk capacity (e.g., "1.00 TB")
# WWN    : The disk's WWN as reported by smartctl (e.g., "5 000cca 264d0e0b2")
# Health : Overall SMART health status (e.g., PASSED)
# R      : Reallocated Sector Count (number of sectors remapped)
# P      : Current Pending Sector Count (sectors pending reallocation)
# U      : Offline Uncorrectable Sector Count (sectors that cannot be corrected)
# S      : Spin Retry Count (indicates spin-up issues)
# HP     : Head Parking Count (Load_Cycle_Count)
# Work   : Calculated work time from Power_On_Hours (days and hours)
# Temp   : Temperature in Celsius (from Temperature_Celsius attribute)
# Advice : Advisory message ("FAIL" if any key parameter is non-zero, otherwise "OK")
# ------------------------------------------------------------------------------

echo "Scanning for HDDs..."

# Perform two scans: one for SATA (including USB bridges) and one for NVMe devices.
# Then merge the results (unique device paths) for further processing.
disks=$( { smartctl --scan -d sat; smartctl --scan -d nvme; } | sort -u | awk '{print $1}' )
if [ -z "$disks" ]; then
  echo "No disks found by smartctl."
  exit 0
fi

# Define fixed column widths:
# Disk (10), Model (22), Serial (20), Size (10), WWN (20), Health (8),
# R (4), P (4), U (4), S (4), HP (8), Work (12), Temp (6), Advice (8)
header_fmt="%-10s %-22s %-20s %-10s %-20s %-8s %-4s %-4s %-4s %-4s %-8s %-12s %-6s %-8s\n"
row_fmt="%-10s %-22s %-20s %-10s %-20s %-8s %-4s %-4s %-4s %-4s %-8s %-12s %-6s %-8s\n"

# Create header string and dashed line of matching width
header=$(printf "$header_fmt" "Disk" "Model" "Serial" "Size" "WWN" "Health" "R" "P" "U" "S" "HP" "Work" "Temp" "Advice")
header_len=$(echo -n "$header" | wc -c)
dashes=$(printf '%*s' "$header_len" '' | tr ' ' '-')

# Print header and dashed line
echo "$header"
echo "$dashes"

# Process each disk
for disk in $disks; do
  # Determine device type based on previous scan or error check.
  # Default is no type; if "Unknown USB bridge" is detected, use "-d sat"
  TYPE=""
  usb_check=$(smartctl -i "$disk" 2>&1)
  if echo "$usb_check" | grep -qi "Unknown USB bridge"; then
    TYPE="-d sat"
  fi

  # Get device information with the determined TYPE option
  info=$(smartctl $TYPE -i "$disk")
  model=$(echo "$info" | grep -i "Device Model" | awk -F: '{print $2}' | xargs)
  if [ -z "$model" ]; then
    model=$(echo "$info" | grep -i "Model Family" | awk -F: '{print $2}' | xargs)
  fi
  serial=$(echo "$info" | grep -i "Serial Number" | awk -F: '{print $2}' | xargs)
  
  # Extract disk size.
  # First try "User Capacity:" (common for SATA drives)
  size=$(echo "$info" | grep "User Capacity:" | sed -E 's/.*\[(.*)\].*/\1/' | xargs)
  # If not found, try "Total NVM Capacity:" (for NVMe drives)
  if [ -z "$size" ]; then
    size=$(echo "$info" | grep "Total NVM Capacity:" | sed -E 's/.*\[(.*)\].*/\1/' | xargs)
  fi
  
  # Extract WWN string from the info.
  wwn=$(echo "$info" | grep -i "LU WWN Device Id:" | awk -F: '{print $2}' | xargs)
  if [ -z "$wwn" ]; then
    wwn=$(echo "$info" | grep -i "WWN:" | awk -F: '{print $2}' | xargs)
  fi
  
  model=${model:-"N/A"}
  serial=${serial:-"N/A"}
  size=${size:-"N/A"}
  wwn=${wwn:-"N/A"}
  
  # Get overall health status
  health_output=$(smartctl $TYPE -H "$disk")
  health=$(echo "$health_output" | grep -i "SMART overall-health self-assessment test result" | cut -d: -f2 | xargs)
  if [ -z "$health" ]; then
    health="Unknown"
  fi
  
  # Get detailed SMART attributes
  smart_data=$(smartctl $TYPE -A "$disk")
  
  # Extract key parameters (default to 0 if not found)
  r=$(echo "$smart_data" | awk '/Reallocated_Sector_Ct/ {print $10}')
  p=$(echo "$smart_data" | awk '/Current_Pending_Sector/ {print $10}')
  u=$(echo "$smart_data" | awk '/Offline_Uncorrectable/ {print $10}')
  s=$(echo "$smart_data" | awk '/Spin_Retry_Count/ {print $10}')
  r=${r:-0}
  p=${p:-0}
  u=${u:-0}
  s=${s:-0}
  
  # Extract head parking count (Load_Cycle_Count)
  hpc=$(echo "$smart_data" | awk '/Load_Cycle_Count/ {print $10}')
  hpc=${hpc:-"N/A"}
  
  # Extract power-on hours and calculate work time (days and hours)
  poh=$(echo "$smart_data" | awk '/Power_On_Hours/ {print $10}')
  if [[ "$poh" =~ ^[0-9]+$ ]]; then
    days=$(( poh / 24 ))
    hours=$(( poh % 24 ))
    work="${days}d ${hours}h"
  else
    work="N/A"
  fi
  
  # Extract temperature (assuming attribute is Temperature_Celsius)
  temp=$(echo "$smart_data" | awk '/Temperature_Celsius/ {print $10}')
  temp=${temp:-"N/A"}
  
  # Determine advisory: if any key parameter is non-zero, flag as FAIL; otherwise OK.
  if [ "$r" -gt 0 ] || [ "$p" -gt 0 ] || [ "$u" -gt 0 ] || [ "$s" -gt 0 ]; then
    advice="FAIL"
  else
    advice="OK"
  fi
  
  # Print row for the disk
  printf "$row_fmt" "$disk" "$model" "$serial" "$size" "$wwn" "$health" "$r" "$p" "$u" "$s" "$hpc" "$work" "$temp" "$advice"
done

echo "HDD check complete."

# Column Explanations:
echo ""
echo "Column Explanations:"
echo "Disk   : Device file for the HDD (e.g., /dev/sda)"
echo "Model  : The disk model name"
echo "Serial : The disk serial number"
echo "Size   : Disk capacity (e.g., \"1.00 TB\")"
echo "WWN    : The disk's WWN as reported by smartctl (e.g., \"5 000cca 264d0e0b2\")"
echo "Health : Overall SMART health status (e.g., PASSED)"
echo "R      : Reallocated Sector Count (number of sectors remapped)"
echo "P      : Current Pending Sector Count (sectors pending reallocation)"
echo "U      : Offline Uncorrectable Sector Count (sectors that cannot be corrected)"
echo "S      : Spin Retry Count (indicates spin-up issues)"
echo "HP     : Head Parking Count (Load_Cycle_Count)"
echo "Work   : Calculated work time from Power_On_Hours (days and hours)"
echo "Temp   : Temperature in Celsius (from Temperature_Celsius attribute)"
echo "Advice : Advisory message (\"FAIL\" if any key parameter is non-zero, otherwise \"OK\")"
