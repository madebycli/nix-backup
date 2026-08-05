#!/usr/bin/env bash
set -Eeuo pipefail

section() {
  printf '\n\n===== %s =====\n' "$1"
}

run() {
  printf '\n$ %s\n' "$*"
  "$@" 2>&1 || true
}

section "Identity"
run whoami
run hostname
run uname -a
run nixos-version

section "PCI network devices and drivers"
run lspci -nnk

section "USB devices"
run lsusb

section "Network interfaces"
run ip -brief link
run ip -brief address

section "Wireless PHYs"
run iw dev
run iw phy

section "Radio kill switches"
run rfkill list all

section "Loaded wireless-related kernel modules"
run bash -c "lsmod | grep -Ei 'iwl|ath|brcm|b43|rtw|rtl|mt7|mt76|wl|cfg80211|mac80211'"

section "NetworkManager"
run systemctl is-enabled NetworkManager
run systemctl is-active NetworkManager
run nmcli general status
run nmcli radio all
run nmcli device status
run nmcli -f IN-USE,SSID,MODE,CHAN,RATE,SIGNAL,SECURITY device wifi list --rescan yes

section "Kernel and firmware messages"
if command -v sudo >/dev/null 2>&1; then
  run sudo dmesg --level=err,warn
  run sudo journalctl -b -k --no-pager
else
  run dmesg --level=err,warn
  run journalctl -b -k --no-pager
fi

section "Current NixOS hardware and network configuration"
run bash -c "grep -RniE 'networkmanager|wireless|firmware|kernelModules|initrd.*kernelModules|blacklistedKernelModules' /etc/nixos 2>/dev/null"

section "Compact Wi-Fi summary"
printf '\nPCI candidates:\n'
lspci -nnk 2>/dev/null | grep -A4 -Ei 'network controller|wireless|wi-fi' || true
printf '\nUSB candidates:\n'
lsusb 2>/dev/null | grep -Ei 'wireless|wifi|802\.11|wlan|realtek|ralink|mediatek|atheros|broadcom|intel' || true
printf '\nInterfaces:\n'
ip -brief link 2>/dev/null || true
printf '\nrfkill:\n'
rfkill list all 2>/dev/null || true
printf '\nNetworkManager devices:\n'
nmcli device status 2>/dev/null || true

printf '\n\nDiagnosis complete. Copy the full output back for driver selection.\n'
