#!/usr/bin/env bash
# auto-winrdp-advanced.sh — Full unattended Windows VM on KVM, RDP ready, VirtIO auto-driver
# by bro-ChatGPT

set -euo pipefail

# ====== Config (override via env) ======
VMNAME="${VMNAME:-winvm}"
OS_CHOICE="${OS_CHOICE:-2022}"        # 2016|2019|2022|win10|win11
VCPUS="${VCPUS:-2}"
RAM_MB="${RAM_MB:-4096}"              # 4GB
DISK_GB="${DISK_GB:-60}"
ADMIN_PASS="${ADMIN_PASS:-P@ssw0rd!}" # ganti!
RDP_HOST_PORT="${RDP_HOST_PORT:-3389}"# port RDP di host
WIN_ISO_URL="${WIN_ISO_URL:-}"        # URL ISO Windows resmi/trial
# VirtIO driver ISO (resmi Fedora)
VIRTIO_URL="${VIRTIO_URL:-https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/latest-virtio/virtio-win.iso}"

IMG_DIR="/var/lib/libvirt/images"
BOOT_DIR="/var/lib/libvirt/boot"
WIN_ISO_LOCAL="${BOOT_DIR}/${VMNAME}-install.iso"
VIRTIO_ISO="${BOOT_DIR}/${VMNAME}-virtio.iso"
AUTOUNATTEND_ISO="${BOOT_DIR}/${VMNAME}-autounattend.iso"
DISK_PATH="${IMG_DIR}/${VMNAME}.qcow2"

usage() {
  cat <<USG
Usage (contoh):
  sudo VMNAME=win2022 OS_CHOICE=2022 VCPUS=4 RAM_MB=8192 DISK_GB=80 \\
       ADMIN_PASS='RahasiaBanget123!' \\
       WIN_ISO_URL='https://<link-iso-windows-server-2022-eval-resmi>' \\
       RDP_HOST_PORT=3389 \\
       bash ./auto-winrdp-advanced.sh
USG
  exit 1
}

[[ $EUID -ne 0 ]] && { echo "Jalankan sebagai root/sudo."; exit 1; }

# ====== Basic deps ======
command -v curl >/dev/null || { apt-get update -y; apt-get install -y curl; }

# ====== Cek VT-x/AMD-V ======
if ! LC_ALL=C lscpu | grep -Eiq 'vmx|svm'; then
  echo "Peringatan: VT-x/AMD-V tidak terdeteksi. VM bisa lambat atau gagal start."
fi

# ====== Install KVM stack ======
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  qemu-kvm libvirt-daemon-system libvirt-clients virtinst \
  genisoimage ovmf bridge-utils net-tools nftables

systemctl enable --now libvirtd

# ====== Libvirt default NAT ======
if ! virsh net-list --all | grep -q "default"; then
  virsh net-define /usr/share/libvirt/networks/default.xml
fi
virsh net-autostart default || true
virsh net-start default || true

mkdir -p "$IMG_DIR" "$BOOT_DIR"

# ====== Ambil ISO Windows ======
if [[ -n "$WIN_ISO_URL" ]]; then
  echo "[*] Download ISO Windows..."
  curl -fL --retry 3 -o "$WIN_ISO_LOCAL" "$WIN_ISO_URL"
fi
[[ -f "$WIN_ISO_LOCAL" ]] || { echo "ISO Windows tidak ditemukan di $WIN_ISO_LOCAL"; usage; }

# ====== Ambil ISO VirtIO ======
if [[ ! -f "$VIRTIO_ISO" ]]; then
  echo "[*] Download VirtIO driver ISO..."
  curl -fL --retry 3 -o "$VIRTIO_ISO" "$VIRTIO_URL"
fi

# ====== os-variant ======
case "$OS_CHOICE" in
  2016) OSVAR="win2k16";;
  2019) OSVAR="win2k19";;
  2022) OSVAR="win2k22";;
  win10) OSVAR="win10";;
  win11) OSVAR="win11";;
  *) echo "OS_CHOICE tidak valid (pakai: 2016|2019|2022|win10|win11)"; exit 1;;
esac

# ====== Disk VM ======
[[ -f "$DISK_PATH" ]] || qemu-img create -f qcow2 "$DISK_PATH" "${DISK_GB}G"

