#version=RHEL9
# Fedora Linux — VM Smoke Test
# Minimale Installation zum Testen des Boot- und Anaconda-Starts in QEMU.
# Ziel: nur verifizieren dass Anaconda bootet und die Installation beginnt.

text
reboot

# ── Locale / Keyboard / Timezone ─────────────────────────────────────────────
keyboard --xlayouts='de'
lang de_DE.UTF-8
timezone Europe/Berlin --utc

# ── Network ───────────────────────────────────────────────────────────────────
network --bootproto=dhcp --device=link --activate

# ── Authentication ────────────────────────────────────────────────────────────
rootpw --lock
user --groups=wheel --name=test --plaintext --password=test

# ── Partitionierung ───────────────────────────────────────────────────────────
# In QEMU: vda = Install-Disk (40G qcow2), vdb = USB-Raw-Device.
# ignoredisk stellt sicher dass nur vda verwendet wird.
ignoredisk --only-use=vda
clearpart --all --initlabel --drives=vda
autopart --type=plain --nohome

bootloader --disabled

# ── Packages ──────────────────────────────────────────────────────────────────
%packages --inst-langs=en
@core
kernel
%end
