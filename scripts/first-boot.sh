#!/usr/bin/env bash
# scripts/first-boot.sh — System-wide one-shot provisioning (runs as root via systemd)
#
# Executed by fedora-first-boot.service exactly once after the first boot.
# Marker: /var/lib/fedora-provision/first-boot.done
#
# Tasks:
#   1. System-Update (dnf update)
#   5. Ensure GUI boot path (graphical.target + GDM)

set -euo pipefail

MARKER_DIR="/var/lib/fedora-provision"
MARKER_FILE="$MARKER_DIR/first-boot.done"
LOG_FILE="/var/log/fedora-first-boot.log"
ENV_FILE="/etc/fedora-provision.env"

exec > >(tee -a "$LOG_FILE") 2>&1

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO]  $*"; }
warn() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN]  $*"; }
err()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $*" >&2; }
die()  { err "$*"; exit 1; }
step() { echo; echo "══ $* ══"; }

systemd_available() {
    command -v systemctl >/dev/null 2>&1 || return 1
    [[ -d /run/systemd/system ]] || return 1
    systemctl show-environment >/dev/null 2>&1 || return 1
}

systemctl_safe() {
    if systemd_available; then
        systemctl "$@"
    else
        warn "systemctl $* uebersprungen (kein systemd als PID 1)."
        return 0
    fi
}

run_dnf_retry() {
    local max_attempts="${DNF_RETRY_MAX:-3}"
    local sleep_seconds="${DNF_RETRY_SLEEP:-4}"
    local attempt=1
    while true; do
        if "$@"; then
            return 0
        fi
        if (( attempt >= max_attempts )); then
            return 1
        fi
        warn "DNF command failed (attempt ${attempt}/${max_attempts}), retrying in ${sleep_seconds}s: $*"
        sleep "${sleep_seconds}"
        attempt=$((attempt + 1))
    done
}

is_headless_profile() {
    [[ "${INSTALL_PROFILE:-full}" =~ ^(headless-vllm|vllm-only)$ ]]
}

is_container() {
    # Detect podman/docker/systemd-nspawn container environments.
    # Kernel install hangs in containers (dracut can't build initramfs).
    [[ -f /run/.containerenv ]] || \
    [[ -f /.dockerenv ]] || \
    systemd-detect-virt --container >/dev/null 2>&1 || \
    [[ "$(cat /proc/1/comm 2>/dev/null || true)" != "systemd" ]]
}

ensure_gui_boot_path() {
    local exit_code="${1:-0}"

    if is_headless_profile; then
        log "Headless profile detected — GUI boot path skipped."
        return 0
    fi

    log "Ensuring GUI boot path (graphical.target)..."
    systemctl set-default graphical.target 2>/dev/null \
        && log "Default target set to graphical.target." \
        || warn "Failed to set default target to graphical.target."
}

on_exit_first_boot() {
    local rc="$1"
    set +e
    ensure_gui_boot_path "$rc"
    if (( rc != 0 )); then
        err "First-boot provisioning failed with exit code ${rc}."
    fi
    return "$rc"
}

# ── Idempotency guard ─────────────────────────────────────────────────────────
if [[ -f "$MARKER_FILE" ]]; then
    log "First-boot already completed (marker exists: $MARKER_FILE). Skipping."
    exit 0
fi

mkdir -p "$MARKER_DIR"