# ====== Siapkan Autounattend (enable RDP + auto install VirtIO drivers) ======
TMPD="$(mktemp -d)"
AUTOUNATTEND_XML="${TMPD}/Autounattend.xml"
FIRSTBOOT_PS1="${TMPD}/FirstBoot.ps1"

cat > "$FIRSTBOOT_PS1" <<'PS1'
# FirstBoot: enable RDP, install VirtIO drivers, basic tweaks
Try {
  # Enable RDP + firewall
  Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name 'fDenyTSConnections' -Value 0
  Enable-NetFirewallRule -DisplayGroup 'Remote Desktop'
  # Prefer NLA
  New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name 'UserAuthentication' -PropertyType DWord -Value 1 -Force | Out-Null

  # Cari drive letter VirtIO CD
  $cd = Get-Volume | Where-Object {$_.FileSystemLabel -eq 'virtio-win'} | Select-Object -First 1
  if (-not $cd) {
    # fallback: cari drive dengan files 'vioscsi' dll
    $cd = Get-Volume | Where-Object { Test-Path ($_.DriveLetter + ':\viostor') } | Select-Object -First 1
  }
  if ($cd) {
    $drv = $cd.DriveLetter + ':\'
    # Install semua driver INF
    pnputil /add-driver ($drv + '*.inf') /subdirs /install | Out-Null
  }

  # Set power: never sleep on AC
  powercfg -change -standby-timeout-ac 0

  # Tulis tanda selesai
  New-Item -Path 'C:\' -Name 'rdp_ready.txt' -ItemType File -Force | Out-Null
} Catch {
  # tulis error kalau ada
  $_ | Out-File -FilePath 'C:\firstboot_error.txt' -Encoding utf8 -Force
}
PS1

cat > "$AUTOUNATTEND_XML" <<XML
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="windowsPE">
    <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <UserData>
        <AcceptEula>true</AcceptEula>
        <FullName>Admin</FullName>
        <Organization>RDP</Organization>
        <ProductKey></ProductKey>
      </UserData>
      <DiskConfiguration>
        <Disk wcm:action="add" wcm:keyValue="0" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
          <CreatePartitions>
            <CreatePartition wcm:action="add">
              <Order>1</Order>
              <Type>Primary</Type>
              <Extend>true</Extend>
            </CreatePartition>
          </CreatePartitions>
          <WillWipeDisk>true</WillWipeDisk>
        </Disk>
      </DiskConfiguration>
      <ImageInstall>
        <OSImage>
          <InstallTo>
            <DiskID>0</DiskID>
            <PartitionID>1</PartitionID>
          </InstallTo>
          <WillShowUI>OnError</WillShowUI>
        </OSImage>
      </ImageInstall>
    </component>
  </settings>

  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <ComputerName>WINVM</ComputerName>
      <TimeZone>SE Asia Standard Time</TimeZone>
    </component>
    <component name="Microsoft-Windows-TerminalServices-LocalSessionManager" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <fDenyTSConnections>false</fDenyTSConnections>
    </component>
    <component name="Microsoft-Windows-TerminalServices-RDP-WinStationExtensions" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <UserAuthentication>1</UserAuthentication>
    </component>
  </settings>

  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <InputLocale>en-US</InputLocale>
      <SystemLocale>en-US</SystemLocale>
      <UILanguage>en-US</UILanguage>
      <UserLocale>en-US</UserLocale>
    </component>
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideLocalAccountScreen>true</HideLocalAccountScreen>
        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <ProtectYourPC>1</ProtectYourPC>
      </OOBE>
      <UserAccounts>
        <AdministratorPassword>
          <Value>__ADMIN_PASS__</Value>
          <PlainText>true</PlainText>
        </AdministratorPassword>
      </UserAccounts>
      <AutoLogon>
        <Username>Administrator</Username>
        <Enabled>true</Enabled>
        <LogonCount>1</LogonCount>
        <Password>
          <Value>__ADMIN_PASS__</Value>
          <PlainText>true</PlainText>
        </Password>
      </AutoLogon>
      <FirstLogonCommands>
        <SynchronousCommand wcm:action="add">
          <CommandLine>powershell -ExecutionPolicy Bypass -File D:\FirstBoot.ps1</CommandLine>
          <Description>FirstBoot Script</Description>
          <Order>1</Order>
        </SynchronousCommand>
      </FirstLogonCommands>
    </component>
  </settings>

  <cpi:offlineImage cpi:source="wim://sources/install.wim#Windows" xmlns:cpi="urn:schemas-microsoft-com:cpi" />
