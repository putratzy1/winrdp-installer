#!/usr/bin/env bash
# setup.sh — Interactive one-liner installer for Windows VM (KVM) by @putratzy1

set -euo pipefail

RAW_BASE="https://raw.githubusercontent.com/putratzy1/winrdp-installer/main"
MAIN_SCRIPT="${RAW_BASE}/auto-winrdp-advanced.sh"

# =============== UI helpers ===============
C0="\033[0m"; C1="\033[1;36m"; C2="\033[1;35m"; C3="\033[1;34m"; C4="\033[1;33m"; C5="\033[1;32m"; C6="\033[1;31m"
hr(){ printf "${C3}%s${C0}\n" "────────────────────────────────────────────────────────"; }
title(){
  clear
  printf "${C2}%s${C0}\n" "╔══════════════════════════════════════════════════════╗"
  printf "${C2}║${C0} ${C1}Putra RDP Installer${C0}                                      ${C2}║${C0}\n"
  printf "${C2}%s${C0}\n" "╚══════════════════════════════════════════════════════╝"
}

need_root(){
  if [[ $EUID -ne 0 ]]; then
    echo -e "${C6}[!] Jalankan dengan sudo/root.${C0}"
    exit 1
  fi
}

check_cmd(){ command -v "$1" >/dev/null 2>&1; }

pause(){ read -rp "$(printf "${C4}Tekan Enter untuk lanjut...${C0} ")"; }

# =============== preflight ===============
need_root
title
echo -e "${C5}Installer ini akan men-deploy Windows (Server/10/11) di atas KVM/QEMU, enable RDP otomatis.${C0}"
echo -e "${C4}Host Ubuntu 22.04 kamu tetap aman (tidak ganti OS, bukan Docker).${C0}"
hr

# Cek requirement dasar
apt-get update -y >/dev/null 2>&1 || true
for p in curl lscpu; do
  check_cmd "$p" || apt-get install -y "$p"
done

if ! LC_ALL=C lscpu | grep -Eiq 'vmx|svm'; then
  echo -e "${C6}[!] Peringatan: VT-x/AMD-V tidak terdeteksi. VM bisa lambat/ga jalan.${C0}"
  sleep 2
fi

# =============== pilih OS ===============
echo -e "${C1}Pilih Versi Windows yang ingin diinstall:${C0}"
echo -e "  ${C5}1${C0}) Windows Server 2016 (Eval 180 hari)"
echo -e "  ${C5}2${C0}) Windows Server 2019 (Eval 180 hari)"
echo -e "  ${C5}3${C0}) Windows Server 2022 (Eval 180 hari)"
echo -e "  ${C5}4${C0}) Windows 10 Pro (Trial, tanpa aktivasi)"
echo -e "  ${C5}5${C0}) Windows 11 Pro (Trial, tanpa aktivasi)"
read -rp "$(printf "${C4}Pilih nomor [1-5]: ${C0}")" CHOICE

case "$CHOICE" in
  1) OS_CHOICE="2016"; OS_LABEL="Windows Server 2016";;
  2) OS_CHOICE="2019"; OS_LABEL="Windows Server 2019";;
  3) OS_CHOICE="2022"; OS_LABEL="Windows Server 2022";;
  4) OS_CHOICE="win10"; OS_LABEL="Windows 10 Pro";;
  5) OS_CHOICE="win11"; OS_LABEL="Windows 11 Pro";;
  *) echo -e "${C6}Pilihan tidak valid.${C0}"; exit 1;;
esac
hr

# =============== input spec ===============
read -rp "$(printf "${C4}Nama VM (default: winvm): ${C0}")" VMNAME
VMNAME=${VMNAME:-winvm}
read -rp "$(printf "${C4}vCPU (default: 2): ${C0}")" VCPUS
VCPUS=${VCPUS:-2}
read -rp "$(printf "${C4}RAM MB (default: 4096): ${C0}")" RAM_MB
RAM_MB=${RAM_MB:-4096}
read -rp "$(printf "${C4}Disk GB (default: 60): ${C0}")" DISK_GB
DISK_GB=${DISK_GB:-60}
read -rp "$(printf "${C4}Port RDP publik host (default: 3389): ${C0}")" RDP_HOST_PORT
RDP_HOST_PORT=${RDP_HOST_PORT:-3389}
read -rp "$(printf "${C4}Password Administrator Windows (default: P@ssw0rd!): ${C0}")" ADMIN_PASS
ADMIN_PASS=${ADMIN_PASS:-P@ssw0rd!}
hr

# =============== ISO URL handling ===============
echo -e "${C1}Sumber ISO Windows:${C0}"
echo -e "• Disarankan pakai ISO resmi Microsoft (Server = Evaluation 180 hari; 10/11 = trial)."
echo -e "• Kalau kamu kosongkan, installer akan coba URL bawaan (bisa berubah sewaktu-waktu)."
read -rp "$(printf "${C4}Masukkan URL ISO (kosongkan untuk auto): ${C0}")" WIN_ISO_URL
WIN_ISO_URL=${WIN_ISO_URL:-}

# Default fallback (fwlink). Jika gagal, nanti script utama akan menolak & minta ulang.
if [[ -z "$WIN_ISO_URL" ]]; then
  case "$OS_CHOICE" in
    2016) WIN_ISO_URL="https://go.microsoft.com/fwlink/?linkid=829176" ;; # fallback
    2019) WIN_ISO_URL="https://go.microsoft.com/fwlink/?linkid=2195331" ;;
    2022) WIN_ISO_URL="https://go.microsoft.com/fwlink/?linkid=2195334" ;;
    win10) WIN_ISO_URL="https://www.microsoft.com/software-download/windows10ISO" ;;
    win11) WIN_ISO_URL="https://www.microsoft.com/software-download/windows11" ;;
  esac
fi

# Ringkasan
title
echo -e "${C5}Ringkasan konfigurasi:${C0}"
echo -e "  OS           : ${OS_LABEL} (${OS_CHOICE})"
echo -e "  VM Name      : ${VMNAME}"
echo -e "  vCPU         : ${VCPUS}"
echo -e "  RAM (MB)     : ${RAM_MB}"
echo -e "  Disk (GB)    : ${DISK_GB}"
echo -e "  RDP Port     : ${RDP_HOST_PORT} (host publik)"
echo -e "  Admin Pass   : ${ADMIN_PASS}"
echo -e "  ISO URL      : ${WIN_ISO_URL}"
hr
read -rp "$(printf "${C4}Lanjutkan install? [y/N]: ${C0}")" YN
[[ "${YN:-n}" =~ ^[Yy]$ ]] || { echo -e "${C6}Dibatalkan.${C0}"; exit 1; }

# =============== fetch & run main script ===============
TMP="/tmp/auto-winrdp-advanced.sh"
echo -e "${C1}Mengunduh script utama...${C0}"
curl -fsSL "$MAIN_SCRIPT" -o "$TMP"

chmod +x "$TMP"
echo -e "${C5}Menjalankan installer... ini bisa butuh waktu (download ISO + instalasi Windows).${C0}"
echo

VMNAME="$VMNAME" \
OS_CHOICE="$OS_CHOICE" \
VCPUS="$VCPUS" \
RAM_MB="$RAM_MB" \
DISK_GB="$DISK_GB" \
ADMIN_PASS="$ADMIN_PASS" \
RDP_HOST_PORT="$RDP_HOST_PORT" \
WIN_ISO_URL="$WIN_ISO_URL" \
bash "$TMP"