# ── Load provisioning env ─────────────────────────────────────────────────────
if [[ -f "$ENV_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$ENV_FILE"
fi

INSTALL_PROFILE="${FEDORA_INSTALL_PROFILE:-full}"
log "Install profile: ${INSTALL_PROFILE}"

trap 'on_exit_first_boot $?' EXIT

# ── 0. DNF Optimierungen ─────────────────────────────────────────────────────
step "DNF Optimierungen"
cat >> /etc/dnf/dnf.conf <<'DNFEOF'
max_parallel_downloads=10
fastestmirror=True
deltarpm=True
DNFEOF
log "DNF: max_parallel_downloads=10, fastestmirror, deltarpm."

# ── 0b. Flathub einrichten (system-wide remote) ───────────────────────────────
step "Flathub"
if command -v flatpak &>/dev/null; then
    flatpak remote-add --if-not-exists --system flathub \
        https://flathub.org/repo/flathub.flatpakrepo 2>/dev/null \
        && log "Flathub system-weit hinzugefügt." \
        || warn "Flathub setup fehlgeschlagen (non-fatal)."
fi

# ── 0c. fstrim (SSD TRIM wöchentlich) ────────────────────────────────────────
step "fstrim.timer"
systemctl enable fstrim.timer 2>/dev/null \
    && log "fstrim.timer aktiviert." \
    || warn "fstrim.timer enable fehlgeschlagen (non-fatal)."

# ── 1. System-Update ──────────────────────────────────────────────────────────
step "System-Update"
log "Running dnf update..."
if run_dnf_retry dnf update -y --refresh; then
    log "dnf update completed."
else
    warn "dnf update failed — continuing provisioning with current package state."
fi

# ── 1a. RPM Fusion (NVIDIA packages) ──────────────────────────────────────────
step "RPM Fusion Repos"
FEDORA_VER="$(rpm -E %fedora)"
run_dnf_retry dnf install -y \
    "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${FEDORA_VER}.noarch.rpm" \
    "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${FEDORA_VER}.noarch.rpm" \
    || warn "RPM Fusion release package install failed (non-fatal)."
dnf config-manager setopt rpmfusion-nonfree-nvidia-driver.enabled=1 >/dev/null 2>&1 || true
run_dnf_retry dnf makecache || warn "dnf makecache failed after repo setup (non-fatal)."
log "Repo setup complete (RPM Fusion + metadata refresh)."

# ── 1b. CachyOS Kernel (BORE-Scheduler + Performance-Patches) ─────────────────
# CachyOS-Kernel bietet BORE-Scheduler, io_uring-Optimierungen und
# Blackwell-Kompatibilität. Muss VOR akmod-nvidia-open installiert werden,
# damit Module gegen den richtigen Kernel gebaut werden.
step "CachyOS Kernel installieren"
if is_container; then
    log "Container-Umgebung erkannt — Kernel-Installation übersprungen (dracut nicht verfügbar)."
elif [[ "${FEDORA_KERNEL_SOURCE:-cachyos}" != "fedora" ]]; then
    if dnf copr enable -y bieszczaders/kernel-cachyos 2>/dev/null; then
        if run_dnf_retry dnf install -y \
            kernel-cachyos \
            kernel-cachyos-devel 2>/dev/null; then
            log "CachyOS-Kernel installiert."
            if command -v grubby &>/dev/null; then
                NEW_KERNEL=$(ls /boot/vmlinuz-*cachyos* 2>/dev/null | sort -V | tail -1 || true)
                if [[ -n "$NEW_KERNEL" ]]; then
                    grubby --set-default "$NEW_KERNEL" \
                        && log "CachyOS-Kernel als Default gesetzt: $(basename "$NEW_KERNEL")" \
                        || warn "grubby --set-default fehlgeschlagen."
                fi
            fi
        else
            warn "CachyOS-Kernel install fehlgeschlagen — Standard-Kernel bleibt aktiv."
        fi
    else
        warn "COPR bieszczaders/kernel-cachyos nicht verfügbar — Standard-Kernel bleibt aktiv."
    fi
else
    log "FEDORA_KERNEL_SOURCE=fedora — CachyOS-Kernel übersprungen."
fi

# ── 2b. Podman + NVIDIA Container Toolkit (headless-vllm / full) ──────────────
if [[ "$INSTALL_PROFILE" =~ ^(headless-vllm|vllm-only|full)$ ]]; then
    step "Podman + NVIDIA Container Toolkit"

    dnf install -y podman podman-compose 2>/dev/null \
        && log "Podman installiert." \
        || warn "Podman install fehlgeschlagen (non-fatal)."

    # NVIDIA Container Toolkit — GPU-Passthrough in Podman/Docker
    if lspci -nn 2>/dev/null | grep -qi 'NVIDIA'; then
        if ! rpm -q nvidia-container-toolkit &>/dev/null; then
            curl -s -L https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo \
                -o /etc/yum.repos.d/nvidia-container-toolkit.repo 2>/dev/null
            dnf install -y nvidia-container-toolkit 2>/dev/null \
                && log "nvidia-container-toolkit installiert." \
                || warn "nvidia-container-toolkit fehlgeschlagen (non-fatal)."
        fi
        nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml 2>/dev/null \
            && log "NVIDIA CDI-Profil generiert." \
            || warn "nvidia-ctk CDI fehlgeschlagen (non-fatal)."
    fi

    # ── vLLM via Podman Quadlet (systemd Container Service) ───────────────────
    # Multi-Model Hotswap: ein einziges parametrisiertes Quadlet-Template
    # (vllm@.container) startet vllm-Backends on-demand. Router auf :8000
    # dispatched OpenAI-Requests an aktive Backends (Quelle: vllm-router.py).
    TARGET_USER="${FEDORA_TARGET_USER:-sija}"
    USER_HOME="/home/${TARGET_USER}"
    AUDIO_MODEL="${FEDORA_AUDIO_MODEL:-moonshotai/Kimi-Audio-7B-Instruct}"
    AGENT_MODEL="${FEDORA_AGENT_MODEL:-Qwen/Qwen3-8B}"
    QUADLET_DIR="${USER_HOME}/.config/containers/systemd"
    ROUTER_DIR="${USER_HOME}/.config/vllm-router"
    REPO_DIR="/usr/local/share/fedora-autoinstall"
    mkdir -p "$QUADLET_DIR" "$ROUTER_DIR/instances"

    # ── Cleanup: alte statische Quadlets entfernen (Migration) ───────────────
    for old in vllm-audio.container vllm-agent.container; do
        if [[ -f "${QUADLET_DIR}/${old}" ]]; then
            systemctl --user --machine="${TARGET_USER}@" stop "${old%.container}.service" 2>/dev/null || true
            rm -f "${QUADLET_DIR}/${old}"
            log "Alt-Quadlet entfernt: ${old}"
        fi
    done

    # ── Quadlet-Template + Router-Unit installieren ───────────────────────────
    if [[ -f "${REPO_DIR}/systemd/vllm@.container" ]]; then
        install -m 0644 "${REPO_DIR}/systemd/vllm@.container" "${QUADLET_DIR}/vllm@.container"
    else
        warn "vllm@.container Template fehlt unter ${REPO_DIR}/systemd/ — Build unvollständig?"
    fi
    if [[ -f "${REPO_DIR}/systemd/vllm-router.service" ]]; then
        mkdir -p "${USER_HOME}/.config/systemd/user"
        install -m 0644 "${REPO_DIR}/systemd/vllm-router.service" \
            "${USER_HOME}/.config/systemd/user/vllm-router.service"
    fi

    # ── Default-Registry seeden (falls noch keine vorhanden) ──────────────────
    REGISTRY="${ROUTER_DIR}/models.json"
    if [[ ! -f "$REGISTRY" ]]; then
        cat > "$REGISTRY" <<REGEOF
{
  "agent": {
    "hf_repo": "${AGENT_MODEL}",
    "port": 8100,
    "vram_share": 0.45,
    "max_len": 8192,
    "extra": "--enable-reasoning --reasoning-parser deepseek_r1"
  },
  "audio": {
    "hf_repo": "${AUDIO_MODEL}",
    "port": 8101,
    "vram_share": 0.40,
    "max_len": 4096,
    "extra": "--trust-remote-code --limit-mm-per-prompt audio=5"
  }
}
REGEOF
        log "Default-Registry geseedet: $REGISTRY"
    fi

    chown -R "${TARGET_USER}:${TARGET_USER}" \
        "$QUADLET_DIR" "$ROUTER_DIR" "${USER_HOME}/.config/systemd" 2>/dev/null || true

    log "vLLM Quadlet-Template installiert (vllm@.container)."
    log "Router-Service-Unit installiert (vllm-router.service)."
    log "Registry: $REGISTRY  — bearbeiten zum Modelle hinzufügen."
    log "Aktivierung erfolgt im first-login (loginctl linger + enable)."
fi

# ── 2. NVIDIA Open Driver + CUDA (nvidia-cuda Profil) ────────────────────────
if [[ "$INSTALL_PROFILE" == "nvidia-cuda" ]]; then
    step "NVIDIA Open Driver"

    if ! lspci -nn 2>/dev/null | grep -qi 'NVIDIA'; then
        warn "Kein NVIDIA GPU erkannt — NVIDIA/CUDA Installation übersprungen."
    elif is_container; then
        warn "Container-Umgebung erkannt — NVIDIA/CUDA Installation übersprungen."
    else
        # kernel-devel für den aktuell laufenden Kernel — akmods braucht die Headers
        # um das Modul noch während first-boot zu bauen (vor dem ersten CachyOS-Boot).
        run_dnf_retry dnf install -y \
            "kernel-devel-$(uname -r)" \
            akmod-nvidia-open \
            xorg-x11-drv-nvidia-cuda \
            && log "NVIDIA Open Driver + xorg-cuda installiert." \
            || warn "NVIDIA Open Driver Installation fehlgeschlagen (non-fatal)."

        # Nouveau dauerhaft blacklisten — kollidiert sonst beim Boot mit nvidia-open.
        cat > /etc/modprobe.d/blacklist-nouveau.conf <<'MEOF'
blacklist nouveau
options nouveau modeset=0
MEOF
        grubby --update-kernel=ALL \
            --args="modprobe.blacklist=nouveau rd.driver.blacklist=nouveau nvidia-drm.modeset=1" \
            2>/dev/null \
            && log "GRUB: nouveau blacklist + nvidia-drm.modeset=1 gesetzt." \
            || warn "grubby NVIDIA-Kernel-Args fehlgeschlagen (non-fatal)."

        nvidia_module_ok=0
        if command -v akmods &>/dev/null; then
            log "Building kernel modules (akmods) für alle installierten Kernel..."
            # --force baut für JEDEN Kernel mit verfügbaren Headers:
            # aktueller Fedora-Kernel (kernel-devel) + CachyOS (kernel-cachyos-devel)
            if akmods --force; then
                nvidia_module_ok=1
                log "akmods: NVIDIA-Modul erfolgreich gebaut."
            else
                warn "akmods fehlgeschlagen — NVIDIA-Modul nicht verfügbar."
            fi
        fi

        if [[ "$nvidia_module_ok" -eq 1 ]]; then
            # Initramfs für alle Kernel neu bauen damit NVIDIA-Modul eingebunden ist.
            dracut --regenerate-all --force 2>/dev/null \
                && log "Initramfs für alle Kernel rebuilt (NVIDIA)." \
                || warn "dracut --regenerate-all fehlgeschlagen (non-fatal)."
        else
            # NVIDIA-Modul nicht verfügbar — Fedora-Kernel als sicherer Fallback.
            FALLBACK_KERNEL=$(ls /boot/vmlinuz-[0-9]* 2>/dev/null \
                | grep -v cachyos | sort -V | tail -1 || true)
            if [[ -n "$FALLBACK_KERNEL" ]]; then
                grubby --set-default "$FALLBACK_KERNEL" \
                    && log "Fallback: Fedora-Kernel als Default gesetzt: $(basename "$FALLBACK_KERNEL")" \
                    || warn "grubby --set-default Fallback fehlgeschlagen (non-fatal)."
            fi
        fi

        step "CUDA Toolkit (NVIDIA-Repo)"
        CUDA_ARCH=$(uname -m)
        CUDA_FEDORA_VER=$(. /etc/os-release && echo "$VERSION_ID")
        CUDA_DISTRO="fedora${CUDA_FEDORA_VER}"
        CUDA_REPO_URL="https://developer.download.nvidia.com/compute/cuda/repos/${CUDA_DISTRO}/${CUDA_ARCH}/cuda-${CUDA_DISTRO}.repo"

        if ! curl -sfI "$CUDA_REPO_URL" >/dev/null; then
            log "Kein CUDA-Repo für Fedora ${CUDA_FEDORA_VER} — Fallback auf fedora43."
            CUDA_DISTRO="fedora43"
            CUDA_REPO_URL="https://developer.download.nvidia.com/compute/cuda/repos/${CUDA_DISTRO}/${CUDA_ARCH}/cuda-${CUDA_DISTRO}.repo"
        fi

        if ! dnf config-manager --add-repo "$CUDA_REPO_URL" 2>/dev/null; then
            dnf config-manager addrepo --from-repofile="$CUDA_REPO_URL" \
                || warn "CUDA-Repo konnte nicht hinzugefügt werden."
        fi

        run_dnf_retry dnf makecache || true
        run_dnf_retry dnf install -y cuda-toolkit \
            && log "CUDA Toolkit installiert." \
            || warn "CUDA Toolkit Installation fehlgeschlagen (non-fatal)."

        # System-weite CUDA Umgebungsvariablen
        CUDA_HOME_DETECTED=""
        for candidate in /usr/local/cuda /usr/local/cuda-* /usr; do
            if [[ -x "${candidate}/bin/nvcc" ]]; then
                CUDA_HOME_DETECTED="$candidate"; break
            fi
        done
        if [[ -n "$CUDA_HOME_DETECTED" ]]; then
            cat > /etc/profile.d/cuda.sh <<ENVEOF
export CUDA_HOME="${CUDA_HOME_DETECTED}"
export PATH="\${CUDA_HOME}/bin\${PATH:+:\$PATH}"
export LD_LIBRARY_PATH="\${CUDA_HOME}/lib64\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
ENVEOF
            chmod 0644 /etc/profile.d/cuda.sh
            log "CUDA Umgebung gesetzt: ${CUDA_HOME_DETECTED}"
        fi

        # NVIDIA Persistence Mode Service
        cat > /etc/systemd/system/nvidia-performance.service <<'NVEOF'
[Unit]
Description=NVIDIA Persistence Mode
After=multi-user.target
ConditionPathExists=/usr/bin/nvidia-smi

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/nvidia-smi -pm 1
ExecStop=/usr/bin/nvidia-smi  -pm 0

[Install]
WantedBy=multi-user.target
NVEOF
        systemctl_safe daemon-reload
        systemctl enable nvidia-performance.service 2>/dev/null \
            && log "nvidia-performance.service aktiviert." \
            || warn "nvidia-performance.service enable fehlgeschlagen (non-fatal)."
    fi
fi

# ── 4b. Theme-Abhängigkeiten + GNOME Extensions ──────────────────────────────
step "Theme dependencies + GNOME Extensions"
if [[ "$INSTALL_PROFILE" =~ ^(full|theme-bash)$ ]]; then
    run_dnf_retry dnf install -y \
        sassc \
        glib2-devel \
        zenity \
        gnome-shell-extension-user-theme \
        gnome-shell-extension-dash-to-dock \
        gnome-shell-extension-caffeine \
        gnome-shell-extension-appindicator \
        gnome-shell-extension-blur-my-shell \
        2>/dev/null \
        && log "Theme deps + GNOME Extensions installiert." \
        || warn "Theme deps/extensions install fehlgeschlagen (non-fatal)."
fi

# ── 5. Kernel/Sysctl performance tuning ──────────────────────────────────────
step "Kernel/Sysctl tuning"

cat > /etc/sysctl.d/99-fedora-performance.conf <<'SYSCTLEOF'
# Fedora Auto-Install: performance tuning
vm.swappiness = 10
vm.vfs_cache_pressure = 50
kernel.sched_migration_cost_ns = 500000
net.core.somaxconn = 1024
SYSCTLEOF
chmod 0644 /etc/sysctl.d/99-fedora-performance.conf
sysctl --system 2>&1 | grep -E 'Applying|error' | while read -r l; do log "  sysctl: $l"; done || true
log "Sysctl tuning applied."

# Transparent Hugepages: madvise (opt-in per Prozess — PyTorch/vLLM nutzen es gezielt)
cat > /etc/tmpfiles.d/transparent-hugepages.conf <<'THPEOF'
w /sys/kernel/mm/transparent_hugepage/enabled - - - - madvise
w /sys/kernel/mm/transparent_hugepage/defrag  - - - - defer+madvise
THPEOF
chmod 0644 /etc/tmpfiles.d/transparent-hugepages.conf
echo madvise        > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
echo defer+madvise  > /sys/kernel/mm/transparent_hugepage/defrag  2>/dev/null || true
log "Transparent hugepages: madvise (per tmpfiles.d persistent)."

# ── 6. CPU Performance Governor (tuned) ───────────────────────────────────────
step "CPU performance profile"

if ! command -v tuned-adm &>/dev/null; then
    dnf install -y tuned && log "tuned installed." || warn "tuned install failed (non-fatal)."
fi

if command -v tuned-adm &>/dev/null; then
    cat > /usr/local/bin/fedora-cpu-profile <<'CPUWRAPEOF'
#!/usr/bin/env bash
set -euo pipefail

mode="${1:-podman}"

case "$mode" in
    podman)
        # Bestehendes Podman/vLLM-Verhalten: throughput + schedutil
        /usr/sbin/tuned-adm profile throughput-performance >/dev/null 2>&1 || true
        for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
            echo schedutil > "$f" 2>/dev/null || true
        done
        ;;
    bitwig)
        # Audio-optimiertes Profil fuer DAW/Recording: latency-performance + performance-Governor
        /usr/sbin/tuned-adm profile latency-performance >/dev/null 2>&1 || true
        for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
            echo performance > "$f" 2>/dev/null || true
        done
        ;;
    balanced)
        /usr/sbin/tuned-adm profile balanced >/dev/null 2>&1 || true
        ;;
    *)
        echo "Usage: $0 {podman|bitwig|balanced}" >&2
        exit 2
        ;;
