#!/usr/bin/env python3
"""VM E2E smoke test: boot full install from a real USB block device.

This test is intentionally optional and environment-dependent.
It is skipped unless called with --run.
"""

from __future__ import annotations

import argparse
import os
import platform
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path


def run(cmd: list[str]) -> int:
    return subprocess.run(cmd, check=False).returncode


def output(cmd: list[str]) -> str:
    proc = subprocess.run(cmd, check=False, text=True, capture_output=True)
    return (proc.stdout or "") + (proc.stderr or "")


def require_command(name: str) -> bool:
    return shutil.which(name) is not None


def macos_qemu_accel() -> str:
    info = output(["qemu-system-x86_64", "-accel", "help"]).lower()
    if "hvf" in info:
        return "hvf"
    return "tcg"


def macos_qemu_cpu(accel: str) -> str:
    # On macOS, '-cpu host' is often unsupported. Use a portable model.
    if accel == "hvf":
        return "max"
    return "qemu64"


def macos_whole_disk(usb_device: str) -> str:
    dev = usb_device.strip()
    if dev.startswith("/dev/rdisk"):
        dev = dev.replace("/dev/rdisk", "/dev/disk", 1)
    match = re.match(r"^(/dev/disk\d+)(s\d+)?$", dev)
    if match:
        return match.group(1)
    return dev


def macos_disk_partitions(whole_disk: str) -> list[str]:
    text = output(["diskutil", "list", whole_disk])
    parts: list[str] = []
    for line in text.splitlines():
        match = re.search(r"(disk\d+s\d+)\s*$", line)
        if match:
            parts.append(match.group(1))
    return parts


def macos_mount_point(part_device: str) -> str:
    info = output(["diskutil", "info", part_device])
    for line in info.splitlines():
        if line.strip().startswith("Mount Point:"):
            return line.split(":", 1)[1].strip()
    return ""


def linux_libvirt_flow(
    usb_device: str,
    timeout_seconds: int,
    keep_on_fail: bool,
    markers: re.Pattern[str],
) -> int:
    needed = ("virsh", "virt-install", "qemu-img")
    missing = [cmd for cmd in needed if not require_command(cmd)]
    if missing:
        print(f"[anaconda-vm] skipped (fehlende Tools: {', '.join(missing)})")
        return 0

    if os.geteuid() != 0:
        print("[anaconda-vm] FAIL: bitte als root ausfuehren (libvirt/qemu:///system + Blockdevice)")
        return 2

    vm_name = f"fedora-anaconda-usb-{int(time.time())}"
    workdir = Path(tempfile.mkdtemp(prefix=f"{vm_name}-"))
    install_disk = workdir / "target.qcow2"
    serial_log = workdir / "serial.log"

    def cleanup(success: bool) -> None:
        if success or not keep_on_fail:
            _ = run(["virsh", "destroy", vm_name])
            _ = run(["virsh", "undefine", vm_name, "--nvram"])
            for p in (install_disk, serial_log):
                try:
                    p.unlink(missing_ok=True)
                except Exception:
                    pass
            try:
                workdir.rmdir()
            except Exception:
                pass
        else:
            print(f"[anaconda-vm] Debug VM behalten: {vm_name}")
            print(f"[anaconda-vm] Serial-Log: {serial_log}")

    rc = run(["qemu-img", "create", "-f", "qcow2", str(install_disk), "40G"])
    if rc != 0:
        print("[anaconda-vm] FAIL: qemu-img create fehlgeschlagen")
        return 1

    virt_cmd = [
        "virt-install",
        "--connect",
        "qemu:///system",
        "--name",
        vm_name,
        "--memory",
        "4096",
        "--vcpus",
        "4",
        "--os-variant",
        "fedora-unknown",
        "--disk",
        f"path={install_disk},format=qcow2,bus=virtio",
        "--disk",
        f"path={usb_device},device=disk,bus=usb,cache=none",
        "--network",
        "network=default",
        "--graphics",
        "none",
        "--serial",
        f"file,path={serial_log}",
        "--console",
        "pty,target.type=serial",
        "--boot",
        "uefi,menu=on,useserial=on",
        "--noautoconsole",
        "--wait",
        "0",
    ]

    rc = run(virt_cmd)
    if rc != 0:
        print("[anaconda-vm] FAIL: virt-install fehlgeschlagen")
        cleanup(success=False)
        return 1

    time.sleep(8)
    _ = run(["virsh", "send-key", vm_name, "KEY_D"])

    deadline = time.time() + max(30, timeout_seconds)
    found = False

    print(f"[anaconda-vm] warte auf Anaconda-Marker im Serial-Log ({serial_log})...")
    while time.time() < deadline:
        if serial_log.exists():
            text = serial_log.read_text(encoding="utf-8", errors="ignore")
            if markers.search(text):
                found = True
                break
        time.sleep(3)

    if not found:
        print("[anaconda-vm] FAIL: kein Anaconda-Marker im Timeout gefunden")
        print(f"[anaconda-vm] Hinweis: pruefe Log unter {serial_log}")
        cleanup(success=False)
        return 1

    print("[anaconda-vm] PASS: Anaconda im VM-Serial-Log erkannt")
    cleanup(success=True)
    return 0


