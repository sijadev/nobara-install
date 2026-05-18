#!/usr/bin/env bash
# build-rpm.sh — baut fedora-autoinstall RPM und aktualisiert rpm/repodata.
#
# Nutzt lokal rpmbuild falls vorhanden, sonst Podman-Fallback.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
RPM_DIR="${PROJECT_DIR}/rpm"
SPEC_FILE="${RPM_DIR}/fedora-autoinstall.spec"
HOST_OS="$(uname -s)"
PODMAN_PLATFORM="linux/amd64"

if [[ -t 1 ]]; then
    RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; CYAN=$'\033[36m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
else
    RED=""; GREEN=""; YELLOW=""; CYAN=""; BOLD=""; RESET=""
fi
log()  { echo -e "${GREEN}[build-rpm]${RESET} $*"; }
warn() { echo -e "${YELLOW}[build-rpm]${RESET} $*" >&2; }
die()  { echo -e "${RED}[build-rpm] $*${RESET}" >&2; exit 1; }
step() { echo -e "\n${CYAN}${BOLD}══ $* ══${RESET}"; }

[[ -f "$SPEC_FILE" ]] || die "Spec-Datei fehlt: $SPEC_FILE"

NAME="$(awk '/^Name:/ {print $2; exit}' "$SPEC_FILE")"
VERSION="$(awk '/^Version:/ {print $2; exit}' "$SPEC_FILE")"
[[ -n "$NAME" && -n "$VERSION" ]] || die "Name/Version konnten aus Spec nicht gelesen werden."

SRC_BASENAME="${NAME}-${VERSION}"
SRC_TARBALL="${RPM_DIR}/${SRC_BASENAME}.tar.gz"

create_source_tarball() {
    local stage_root stage_dir
    stage_root="$(mktemp -d -t build-rpm-src-XXXXXX)"
    stage_dir="${stage_root}/${SRC_BASENAME}"
    mkdir -p "$stage_dir"

    # Vollständige Projektkopie, ohne Build-Artefakte/VC-Metadaten.
    rsync -a \
        --exclude '.git' \
        --exclude '.venv' \
        --exclude '__pycache__' \
        --exclude '.pytest_cache' \
        --exclude '*.pyc' \
        --exclude 'iso/*.iso' \
        --exclude 'rpm/*.rpm' \
        --exclude 'rpm/repodata' \
        "${PROJECT_DIR}/" "${stage_dir}/"

    tar -C "$stage_root" -czf "$SRC_TARBALL" "$SRC_BASENAME"
    rm -rf "$stage_root"

    log "Source-Tarball erstellt: ${SRC_TARBALL}"
}

refresh_repo_metadata_local() {
    if command -v createrepo_c >/dev/null 2>&1; then
        createrepo_c --update "$RPM_DIR" >/dev/null
        log "Repo-Metadaten aktualisiert (createrepo_c)."
        return 0
    fi
    if command -v createrepo >/dev/null 2>&1; then
        createrepo --update "$RPM_DIR" >/dev/null
        log "Repo-Metadaten aktualisiert (createrepo)."
        return 0
    fi
    return 1
}

build_with_local_rpmbuild() {
    local topdir spec_copy
    step "RPM lokal bauen (rpmbuild)"
    topdir="$(mktemp -d -t rpmbuild-XXXXXX)"
    mkdir -p "$topdir"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}

    spec_copy="${topdir}/SPECS/$(basename "$SPEC_FILE")"
    cp "$SPEC_FILE" "$spec_copy"
    cp "$SRC_TARBALL" "${topdir}/SOURCES/${SRC_BASENAME}.tar.gz"

    rpmbuild -bb --define "_topdir ${topdir}" "$spec_copy"

    cp -f "${topdir}"/RPMS/*/*.rpm "$RPM_DIR/"
    rm -rf "$topdir"

    log "RPM lokal gebaut und nach rpm/ kopiert."
}

build_with_podman() {
    step "RPM via Podman bauen"
    command -v podman >/dev/null 2>&1 || die "Weder rpmbuild noch podman verfugbar."

    if ! podman info >/dev/null 2>&1; then
        if [[ "$HOST_OS" == "Darwin" ]]; then
            warn "Podman Machine ist nicht aktiv — starte sie."
            podman machine start >/dev/null
        fi
    fi
    podman info >/dev/null 2>&1 || die "Podman ist nicht bereit."

    podman run --rm \
        --platform "${PODMAN_PLATFORM}" \
        -v "${PROJECT_DIR}:/src:Z" \
        fedora:latest \
        /bin/bash -lc "
            set -euo pipefail
            dnf -y install rpm-build tar gzip findutils createrepo_c >/dev/null
            TOP=/tmp/rpmbuild
            mkdir -p \"\$TOP\"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}
            cp /src/rpm/fedora-autoinstall.spec \"\$TOP/SPECS/\"
            cp /src/rpm/${SRC_BASENAME}.tar.gz \"\$TOP/SOURCES/\"
            rpmbuild -bb --define \"_topdir \$TOP\" \"\$TOP/SPECS/fedora-autoinstall.spec\"
            cp -f \"\$TOP\"/RPMS/*/*.rpm /src/rpm/
            createrepo_c --update /src/rpm >/dev/null
        "

    log "RPM via Podman gebaut und Repo-Metadaten aktualisiert."
}

step "RPM Build vorbereiten"
create_source_tarball

if command -v rpmbuild >/dev/null 2>&1; then
    build_with_local_rpmbuild
    if ! refresh_repo_metadata_local; then
        warn "createrepo(_c) lokal nicht gefunden — versuche Repo-Metadaten via Podman."
        build_with_podman
    fi
else
    build_with_podman
fi

rm -f "$SRC_TARBALL"
log "Fertig. RPM-Dateien in: ${RPM_DIR}"