esac
CPUWRAPEOF
    chmod 0755 /usr/local/bin/fedora-cpu-profile

    # tuned: throughput-performance für Disk/IRQ/Netzwerk
    # CPU-Governor wird danach von cpu-schedutil.service auf schedutil gesetzt
    # (scx_bpfland arbeitet mit schedutil, nicht performance)
    cat > /etc/systemd/system/cpu-performance.service <<'CPUEOF'
[Unit]
Description=System throughput profile via tuned (Disk/IRQ/Net)
After=tuned.service
Requires=tuned.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/fedora-cpu-profile podman
ExecStop=/usr/local/bin/fedora-cpu-profile balanced

[Install]
WantedBy=multi-user.target
CPUEOF

    # schedutil Override: läuft nach tuned und setzt Governor zurück
    # scx_bpfland braucht schedutil für korrekte Frequenzskalierung
    cat > /etc/systemd/system/cpu-schedutil.service <<'SUTILEOF'
[Unit]
Description=Set CPU Governor to schedutil (für scx_bpfland)
After=cpu-performance.service
Wants=cpu-performance.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c 'for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo schedutil > "$f" 2>/dev/null || true; done'

[Install]
WantedBy=multi-user.target
SUTILEOF

    systemctl_safe daemon-reload
    systemctl enable tuned.service           2>/dev/null || true
    systemctl enable cpu-performance.service 2>/dev/null || true
    systemctl enable cpu-schedutil.service   2>/dev/null || true
    systemctl start  tuned.service           2>/dev/null || true
    /usr/local/bin/fedora-cpu-profile podman 2>/dev/null \
        && log "tuned: throughput-performance aktiv (Disk/IRQ/Net)." \
        || warn "tuned-adm fehlgeschlagen (non-fatal)."
    log "CPU Governor: schedutil (kompatibel mit scx_bpfland)."