def _read_iso_label(iso_path: str) -> str:
    """ISO-Volume-Label aus der GRUB-Konfiguration lesen (von mkksiso gesetzt)."""
    try:
        proc = subprocess.run(
            ["bsdtar", "-xf", iso_path, "-O", "boot/grub2/grub.cfg"],
            capture_output=True, text=True, check=False,
        )
        for line in proc.stdout.splitlines():
            m = re.search(r"hd:LABEL=([^\s/]+)", line)
            if m:
                return m.group(1)
    except Exception:
        pass
    return "Fedora-E-dvd-x86_64-43"


def macos_qemu_flow(
    usb_device: str,
    usb_image: str,
    iso_image: str,
    timeout_seconds: int,
    keep_on_fail: bool,
    gui: bool,
    watch_install: bool,
    markers: re.Pattern[str],
) -> int:
    needed = ("qemu-system-x86_64", "qemu-img")
    missing = [cmd for cmd in needed if not require_command(cmd)]
    if missing:
        print(f"[anaconda-vm] skipped (fehlende Tools: {', '.join(missing)})")
        return 0

    if os.geteuid() != 0:
        print("[anaconda-vm] FAIL: bitte mit sudo ausfuehren (Raw-USB in QEMU)")
        return 2

    vm_name = f"fedora-anaconda-usb-macos-{int(time.time())}"
    workdir = Path(tempfile.mkdtemp(prefix=f"{vm_name}-"))
    install_disk = workdir / "target.qcow2"
    serial_log = workdir / "serial.log"
    vmlinuz_copy = workdir / "vmlinuz"
    initrd_copy = workdir / "initrd.img"
    project_dir = Path(__file__).resolve().parent.parent
    log_dir = project_dir / "logs"
    log_dir.mkdir(parents=True, exist_ok=True)
    # Serial-Log direkt in logs/ — sofort ohne sudo lesbar via tail -f
    serial_log = log_dir / "vm-serial.log"

    def save_logs() -> None:
        # Log liegt bereits in logs/ — nur Berechtigungen öffnen damit der aufrufende User lesen kann
        if serial_log.exists():
            try:
                serial_log.chmod(0o644)
            except Exception:
                pass
            print(f"[anaconda-vm] Log: {serial_log}")

    qemu_proc: subprocess.Popen[str] | None = None

    def cleanup(success: bool) -> None:
        nonlocal qemu_proc
        if qemu_proc is not None and qemu_proc.poll() is None:
            qemu_proc.terminate()
            try:
                qemu_proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                qemu_proc.kill()

        if success or not keep_on_fail:
            for p in (install_disk, vmlinuz_copy, initrd_copy):
                try:
                    p.unlink(missing_ok=True)
                except Exception:
                    pass
            try:
                workdir.rmdir()
            except Exception:
                pass
        else:
            print(f"[anaconda-vm] Debug-Artefakte behalten unter: {workdir}")

    rc = run(["qemu-img", "create", "-f", "qcow2", str(install_disk), "40G"])
    if rc != 0:
        print("[anaconda-vm] FAIL: qemu-img create fehlgeschlagen")
        return 1

    if iso_image:
        # ISO-Modus: vmlinuz/initrd direkt aus der gepatchten ISO extrahieren.
        iso_extract = workdir / "iso_extract"
        iso_extract.mkdir()
        rc = run(["bsdtar", "-xf", iso_image, "-C", str(iso_extract),
                  "images/pxeboot/vmlinuz", "images/pxeboot/initrd.img"])
        if rc != 0:
            print(f"[anaconda-vm] FAIL: Boot-Dateien konnten nicht aus ISO extrahiert werden")
            save_logs()
            cleanup(success=False)
            return 1
        shutil.copy2(iso_extract / "images/pxeboot/vmlinuz",    vmlinuz_copy)
        shutil.copy2(iso_extract / "images/pxeboot/initrd.img", initrd_copy)
        shutil.rmtree(iso_extract, ignore_errors=True)
        print(f"[anaconda-vm] ISO-Modus: {iso_image}")
        print(f"[anaconda-vm] vmlinuz: {vmlinuz_copy.stat().st_size // 1024 // 1024} MB")
        print(f"[anaconda-vm] initrd:  {initrd_copy.stat().st_size // 1024 // 1024} MB")
    elif usb_image:
        # Virtueller USB-Modus: vorgebautes Image + exportierte Boot-Dateien nutzen.
        usb_raw = usb_image
        project_dir = Path(__file__).resolve().parent.parent
        boot_dir = project_dir / "iso" / "vm-boot"
        if not (boot_dir / "vmlinuz").exists() or not (boot_dir / "initrd.img").exists():
            print(f"[anaconda-vm] FAIL: Boot-Dateien nicht gefunden: {boot_dir}")
            print("[anaconda-vm] Hinweis: zuerst 'make install-podman' ausfuehren")
            cleanup(success=False)
            return 1
        shutil.copy2(boot_dir / "vmlinuz",    vmlinuz_copy)
        shutil.copy2(boot_dir / "initrd.img", initrd_copy)
        print(f"[anaconda-vm] Virtuelle USB: {usb_image}")
        print(f"[anaconda-vm] vmlinuz: {vmlinuz_copy.stat().st_size // 1024 // 1024} MB")
        print(f"[anaconda-vm] initrd:  {initrd_copy.stat().st_size // 1024 // 1024} MB")
    else:
        # Physischer USB-Modus: Partitionen mounten, Boot-Dateien kopieren, dann aushängen.
        usb_raw = usb_device
        if usb_raw.startswith("/dev/disk"):
            usb_raw = usb_raw.replace("/dev/disk", "/dev/rdisk", 1)

        usb_whole = macos_whole_disk(usb_device)
        found_boot = False
        for part in macos_disk_partitions(usb_whole):
            part_device = f"/dev/{part}"
            _ = run(["diskutil", "mount", part_device])
            mount_point = macos_mount_point(part_device)
            if not mount_point:
                continue
            mount_path = Path(mount_point)
            src_vmlinuz = mount_path / "boot/vmlinuz"
            src_initrd = mount_path / "boot/initrd.img"
            if src_vmlinuz.exists() and src_initrd.exists():
                print(f"[anaconda-vm] Kopiere Boot-Dateien von {mount_path} ...")
                shutil.copy2(src_vmlinuz, vmlinuz_copy)
                shutil.copy2(src_initrd, initrd_copy)
                print(f"[anaconda-vm] vmlinuz: {vmlinuz_copy.stat().st_size // 1024 // 1024} MB")
                print(f"[anaconda-vm] initrd:  {initrd_copy.stat().st_size // 1024 // 1024} MB")
                found_boot = True
                break

        if not found_boot:
            print("[anaconda-vm] FAIL: boot/vmlinuz + boot/initrd.img nicht auf USB gefunden")
            cleanup(success=False)
            return 1

        # Partitionen aushängen damit QEMU /dev/rdisk* ohne macOS-Blockierung öffnen kann.
        _ = run(["sync"])
        run(["diskutil", "unmountDisk", usb_whole])
        print(f"[anaconda-vm] USB ausgehaengt fuer QEMU-Raw-Zugriff: {usb_whole}")

    accel = macos_qemu_accel()
    cpu_model = macos_qemu_cpu(accel)
    # ISO-Modus: immer inst.text — graphical braucht viel RAM/CPU im VM und
    # blockiert den Serial-Log. USB-Modus folgt dem gui-Flag.
    if iso_image:
        display_mode = "inst.text"
    else:
        display_mode = "inst.graphical" if (gui and watch_install) else "inst.text"
    log_args = (
        "console=tty0 console=ttyS0,115200 "
        "systemd.journald.forward_to_console=1 systemd.console_level=6 "
        "systemd.log_target=console systemd.log_level=info "
        "systemd.mask=brltty.service"
    )

    if iso_image:
        # ISO-Modus: Stage2 + Kickstart + RPM-Repo per Volume-Label.
        # inst.disk=vda: %pre-Skript überspringt lsblk (leeres TRAN bei virtio-blk
        # verschiebt Spalten → Disk nicht erkannt). Direktangabe ist zuverlässiger.
        iso_label = _read_iso_label(iso_image)
        kernel_args = (
            f"inst.stage2=hd:LABEL={iso_label} "
            f"inst.ks=hd:LABEL={iso_label}:/fedora-full.ks "
            "inst.addrepo=fedora-autoinstall,file:///run/install/repo/rpm "
            "inst.disk=vda "
            f"rd.retry=30 {display_mode} "
            + log_args
        )
        qemu_cmd = [
            "qemu-system-x86_64",
            "-accel", accel,
            "-machine", "q35",
            "-cpu", cpu_model,
            "-m", "4096",
            "-smp", "4",
            "-kernel", str(vmlinuz_copy),
            "-initrd", str(initrd_copy),
            "-append", kernel_args,
            "-drive", f"if=virtio,file={install_disk},format=qcow2",
            "-cdrom", iso_image,
            "-serial", f"file:{serial_log}",
            "-monitor", "none",
            "-no-reboot",
        ]
    else:
        # USB-Modus: Stage2 vom Netz, Kickstart + RPM vom USB-Image.
        kernel_args = (
            "inst.stage2=https://dl.fedoraproject.org/pub/fedora/linux/releases/43/Everything/x86_64/os/ "
            "inst.repo=https://dl.fedoraproject.org/pub/fedora/linux/releases/43/Everything/x86_64/os/ "
            "inst.ks=hd:LABEL=FEDORA-USB:/kickstart/fedora-vm.ks "
            "inst.addrepo=fedora-autoinstall,hd:LABEL=FEDORA-USB:/rpm "
            f"rd.retry=30 {display_mode} "
            + log_args
        )
        qemu_cmd = [
            "qemu-system-x86_64",
            "-accel", accel,
            "-machine", "q35",
            "-cpu", cpu_model,
            "-m", "4096",
            "-smp", "4",
            "-kernel", str(vmlinuz_copy),
            "-initrd", str(initrd_copy),
            "-append", kernel_args,
            "-drive", f"if=virtio,file={install_disk},format=qcow2",
            "-drive", f"if=none,id=usbdrive,file={usb_raw},format=raw,snapshot=on",
            "-device", "virtio-blk-pci,drive=usbdrive",
            "-serial", f"file:{serial_log}",
            "-monitor", "none",
            "-no-reboot",
        ]

    if gui:
        qemu_cmd.extend([
            "-display", "cocoa,zoom-to-fit=on",
            "-device", "virtio-vga,xres=1920,yres=1080",
        ])
    else:
        qemu_cmd.extend(["-display", "none"])

    try:
        qemu_proc = subprocess.Popen(qemu_cmd, text=True)
    except Exception as exc:
        print(f"[anaconda-vm] FAIL: QEMU Start fehlgeschlagen: {exc}")
        save_logs()
        cleanup(success=False)
        return 1

    deadline = time.time() + max(30, timeout_seconds)
    found = False

    print(f"[anaconda-vm] warte auf Anaconda-Marker im Serial-Log ({serial_log})...")
    while time.time() < deadline:
        if serial_log.exists():
            text = serial_log.read_text(encoding="utf-8", errors="ignore")
            if markers.search(text):
                found = True
                break
        if qemu_proc.poll() is not None:
            print(f"[anaconda-vm][WARN] QEMU wurde vorzeitig beendet (exit={qemu_proc.returncode})")
            break
        time.sleep(3)

    if not found:
        print("[anaconda-vm] FAIL: kein Anaconda-Marker im Timeout gefunden")
        save_logs()
        cleanup(success=False)
        return 1

    print("[anaconda-vm] PASS: Anaconda im VM-Serial-Log erkannt")

    if watch_install:
        print("[anaconda-vm] GUI-Watch aktiv: VM bleibt offen, bis die Installation fertig ist oder du den Lauf beendest.")
        print(f"[anaconda-vm] Serial-Log: {serial_log}")
        try:
            while qemu_proc.poll() is None:
                time.sleep(5)
        except KeyboardInterrupt:
            print("[anaconda-vm] Abbruch durch Benutzer, räume auf...")
            save_logs()
            cleanup(success=False)
            return 130

        rc = qemu_proc.returncode or 0
        save_logs()
        if rc == 0:
            print("[anaconda-vm] PASS: VM wurde sauber beendet")
            cleanup(success=True)
            return 0

        print(f"[anaconda-vm] FAIL: VM beendete sich mit Exit-Code {rc}")
        cleanup(success=False)
        return rc

    save_logs()
    cleanup(success=True)
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--run", action="store_true", help="Run real VM E2E test")
    parser.add_argument(
        "--usb-device",
        default=os.environ.get("FEDORA_VM_USB_DEVICE", ""),
        help="Physisches USB-Device (z.B. /dev/sdb, /dev/disk6)",
    )
    parser.add_argument(
        "--usb-image",
        default=os.environ.get("FEDORA_VM_USB_IMAGE", ""),
        help="Vorgebautes virtuelles USB-Image (aus 'make install-podman')",
    )
    parser.add_argument(
        "--iso",
        default=os.environ.get("FEDORA_VM_ISO", ""),
        help="Gepatchte Installer-ISO (aus 'make build-iso')",
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=600,
        help="Max seconds to wait for Anaconda markers in serial log",
    )
    parser.add_argument(
        "--keep-on-fail",
        action="store_true",
        help="Keep VM definition and disks for debugging on failure",
    )
    parser.add_argument(
        "--gui",
        action="store_true",
        help="Show the VM window on macOS instead of running headless",
    )
    parser.add_argument(
        "--watch-install",
        action="store_true",
        help="Keep the macOS GUI VM running until the installation completes or the VM exits",
    )
    args = parser.parse_args()

    if not args.run:
        print("[anaconda-vm] skipped (nutze --run fuer echten VM-Test)")
        return 0

    usb_device = args.usb_device.strip()
    usb_image  = args.usb_image.strip()
    iso_image  = args.iso.strip()

    # Auto-detect: ISO hat Priorität (make build-iso) → virtual USB → physisch.
    if not usb_device and not usb_image and not iso_image:
        project_dir = Path(__file__).resolve().parent.parent
        isos = sorted(project_dir.glob("iso/fedora-autoinstall-*.iso"))
        if isos:
            iso_image = str(isos[-1])
            print(f"[anaconda-vm] Auto-erkannt: ISO {Path(iso_image).name}")
        elif (project_dir / "iso" / "fedora-usb-latest.img").exists():
            usb_image = str(project_dir / "iso" / "fedora-usb-latest.img")
            print(f"[anaconda-vm] Auto-erkannt: virtuelle USB {usb_image}")

    if not usb_device and not usb_image and not iso_image:
        print("[anaconda-vm] FAIL: kein ISO, USB-Image oder USB-Device gefunden")
        print("[anaconda-vm] Hinweis: 'make build-iso' ausfuehren um ISO zu erstellen")
        return 2

    if usb_device and not Path(usb_device).exists():
        print(f"[anaconda-vm] FAIL: USB-Device nicht gefunden: {usb_device}")
        return 2
    if usb_image and not Path(usb_image).exists():
        print(f"[anaconda-vm] FAIL: USB-Image nicht gefunden: {usb_image}")
        return 2
    if iso_image and not Path(iso_image).exists():
        print(f"[anaconda-vm] FAIL: ISO nicht gefunden: {iso_image}")
        return 2

    # Match common text-mode Anaconda/installer boot markers.
    markers = re.compile(
        r"(anaconda|starting installer|running anaconda|installing fedora)",
        re.IGNORECASE,
    )

    system = platform.system()
    if system == "Linux":
        return linux_libvirt_flow(usb_device, args.timeout, args.keep_on_fail, markers)
    if system == "Darwin":
        return macos_qemu_flow(
            usb_device,
            usb_image,
            iso_image,
            args.timeout,
            args.keep_on_fail,
            args.gui,
            args.watch_install,
            markers,
        )

    print(f"[anaconda-vm] skipped (Host {system} nicht unterstuetzt)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