</unattend>
XML

# inject password
sed -i "s|__ADMIN_PASS__|${ADMIN_PASS}|g" "$AUTOUNATTEND_XML"

# Autounattend ISO berisi Autounattend.xml + FirstBoot.ps1 di root CD (D:\)
mkdir -p "${TMPD}/cdroot"
cp "$AUTOUNATTEND_XML" "${TMPD}/cdroot/Autounattend.xml"
cp "$FIRSTBOOT_PS1"    "${TMPD}/cdroot/FirstBoot.ps1"
genisoimage -udf -o "$AUTOUNATTEND_ISO" -V AUTOUNATTEND -J -R "${TMPD}/cdroot" >/dev/null

# ====== Bersihkan VM lama ======
if virsh dominfo "$VMNAME" >/dev/null 2>&1; then
  virsh destroy "$VMNAME" >/dev/null 2>&1 || true
  virsh undefine "$VMNAME" --nvram >/dev/null 2>&1 || true
fi

# ====== Buat & start VM (headless). Disk/NIC: SATA + e1000 agar OOTB ======
virt-install \
  --name "$VMNAME" \
  --ram "$RAM_MB" \
  --vcpus "$VCPUS" \
  --cpu host \
  --machine q35 \
  --os-variant "$OSVAR" \
  --virt-type kvm \
  --graphics none \
  --network network=default,model=e1000 \
  --disk path="$DISK_PATH",bus=sata,format=qcow2 \
  --disk path="$AUTOUNATTEND_ISO",device=cdrom \
  --disk path="$VIRTIO_ISO",device=cdrom \
  --cdrom "$WIN_ISO_LOCAL" \
  --boot useserial=on,loader=/usr/share/OVMF/OVMF_CODE.fd \
  --noautoconsole

echo "[*] VM dibuat. Windows sedang install otomatis (tanpa input)."

# ====== Tunggu IP VM (akan muncul setelah 1-2 reboot) ======
echo "[*] Menunggu IP VM dari NAT libvirt..."
VMIP=""
for i in {1..120}; do
  VMIP=$(virsh domifaddr "$VMNAME" 2>/dev/null | awk '/ipv4/ {print $4}' | cut -d/ -f1 | head -n1 || true)
  [[ -n "$VMIP" ]] && break
  sleep 5
done

HOSTIP=$(hostname -I | awk '{print $1}')
echo "[*] Host IP: $HOSTIP"
if [[ -n "$VMIP" ]]; then
  echo "[*] IP VM (sementara): $VMIP"
fi

# ====== Port forward host:RDP_HOST_PORT -> VM:3389 ======
echo "[*] Konfigurasi NAT RDP di nftables..."
nft list tables | grep -q '^table inet rdpnat$' || nft add table inet rdpnat
nft list chains inet rdpnat | grep -q '^chain prerouting$' || nft add chain inet rdpnat prerouting { type nat hook prerouting priority 0 \; }
nft list chains inet rdpnat | grep -q '^chain postrouting$' || nft add chain inet rdpnat postrouting { type nat hook postrouting priority 100 \; }

# hapus rule lama untuk port ini (jika ada)
OLD_HANDLE=$(nft -a list chain inet rdpnat prerouting 2>/dev/null | awk "/tcp dport ${RDP_HOST_PORT}/ {print \$NF}" | tail -n1 || true)
[[ -n "$OLD_HANDLE" ]] && nft delete rule inet rdpnat prerouting handle "$OLD_HANDLE" || true

if [[ -n "$VMIP" ]]; then
  nft add rule inet rdpnat prerouting tcp dport ${RDP_HOST_PORT} dnat to ${VMIP}:3389
fi
# SNAT
nft list ruleset | grep -q "oifname \"virbr0\"" || nft add rule inet rdpnat postrouting oifname \"virbr0\" masquerade

echo
echo "==============================================================="
echo "[✓] Proses jalan. Tunggu instalasi Windows selesai."
echo "    RDP akan aktif otomatis (user: Administrator / pass: ${ADMIN_PASS})"
echo "    Akses RDP: ${HOSTIP}:${RDP_HOST_PORT}"
[[ -n "$VMIP" ]] && echo "    (Internal VM IP: ${VMIP})"
echo "Catatan: Pertama kali siap, file C:\\rdp_ready.txt akan ada di dalam VM."
echo "==============================================================="