fi

# ── 6b. scx_bpfland Scheduler ─────────────────────────────────────────────────
step "scx_bpfland Scheduler"
if ! rpm -q scx-scheds &>/dev/null; then
    if ! dnf copr list --enabled 2>/dev/null | grep -q 'bieszczaders'; then
        dnf copr enable -y bieszczaders/kernel-cachyos-addons 2>/dev/null || true
    fi
    dnf install -y scx-scheds scx-tools 2>/dev/null \
        && log "scx-scheds + scx-tools installiert (COPR bieszczaders)." \
        || warn "scx-scheds install fehlgeschlagen (non-fatal)."
fi

if command -v scx_bpfland &>/dev/null; then
    # scx_bpfland als direkter systemd-Service (einfacher als scx_loader)
    cat > /etc/systemd/system/scx-bpfland.service <<'SCXEOF'
[Unit]
Description=scx_bpfland — Cache-aware scheduler für AMD Ryzen
Documentation=https://github.com/sched-ext/scx
After=multi-user.target
# Nach cpu-schedutil damit Governor bereits schedutil ist
After=cpu-schedutil.service

[Service]
Type=simple
ExecStart=/usr/bin/scx_bpfland
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
SCXEOF
    systemctl_safe daemon-reload
    systemctl enable scx-bpfland.service 2>/dev/null \
        && log "scx-bpfland.service aktiviert." \
        || warn "scx-bpfland enable fehlgeschlagen (non-fatal)."
