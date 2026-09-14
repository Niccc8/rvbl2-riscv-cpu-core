#!/usr/bin/env bash
# setup_openlane_wsl.sh - one-time setup for running the OpenLane flow locally.
#
# Run this ONCE, inside WSL, from any directory:
#
#     bash /mnt/c/Users/user/Desktop/A/riscv_championchip/chipinventor/scripts/setup_openlane_wsl.sh
#
# It will ask for your sudo password (Docker installs system-wide; nothing else
# here needs root). Everything is idempotent - re-running it after a failure
# picks up where it left off rather than starting over.
#
# Docker Engine is installed natively in the distro rather than via Docker
# Desktop: systemd is already enabled here (/etc/wsl.conf has systemd=true), so
# dockerd runs as an ordinary service and the Desktop integration layer buys us
# nothing.
set -eu

OPENLANE_DIR=${OPENLANE_DIR:-$HOME/OpenLane}

# Pinned from the platform's own synthesis log. These two hashes are the whole
# point of the exercise: they are what make a local run comparable to a run on
# the platform. Do not bump them without re-reading a fresh platform log.
OPENLANE_COMMIT=3876562d27af3f6825a823941b1cab36f7eb6dc3
OPEN_PDKS_COMMIT=bdc9412b3e468c102d01b7cf6337be06ec6e9c9a

say()  { printf '\n\033[1m=== %s\033[0m\n' "$1"; }
ok()   { printf 'OK   %s\n' "$1"; }
die()  { printf 'FAIL %s\n' "$1" >&2; exit 1; }

[ -f /proc/version ] && grep -qi microsoft /proc/version \
    || die "this is meant to run inside WSL, not on the Windows side"

# ---------------------------------------------------------------------------
say "1/5  Docker Engine"
if command -v docker > /dev/null 2>&1 && docker info > /dev/null 2>&1; then
    ok "docker $(docker --version | awk '{print $3}' | tr -d ,) is installed and running"
else
    if ! command -v docker > /dev/null 2>&1; then
        echo "Installing Docker Engine from Docker's apt repository..."
        sudo apt-get update -qq
        sudo apt-get install -y -qq ca-certificates curl python3-pip
        sudo install -m 0755 -d /etc/apt/keyrings
        sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
            -o /etc/apt/keyrings/docker.asc
        sudo chmod a+r /etc/apt/keyrings/docker.asc
        . /etc/os-release
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
            | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
        sudo apt-get update -qq
        sudo apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin
    fi
    sudo systemctl enable --now docker
    sudo usermod -aG docker "$USER"

    # Group membership is read at login, so the current shell still cannot talk
    # to the socket. Stopping here with a clear instruction beats every later
    # step failing with a permission error.
    if ! docker info > /dev/null 2>&1; then
        cat <<'EOF'

Docker is installed, but this shell is not in the `docker` group yet.

  1. From PowerShell:  wsl --shutdown
  2. Reopen WSL and re-run this script.

(The shutdown also picks up the new C:\Users\user\.wslconfig memory settings.)
EOF
        exit 2
    fi
    ok "docker installed"
fi

docker run --rm hello-world > /dev/null 2>&1 \
    || die "docker cannot run containers - check 'sudo systemctl status docker'"
ok "containers run without sudo"

# ---------------------------------------------------------------------------
say "2/5  OpenLane at the pinned commit"
# On the Linux filesystem, never under /mnt/c: the 9p mount is roughly an order
# of magnitude slower and a full flow writes tens of thousands of small files.
case "$OPENLANE_DIR" in
    /mnt/*) die "OPENLANE_DIR is on the Windows mount ($OPENLANE_DIR) - use a path under \$HOME" ;;
esac

if [ ! -d "$OPENLANE_DIR/.git" ]; then
    git clone https://github.com/The-OpenROAD-Project/OpenLane.git "$OPENLANE_DIR"
fi
cd "$OPENLANE_DIR"
git fetch --quiet origin "$OPENLANE_COMMIT" 2>/dev/null || git fetch --quiet origin
git checkout --quiet "$OPENLANE_COMMIT"
[ "$(git rev-parse HEAD)" = "$OPENLANE_COMMIT" ] || die "checkout did not land on $OPENLANE_COMMIT"
ok "OpenLane at $OPENLANE_COMMIT"

# ---------------------------------------------------------------------------
say "3/5  Toolchain image and sky130A PDK"
# `make pdk` builds a venv to install volare into. Debian/Ubuntu ship the venv
# module without ensurepip, so `python3 -m venv` imports fine but cannot create
# an environment - the only honest test is to actually create one.
VENVTEST=$(mktemp -d)
if python3 -m venv "$VENVTEST/v" > /dev/null 2>&1; then
    ok "python3 -m venv works"
else
    echo "Installing python3-venv / python3-pip (needed by 'make pdk')..."
    sudo apt-get update -qq
    sudo apt-get install -y -qq python3-venv python3-pip \
        || sudo apt-get install -y -qq "python$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')-venv" python3-pip
    python3 -m venv "$VENVTEST/v2" > /dev/null 2>&1 \
        || die "python3 -m venv still fails - install python3-venv by hand"
    ok "python3-venv installed"
fi
rm -rf "$VENVTEST"

# The repo's own pin is already correct at this commit - dependencies/
# tool_metadata.yml names open_pdks bdc9412b, exactly what the platform's log
# reports - so the default `make` (get-openlane + pdk) installs the right one.
grep -q "$OPEN_PDKS_COMMIT" dependencies/tool_metadata.yml \
    && ok "tool_metadata.yml pins open_pdks $OPEN_PDKS_COMMIT (the platform's)" \
    || printf 'note tool_metadata.yml does not name %s - step 4 will force it\n' "$OPEN_PDKS_COMMIT"
make
ok "image pulled and PDK installed"

# ---------------------------------------------------------------------------
say "4/5  The installed PDK is actually the platform's"
# `make pdk` runs `volare enable --pdk sky130` with no explicit version, so
# verify what actually landed rather than trusting the resolution.
PDK_ROOT=${PDK_ROOT:-$HOME/.volare}
export PDK_ROOT

# Volare records the enabled version in a marker file and points $PDK_ROOT/sky130A
# at .../versions/<hash>/sky130A - so the hash is the symlink target's PARENT
# directory, not its basename. The marker path has moved between volare
# releases, hence two probes before the symlink fallback.
enabled_version() {
    local v
    for m in "$PDK_ROOT/volare/sky130/current" "$PDK_ROOT/volare/sky130/etc/current"; do
        [ -f "$m" ] && { tr -d '[:space:]' < "$m"; return; }
    done
    v=$(readlink -f "$PDK_ROOT/sky130A" 2>/dev/null) && [ -n "$v" ] \
        && basename "$(dirname "$v")"
}

if [ "$(enabled_version)" != "$OPEN_PDKS_COMMIT" ]; then
    printf 'note enabled PDK is "%s", forcing %s\n' "$(enabled_version)" "$OPEN_PDKS_COMMIT"
    ./venv/bin/volare enable --pdk sky130 "$OPEN_PDKS_COMMIT" \
        || die "could not enable open_pdks $OPEN_PDKS_COMMIT"
fi
[ "$(enabled_version)" = "$OPEN_PDKS_COMMIT" ] \
    || die "PDK is still $(enabled_version), expected $OPEN_PDKS_COMMIT"
ok "sky130A at $OPEN_PDKS_COMMIT is enabled"

[ -d "$PDK_ROOT/sky130A/libs.ref/sky130_fd_sc_hd" ] \
    || die "sky130_fd_sc_hd not found under $PDK_ROOT/sky130A/libs.ref"
ok "sky130_fd_sc_hd is present (PDK_ROOT=$PDK_ROOT)"

# ---------------------------------------------------------------------------
say "5/5  Smoke test (the bundled spm design)"
# Proves Docker, the PDK and the flow all work BEFORE our design is involved,
# so any later failure is unambiguously ours rather than the install's.
if make test; then
    ok "spm ran end to end - the install is sound"
else
    die "the bundled smoke test failed - fix the install before running our design"
fi

cat <<EOF

========================================
 Setup complete.

 Next:
   bash $(cd "$(dirname "$0")" && pwd)/run_openlane_local.sh
========================================
EOF