fi

# ── 8. WhiteSur GRUB Theme ───────────────────────────────────────────────────
step "WhiteSur GRUB Theme"
if [[ "$INSTALL_PROFILE" =~ ^(full|theme-bash|vm)$ ]]; then
    GRUB_THEMES_DIR="/tmp/grub2-themes-build"
    if ! git clone --depth=1 "https://github.com/vinceliuice/grub2-themes.git" \
            "$GRUB_THEMES_DIR" 2>/dev/null; then
        warn "grub2-themes clone fehlgeschlagen (non-fatal)."
    elif [[ -x "${GRUB_THEMES_DIR}/install.sh" ]]; then
        # Auflösung erkennen: 1080p als Standard, 4k falls höher
        GRUB_RES="1080p"
        bash "${GRUB_THEMES_DIR}/install.sh" -t whitesur -s "${GRUB_RES}" 2>/dev/null \
            && log "WhiteSur GRUB Theme installiert (${GRUB_RES})." \
            || warn "GRUB Theme install fehlgeschlagen (non-fatal)."
        rm -rf "$GRUB_THEMES_DIR"
    fi
fi

# ── 9. Timeshift + grub-btrfs (nur bei Btrfs-Root) ───────────────────────────
if findmnt -n -o FSTYPE / 2>/dev/null | grep -qx 'btrfs'; then
    step "Timeshift + grub-btrfs"
    # timeshift ist in Fedora-Repos verfügbar
    dnf install -y timeshift inotify-tools 2>/dev/null \
        && log "timeshift + inotify-tools installiert." \
        || warn "timeshift install fehlgeschlagen (non-fatal)."

    # grub-btrfs ist direkt in Fedora-Repos verfügbar (kein COPR nötig)
    if ! rpm -q grub-btrfs &>/dev/null; then
        run_dnf_retry dnf install -y grub-btrfs \
            && log "grub-btrfs installiert." \
            || warn "grub-btrfs install fehlgeschlagen (non-fatal)."
    fi

    # Bei Btrfs-Subvolumes enthält SOURCE den Subvolume-Pfad (z.B. /dev/vda3[@])
    # → nur den Device-Teil extrahieren
    BTRFS_DEV=$(findmnt -n -o SOURCE / | sed 's/\[.*\]$//')
    BTRFS_UUID=$(blkid -s UUID -o value "$BTRFS_DEV" 2>/dev/null || true)

    # btrfs qgroups für Timeshift aktivieren
    btrfs quota enable / 2>/dev/null || true

    if [[ -n "$BTRFS_UUID" ]] && command -v timeshift &>/dev/null; then
        mkdir -p /etc/timeshift
        cat > /etc/timeshift/timeshift.json <<TIMESHIFTEOF
{
  "backup_device_uuid" : "${BTRFS_UUID}",
  "parent_device_size" : "0",
  "do_first_run" : "false",
  "btrfs_mode" : "true",
  "include_btrfs_home_for_backup" : "false",
  "stop_cron_emails" : "true",
  "btrfs_use_qgroup" : "true",
  "schedule_monthly" : "true",
  "schedule_weekly" : "false",
  "schedule_daily" : "false",
  "schedule_hourly" : "false",
  "schedule_boot" : "true",
  "count_monthly" : "3",
  "count_weekly" : "3",
  "count_daily" : "5",
  "count_hourly" : "6",
  "count_boot" : "5"
}
TIMESHIFTEOF
        chmod 0644 /etc/timeshift/timeshift.json
        log "Timeshift konfiguriert: BTRFS-Modus, UUID=${BTRFS_UUID}."
    fi

    # BLS-Entries auf das aktuell gemountete Btrfs-Subvolume aktualisieren.
    # Fedora-Autopart nutzt nicht zwingend "@"; falsche rootflags führen zu
    # "failed to mount sysroot.mount" beim nächsten Boot.
    if command -v grubby &>/dev/null; then
        ROOT_SOURCE=$(findmnt -n -o SOURCE / 2>/dev/null || true)
        ROOT_SUBVOL=$(printf '%s' "$ROOT_SOURCE" | sed -n 's/.*\[\([^]]\+\)\]$/\1/p')
        if [[ -n "$ROOT_SUBVOL" ]]; then
            grubby --update-kernel=ALL --remove-args='rootflags' --args="rootflags=subvol=${ROOT_SUBVOL}" \
                && log "grubby: BLS-Entries auf rootflags=subvol=${ROOT_SUBVOL} gesetzt." \
                || warn "grubby update fehlgeschlagen (non-fatal)."
        else
            warn "Btrfs-Subvolume konnte nicht erkannt werden; rootflags bleiben unverändert."
        fi
    fi

    # grub-btrfs: Snapshots automatisch im GRUB-Menü registrieren
    if systemctl list-unit-files grub-btrfs.path &>/dev/null; then
        systemctl enable --now grub-btrfs.path 2>/dev/null \
            && log "grub-btrfs.path aktiviert." \
            || warn "grub-btrfs.path enable fehlgeschlagen (non-fatal)."
    fi
    grub2-mkconfig -o /boot/grub2/grub.cfg 2>/dev/null \
        && log "GRUB-Konfiguration aktualisiert." \
        || warn "grub2-mkconfig fehlgeschlagen (non-fatal)."
else
    log "Root ist kein btrfs — Timeshift/grub-btrfs übersprungen."
fi

# ── 10. zram-generator (Swap im RAM — Pflicht ohne Swap-Partition) ───────────
step "zram-generator"
if ! rpm -q zram-generator &>/dev/null; then
    dnf install -y zram-generator \
        && log "zram-generator installiert." \
        || warn "zram-generator install fehlgeschlagen (non-fatal)."
fi
# Konfiguration: 50% RAM, max 8 GB, zstd-Kompression
cat > /etc/systemd/zram-generator.conf <<'ZRAMEOF'
[zram0]
zram-size = min(ram / 2, 8192)
compression-algorithm = zstd
ZRAMEOF
chmod 0644 /etc/systemd/zram-generator.conf
log "zram-generator: 50% RAM (max 8 GB), zstd."

# ── 11. irqbalance (IRQ-Verteilung auf alle CPU-Kerne) ───────────────────────
step "irqbalance"
if ! rpm -q irqbalance &>/dev/null; then
    dnf install -y irqbalance \
        && log "irqbalance installiert." \
        || warn "irqbalance install fehlgeschlagen (non-fatal)."
fi
# --now vermeiden: systemctl start schlägt im DNF-Kontext fehl (kein D-Bus)
systemctl enable irqbalance 2>/dev/null \
    && log "irqbalance aktiviert (startet beim nächsten Boot)." \
    || warn "irqbalance enable fehlgeschlagen (non-fatal)."

# ── 12. ananicy-cpp (Prozess-Priorisierung) ──────────────────────────────────
step "ananicy-cpp"
if ! rpm -q ananicy-cpp &>/dev/null; then
    # tschmitz/ananicy-cpp unterstützt Fedora 43
    if dnf copr enable -y tschmitz/ananicy-cpp &>/dev/null; then
        dnf install -y ananicy-cpp \
            && log "ananicy-cpp installiert." \
            || warn "ananicy-cpp install fehlgeschlagen (non-fatal)."
    else
        warn "ananicy-cpp COPR nicht verfügbar — übersprungen (non-fatal)."
    fi
fi
if command -v ananicy-cpp &>/dev/null; then
    systemctl enable ananicy-cpp 2>/dev/null \
        && log "ananicy-cpp aktiviert (startet beim nächsten Boot)." \
        || warn "ananicy-cpp enable fehlgeschlagen (non-fatal)."
fi

# ── 13. AMD Ryzen Optimierungen ──────────────────────────────────────────────
if grep -qi 'amd\|ryzen\|epyc' /proc/cpuinfo 2>/dev/null; then
    step "AMD Ryzen optimizations"

    # amd-pstate EPP auf 'performance' setzen (persistent via systemd-Service)
    cat > /etc/systemd/system/amd-pstate-epp.service <<'AMDEOF'
[Unit]
Description=AMD P-State Energy Performance Preference (performance)
After=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c 'for f in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do echo performance > "$f" 2>/dev/null || true; done'

[Install]
WantedBy=multi-user.target
AMDEOF
    systemctl daemon-reload
    systemctl enable amd-pstate-epp.service 2>/dev/null \
        && log "amd-pstate-epp.service aktiviert." \
        || warn "amd-pstate-epp enable fehlgeschlagen (non-fatal)."
    # Sofort anwenden
    for f in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do
        echo performance > "$f" 2>/dev/null || true
    done
    log "AMD P-State EPP auf 'performance' gesetzt."

    # GRUB Kernel-Parameter für Ryzen
    GRUB_FILE="/etc/default/grub"
    if [[ -f "$GRUB_FILE" ]] && ! grep -q 'amd_pstate' "$GRUB_FILE"; then
        sed -i 's/GRUB_CMDLINE_LINUX="\(.*\)"/GRUB_CMDLINE_LINUX="\1 amd_pstate=active amd_iommu=on cpufreq.default_governor=performance"/' \
            "$GRUB_FILE"
        grub2-mkconfig -o /boot/grub2/grub.cfg 2>/dev/null \
            && log "GRUB: AMD Kernel-Parameter eingetragen." \
            || warn "grub2-mkconfig fehlgeschlagen (non-fatal)."
    else
        log "GRUB AMD-Parameter bereits vorhanden oder grub-config nicht gefunden."
    fi
else
    log "Kein AMD CPU erkannt — AMD Ryzen Optimierungen übersprungen."
fi

# ── First-Login Setup ────────────────────────────────────────────────────────
step "First-Login Setup"
TARGET_USER="${FEDORA_TARGET_USER:-sija}"
USER_HOME="/home/${TARGET_USER}"
REPO_DIR="/usr/local/share/fedora-autoinstall"
if id -u "$TARGET_USER" >/dev/null 2>&1; then
    TARGET_USER_EXISTS=1
else
    TARGET_USER_EXISTS=0
    warn "Target user '${TARGET_USER}' existiert nicht — user-spezifische First-Login Schritte werden ubersprungen."
fi

# first-login.sh ins System installieren
if [[ -f "${REPO_DIR}/scripts/first-login.sh" ]]; then
    install -m 0755 "${REPO_DIR}/scripts/first-login.sh" /usr/local/sbin/fedora-first-login.sh
    log "fedora-first-login.sh installiert."
else
    warn "first-login.sh nicht gefunden unter ${REPO_DIR}/scripts/ — Autostart nicht eingerichtet."
fi

# welcome-dialog.sh + fedora-provision.desktop system-weit installieren
# → App erscheint dauerhaft im GNOME App-Menü
if [[ -f "${REPO_DIR}/scripts/welcome-dialog.sh" ]]; then
    install -m 0755 "${REPO_DIR}/scripts/welcome-dialog.sh" /usr/local/bin/fedora-welcome-dialog.sh
    log "fedora-welcome-dialog.sh installiert."
fi
if [[ -f "${REPO_DIR}/scripts/fedora-provision.desktop" ]]; then
    install -m 0644 "${REPO_DIR}/scripts/fedora-provision.desktop" \
        /usr/share/applications/fedora-provision.desktop
    update-desktop-database /usr/share/applications/ 2>/dev/null || true
    log "fedora-provision.desktop in /usr/share/applications/ installiert."
fi

# Autostart-Desktop-Datei für den Ziel-User einrichten
AUTOSTART_DIR="${USER_HOME}/.config/autostart"
MARKER="${USER_HOME}/.local/share/fedora-provision/first-login.done"
if [[ "$TARGET_USER_EXISTS" -eq 1 ]] && [[ ! -f "$MARKER" ]] && [[ -x /usr/local/sbin/fedora-first-login.sh ]]; then
    mkdir -p "$AUTOSTART_DIR"
    cat > "${AUTOSTART_DIR}/fedora-first-login.desktop" <<'DEOF'
[Desktop Entry]
Type=Application
Name=Fedora First Login
Exec=/usr/local/sbin/fedora-first-login.sh
Icon=preferences-system
Terminal=false
StartupNotify=false
X-GNOME-Autostart-enabled=true
DEOF
    chown -R "${TARGET_USER}:${TARGET_USER}" "$AUTOSTART_DIR"
    log "Autostart-Eintrag gesetzt: ${AUTOSTART_DIR}/fedora-first-login.desktop"
elif [[ "$TARGET_USER_EXISTS" -eq 0 ]]; then
    warn "Autostart-Eintrag ubersprungen (User fehlt): ${TARGET_USER}"
fi

# Sudoers-Regel: sija darf GNOME Extension RPMs ohne Passwort installieren
SUDOERS_FILE="/etc/sudoers.d/fedora-first-login"
if [[ ! -f "$SUDOERS_FILE" ]]; then
    cat > "$SUDOERS_FILE" <<SUDEOF
# Passwordless dnf (first-login) + cpu-profile switch (Bitwig wrapper)
${TARGET_USER} ALL=(root) NOPASSWD: /usr/bin/dnf, /usr/local/bin/fedora-cpu-profile
SUDEOF
    chmod 0440 "$SUDOERS_FILE"
    visudo -c -f "$SUDOERS_FILE" \
        && log "sudoers: ${TARGET_USER} NOPASSWD dnf install gesetzt." \
        || { warn "sudoers-Datei ungültig — wird entfernt."; rm -f "$SUDOERS_FILE"; }
fi

# ── Done ──────────────────────────────────────────────────────────────────────
step "First-boot provisioning complete"
marker_set() { mkdir -p "$(dirname "$1")"; touch "$1"; }
marker_set "$MARKER_FILE"
log "Marker written: $MARKER_FILE"
log "First-boot provisioning finished successfully."
