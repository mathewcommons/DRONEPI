#!/bin/bash
# ============================================================
#  DronePI5 - Networked Drone Plugin Suite
#  Raspberry Pi 5 Install Script
#  Compatible with: Raspberry Pi OS Bookworm (64-bit)
#  v1.2 - Fixed package conflicts for Bookworm
# ============================================================

set -e

REPO_URL="https://github.com/mathewcommons/DRONEPI.git"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'

INSTALL_DIR="/opt/dronepi"
WEB_DIR="$INSTALL_DIR/web"
CONFIG_DIR="/etc/dronepi"
LOG_DIR="/var/log/dronepi"
SERVICE_USER="dronepi"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ─── Bootstrap: if run via curl|bash, clone repo first ────────────────────
bootstrap_from_github() {
    # If web/ dir exists next to this script, we're already inside the repo
    if [[ -d "$SCRIPT_DIR/web" ]]; then return 0; fi

    echo -e "${CYAN}[BOOTSTRAP]${NC} Cloning DronePI from GitHub..."
    local CLONE_DIR="/tmp/dronepi-install-$$"
    apt-get install -y -qq git 2>/dev/null || true
    git clone --depth=1 "$REPO_URL" "$CLONE_DIR"
    # Re-exec install.sh from the cloned repo
    exec bash "$CLONE_DIR/install.sh" "$@"
}
FIREWALL_MODE="ufw"   # overridden by detect_firewall_mode()
OS_BOOKWORM=0

print_banner() {
    echo -e "${CYAN}"
    echo "  ██████╗ ██████╗  ██████╗ ███╗   ██╗███████╗██████╗ ██╗"
    echo "  ██╔══██╗██╔══██╗██╔═══██╗████╗  ██║██╔════╝██╔══██╗██║"
    echo "  ██║  ██║██████╔╝██║   ██║██╔██╗ ██║█████╗  ██████╔╝██║"
    echo "  ██║  ██║██╔══██╗██║   ██║██║╚██╗██║██╔══╝  ██╔═══╝ ██║"
    echo "  ██████╔╝██║  ██║╚██████╔╝██║ ╚████║███████╗██║     ██║"
    echo "  ╚═════╝ ╚═╝  ╚═╝ ╚═════╝ ╚═╝  ╚═══╝╚══════╝╚═╝     ╚═╝"
    echo ""
    echo "       Networked Drone Plugin Suite for RPI5  v1.2"
    echo -e "${NC}"
}

log_info()  { echo -e "${GREEN}[INFO]${NC}  $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "\n${BLUE}${BOLD}▶ $1${NC}"; }

# ─── apt helper: install packages, warn on failure instead of aborting ────
apt_install() {
    local desc="$1"; shift
    log_info "Installing: $*"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" \
        "$@" 2>&1 || log_warn "Some packages in '$desc' failed — continuing"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Must run as root: sudo bash install.sh"; exit 1
    fi
}

check_rpi5() {
    log_step "Checking hardware..."
    grep -q "Raspberry Pi 5" /proc/cpuinfo 2>/dev/null \
        && log_info "Raspberry Pi 5 detected ✓" \
        || log_warn "RPI5 not detected — continuing anyway"
    [[ $(uname -m) == "aarch64" ]] \
        && log_info "64-bit OS ✓" \
        || log_warn "Not 64-bit — some plugins may fail"

    # Detect Debian codename — works for Bookworm, Trixie, and future releases
    OS_CODENAME=""
    if command -v lsb_release &>/dev/null; then
        OS_CODENAME=$(lsb_release -sc 2>/dev/null | tr '[:upper:]' '[:lower:]')
    fi
    if [[ -z "$OS_CODENAME" ]]; then
        OS_CODENAME=$(grep -oP '(?<=VERSION_CODENAME=).*' /etc/os-release 2>/dev/null \
                      | tr -d '"' | tr '[:upper:]' '[:lower:]' || echo "unknown")
    fi
    log_info "OS codename: ${OS_CODENAME:-unknown}"

    case "$OS_CODENAME" in
        bookworm) log_info "Raspberry Pi OS Bookworm ✓"; OS_BOOKWORM=1 ;;
        trixie)   log_info "Raspberry Pi OS Trixie (Debian 13) ✓"; OS_BOOKWORM=1 ;;
        *)        log_warn "Codename '$OS_CODENAME' — treating as Bookworm-compatible" ; OS_BOOKWORM=1 ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────
# FIX: ufw Breaks netfilter-persistent on Bookworm (and vice-versa).
#      We detect which is installed/preferred and set FIREWALL_MODE.
# ─────────────────────────────────────────────────────────────────────────
detect_firewall_mode() {
    if dpkg -l netfilter-persistent 2>/dev/null | grep -q "^ii"; then
        log_warn "netfilter-persistent is installed — ufw would conflict, using iptables mode"
        FIREWALL_MODE="iptables"
    elif command -v ufw &>/dev/null; then
        log_info "ufw already present — using ufw mode"
        FIREWALL_MODE="ufw"
    else
        # Neither installed yet — prefer ufw but only if safe
        FIREWALL_MODE="ufw_install"
    fi
}

update_system() {
    log_step "Updating system packages..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get upgrade -y -qq \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold"

    # ── Core build & utility tools ────────────────────────────
    apt_install "core-tools" \
        curl wget git \
        python3 python3-pip python3-venv \
        build-essential cmake pkg-config \
        ninja-build \
        sqlite3 jq \
        net-tools iproute2 \
        avahi-daemon \
        libssl-dev libffi-dev \
        v4l-utils ffmpeg lshw

    # ── Meson (needed for mavlink-router build) ───────────────
    if ! command -v meson &>/dev/null; then
        apt_install "meson" meson || \
        pip3 install meson --break-system-packages 2>/dev/null || \
        pip3 install meson 2>/dev/null || true
    fi

    # ── NetworkManager ────────────────────────────────────────
    apt_install "network-manager" network-manager

    # ── Detect firewall situation BEFORE attempting ufw install ─
    detect_firewall_mode

    if [[ "$FIREWALL_MODE" == "ufw_install" ]]; then
        # Safe to install ufw — netfilter-persistent is not present
        apt_install "ufw" ufw && FIREWALL_MODE="ufw" || FIREWALL_MODE="iptables"
    fi

    log_info "System packages updated ✓"
}

create_dirs() {
    log_step "Creating directories and service user..."
    id "$SERVICE_USER" &>/dev/null || \
        useradd -r -s /bin/bash -d "$INSTALL_DIR" -m "$SERVICE_USER"
    usermod -aG dialout,video,plugdev,netdev "$SERVICE_USER" 2>/dev/null || true
    mkdir -p "$INSTALL_DIR" "$WEB_DIR" "$CONFIG_DIR" "$LOG_DIR"
    mkdir -p "$CONFIG_DIR/plugins"
    chown -R "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR" "$LOG_DIR"
    log_info "Directories created ✓"
}

install_nodejs() {
    log_step "Installing Node.js 20 LTS..."
    if command -v node &>/dev/null; then
        NODE_VER=$(node --version | cut -d. -f1 | tr -d 'v')
        if [[ "$NODE_VER" -ge 18 ]]; then
            log_info "Node.js $(node --version) already present ✓"
            install_pty_deps; return
        fi
    fi
    # Remove stale nodejs first
    apt-get remove -y nodejs nodejs-legacy npm 2>/dev/null || true
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt-get install -y nodejs
    install_pty_deps
    log_info "Node.js $(node --version) ✓"
}

install_pty_deps() {
    # node-pty requires native compilation
    apt_install "node-pty build deps" python3 make g++ libssl-dev
}

install_mavlink_router() {
    log_step "Installing MAVLink Router..."
    if command -v mavlink-routerd &>/dev/null; then
        log_info "MAVLink Router already installed ✓"
    else
        # Build dependencies
        apt_install "mavlink-router build deps" \
            git cmake build-essential pkg-config \
            libsystemd-dev

        # Ensure meson/ninja are present
        command -v meson &>/dev/null || \
            pip3 install meson --break-system-packages 2>/dev/null || true
        command -v ninja &>/dev/null || \
            apt_install "ninja" ninja-build

        cd /tmp && rm -rf mavlink-router
        git clone --depth=1 --recursive \
            https://github.com/mavlink-router/mavlink-router.git
        cd mavlink-router

        # ── Patch meson.build before configure ─────────────────────────────
        # The systemd dep in meson.build is ONLY used to find the systemd unit
        # install directory (systemdsystemunitdir). On Trixie, pkg-config can't
        # resolve it even with libsystemd-dev installed.
        #
        # Fix: pass -Dsystemdsystemunitdir=/lib/systemd/system directly to meson,
        # which skips the entire if-block that calls dependency('systemd').
        # We also patch the if-block out as a belt-and-braces safety measure.
        log_info "Patching meson.build: bypassing systemd unit-dir lookup..."
        # Replace the auto-detect block with a hardcoded safe path
        python3 - << 'PYEOF_INNER'
import re, sys
with open('meson.build', 'r') as f:
    src = f.read()
# Remove the if-block that calls dependency('systemd') for the unit dir
# Replace it with a direct assignment to the standard path
src = re.sub(
    r"if systemd_system_unit_dir == 'auto'.*?endif",
    "if systemd_system_unit_dir == 'auto'\n\tsystemd_system_unit_dir = '/lib/systemd/system'\nendif",
    src, flags=re.DOTALL
)
with open('meson.build', 'w') as f:
    f.write(src)
print("meson.build patched OK")
PYEOF_INNER

        meson setup build . \
            --buildtype=release \
            --wrap-mode=nofallback \
            -Dsystemdsystemunitdir=/lib/systemd/system

        ninja -C build
        ninja -C build install
        cd /
        rm -rf /tmp/mavlink-router
    fi

    cat > "$CONFIG_DIR/mavlink-router.conf" << 'EOF'
[General]
TcpServerPort=5760
ReportStats=false
MavlinkDialect=common

[UartEndpoint FC]
Device=/dev/ttyAMA0
Baud=57600

[UdpEndpoint GCS1]
Mode=Normal
Address=0.0.0.0
Port=14550

[UdpEndpoint GCS2]
Mode=Normal
Address=0.0.0.0
Port=14551

[UdpEndpoint GCS3]
Mode=Normal
Address=0.0.0.0
Port=14552

[UdpEndpoint GCS4]
Mode=Normal
Address=0.0.0.0
Port=14553

[UdpEndpoint GCS5]
Mode=Normal
Address=0.0.0.0
Port=14554

[UdpEndpoint GCS6]
Mode=Normal
Address=0.0.0.0
Port=14555
EOF
    log_info "MAVLink Router installed ✓"
}

install_zerotier() {
    log_step "Installing ZeroTier..."
    if ! command -v zerotier-cli &>/dev/null; then
        curl -s https://install.zerotier.com | bash
    fi
    systemctl enable zerotier-one 2>/dev/null || true
    log_info "ZeroTier installed ✓"
}

install_tailscale() {
    log_step "Installing Tailscale..."
    if ! command -v tailscale &>/dev/null; then
        curl -fsSL https://tailscale.com/install.sh | sh
    fi
    systemctl enable tailscaled 2>/dev/null || true
    log_info "Tailscale installed ✓"
}

install_modem_manager() {
    log_step "Configuring ModemManager..."
    apt_install "modemmanager" \
        modemmanager mobile-broadband-provider-info usb-modeswitch
    systemctl enable ModemManager 2>/dev/null || true
    log_info "ModemManager configured ✓"
}

install_gstreamer() {
    log_step "Installing GStreamer..."
    apt_install "gstreamer-core" \
        gstreamer1.0-tools \
        gstreamer1.0-plugins-base \
        gstreamer1.0-plugins-good \
        gstreamer1.0-plugins-bad \
        gstreamer1.0-plugins-ugly \
        gstreamer1.0-libav \
        libgstreamer1.0-dev \
        libgstreamer-plugins-base1.0-dev \
        v4l-utils libv4l-dev

    # Optional — available on most Bookworm installs but not guaranteed
    apt_install "gstreamer-rtsp"  gstreamer1.0-rtsp  || true
    apt_install "gstreamer-py"    python3-gst-1.0     || true
    log_info "GStreamer installed ✓"
}

install_mediamtx() {
    log_step "Installing MediaMTX..."
    if ! command -v mediamtx &>/dev/null; then
        MEDIAMTX_VER="1.9.1"
        URL="https://github.com/bluenviron/mediamtx/releases/download/v${MEDIAMTX_VER}/mediamtx_v${MEDIAMTX_VER}_linux_arm64v8.tar.gz"
        cd /tmp
        wget -q "$URL" -O mediamtx.tar.gz
        # Extract only the mediamtx binary (skip mediamtx.yml from archive)
        tar -xzf mediamtx.tar.gz mediamtx
        mv mediamtx /usr/local/bin/mediamtx
        chmod +x /usr/local/bin/mediamtx
        rm -f mediamtx.tar.gz
    fi

    cat > "$CONFIG_DIR/mediamtx.yml" << 'EOF'
logLevel: info
logFile: /var/log/dronepi/mediamtx.log
rtspAddress: :8554
rtspsAddress: :8322
rtmpAddress: :1935
hlsAddress: :8888
webrtcAddress: :8889
srtAddress: :8890
paths:
  drone0:
    runOnInit: /usr/bin/ffmpeg -f v4l2 -input_format mjpeg -video_size 1280x720 -framerate 30 -i /dev/video0 -pix_fmt yuv420p -c:v libx264 -preset ultrafast -tune zerolatency -profile:v baseline -level 3.1 -b:v 2000k -g 60 -f rtsp rtsp://localhost:8554/drone0
    runOnInitRestart: yes
  drone1:
    source: publisher
  drone2:
    source: publisher
EOF
    log_info "MediaMTX installed ✓"
}

install_tak_bridge() {
    log_step "Setting up TAK Bridge..."
    mkdir -p "$INSTALL_DIR/tak-bridge"

    pip3 install pytak aiohttp --break-system-packages 2>/dev/null || \
    pip3 install pytak aiohttp 2>/dev/null || \
    log_warn "pytak install failed — TAK Bridge needs manual pip install"

    cat > "$INSTALL_DIR/tak-bridge/tak_bridge.py" << 'PYEOF'
#!/usr/bin/env python3
"""DronePI TAK Bridge — MAVLink -> CoT for TAK/ATAK/WinTAK"""
import asyncio, json, time, logging
from pathlib import Path

CONFIG_FILE = "/etc/dronepi/tak_bridge.json"
LOG = logging.getLogger("tak_bridge")
DEFAULT = {
    "enabled": False, "mavlink_host": "127.0.0.1", "mavlink_port": 14550,
    "tak_host": "239.2.3.1", "tak_port": 6969, "multicast": True,
    "callsign": "DRONE-1", "uid": "DRONEPI-001",
    "cot_type": "a-f-A-M-F-Q", "stale_seconds": 30
}

def load_cfg():
    try:    return {**DEFAULT, **json.loads(Path(CONFIG_FILE).read_text())}
    except: return DEFAULT

def build_cot(lat, lon, alt, cfg):
    now   = time.strftime("%Y-%m-%dT%H:%M:%S.00Z", time.gmtime())
    stale = time.strftime("%Y-%m-%dT%H:%M:%S.00Z",
                          time.gmtime(time.time() + cfg["stale_seconds"]))
    return (f'<?xml version="1.0"?>'
            f'<event version="2.0" uid="{cfg["uid"]}" type="{cfg["cot_type"]}" '
            f'time="{now}" start="{now}" stale="{stale}" how="m-g">'
            f'<point lat="{lat:.7f}" lon="{lon:.7f}" hae="{alt:.2f}" '
            f'ce="9999999" le="9999999"/>'
            f'<detail><contact callsign="{cfg["callsign"]}"/></detail></event>')

async def run():
    cfg = load_cfg()
    if not cfg["enabled"]:
        LOG.info("TAK Bridge disabled — sleeping"); await asyncio.sleep(30); return
    LOG.info(f"TAK Bridge -> {cfg['tak_host']}:{cfg['tak_port']}")
    while True:
        await asyncio.sleep(1)

if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO)
    asyncio.run(run())
PYEOF

    chmod +x "$INSTALL_DIR/tak-bridge/tak_bridge.py"

    cat > "$CONFIG_DIR/tak_bridge.json" << 'EOF'
{
  "enabled": false,
  "mavlink_host": "127.0.0.1",
  "mavlink_port": 14550,
  "tak_host": "239.2.3.1",
  "tak_port": 6969,
  "multicast": true,
  "callsign": "DRONE-1",
  "uid": "DRONEPI-001",
  "cot_type": "a-f-A-M-F-Q",
  "stale_seconds": 30
}
EOF
    log_info "TAK Bridge installed ✓"
}

write_default_config() {
    log_step "Writing default configuration..."
    cat > "$CONFIG_DIR/dronepi.json" << 'EOF'
{
  "version": "1.2.0",
  "system": { "hostname": "dronepi", "web_port": 8080 },
  "plugins": {
    "mavlink_router":  { "enabled": false },
    "zerotier":        { "enabled": false, "network_id": "" },
    "tailscale":       { "enabled": false },
    "modem_manager":   { "enabled": false },
    "gstreamer":       { "enabled": false },
    "mediamtx":        { "enabled": true },
    "tak_bridge":      { "enabled": false }
  },
  "telemetry_endpoints": [
    { "id": 1, "enabled": false, "name": "GCS Primary",    "protocol": "udp", "address": "192.168.1.100", "port": 14550 },
    { "id": 2, "enabled": false, "name": "GCS Secondary",  "protocol": "udp", "address": "192.168.1.101", "port": 14551 },
    { "id": 3, "enabled": false, "name": "Mission Planner","protocol": "tcp", "address": "0.0.0.0",       "port": 14552 },
    { "id": 4, "enabled": false, "name": "QGroundControl", "protocol": "udp", "address": "0.0.0.0",       "port": 14553 },
    { "id": 5, "enabled": false, "name": "Remote Site 1",  "protocol": "udp", "address": "10.0.0.1",      "port": 14554 },
    { "id": 6, "enabled": false, "name": "Remote Site 2",  "protocol": "udp", "address": "10.0.0.2",      "port": 14555 }
  ],
  "video_endpoints": [
    { "id": 1, "enabled": false, "name": "RTSP Primary",  "protocol": "rtsp",   "address": "0.0.0.0", "port": 8554, "path": "/drone0" },
    { "id": 2, "enabled": false, "name": "RTSP Secondary","protocol": "rtsp",   "address": "0.0.0.0", "port": 8554, "path": "/drone1" },
    { "id": 3, "enabled": false, "name": "HLS Stream",    "protocol": "hls",    "address": "0.0.0.0", "port": 8888, "path": "/drone0" },
    { "id": 4, "enabled": false, "name": "WebRTC",        "protocol": "webrtc", "address": "0.0.0.0", "port": 8889, "path": "/drone0" },
    { "id": 5, "enabled": false, "name": "UDP Raw",       "protocol": "udp",    "address": "0.0.0.0", "port": 5600, "path": ""        },
    { "id": 6, "enabled": false, "name": "RTMP Live",     "protocol": "rtmp",   "address": "0.0.0.0", "port": 1935, "path": "/live"   }
  ],
  "video": {
    "source_type": "usb",
    "device": "/dev/video0",
    "width": 1280, "height": 720, "fps": 30,
    "bitrate": 2000, "codec": "h264",
    "pipeline_custom": ""
  }
}
EOF
    chown "$SERVICE_USER:$SERVICE_USER" "$CONFIG_DIR/dronepi.json"
    log_info "Configuration written ✓"
}

install_web_backend() {
    log_step "Installing web backend..."
    if [[ -d "$SCRIPT_DIR/web" ]]; then
        cp -r "$SCRIPT_DIR/web/." "$WEB_DIR/"
    else
        log_warn "web/ not found next to install.sh — skipping copy"
    fi

    if [[ ! -f "$WEB_DIR/package.json" ]]; then
        log_warn "package.json missing — web UI needs manual deployment"; return 0
    fi

    cd "$WEB_DIR"
    # Build native addons (node-pty) from source
    npm install --build-from-source 2>&1 | grep -v "^npm warn" | grep -v "^$" || true
    chown -R "$SERVICE_USER:$SERVICE_USER" "$WEB_DIR"
    log_info "Web backend ready ✓"
}

create_services() {
    log_step "Creating systemd services..."

    cat > /etc/systemd/system/dronepi-web.service << EOF
[Unit]
Description=DronePI Web Management Interface
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$SERVICE_USER
WorkingDirectory=$WEB_DIR
ExecStart=/usr/bin/node $WEB_DIR/server.js
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
Environment=NODE_ENV=production PORT=8080

[Install]
WantedBy=multi-user.target
EOF

    cat > /etc/systemd/system/mavlink-router.service << EOF
[Unit]
Description=MAVLink Router
After=network.target
ConditionPathExists=/usr/local/bin/mavlink-routerd

[Service]
Type=simple
ExecStart=/usr/local/bin/mavlink-routerd -c $CONFIG_DIR/mavlink-router.conf
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    cat > /etc/systemd/system/mediamtx.service << EOF
[Unit]
Description=MediaMTX RTSP/WebRTC Server
After=network.target
ConditionPathExists=/usr/local/bin/mediamtx

[Service]
Type=simple
ExecStart=/usr/local/bin/mediamtx $CONFIG_DIR/mediamtx.yml
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    cat > /etc/systemd/system/tak-bridge.service << EOF
[Unit]
Description=DronePI TAK Bridge
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 $INSTALL_DIR/tak-bridge/tak_bridge.py
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable dronepi-web
    systemctl enable mediamtx

    # ── Sudoers for dronepi user (web UI needs these) ─────────────
    log_info "Setting up passwordless sudo for $SERVICE_USER..."
    cat > /etc/sudoers.d/dronepi << SUDOEOF
$SERVICE_USER ALL=(ALL) NOPASSWD: /usr/sbin/zerotier-cli, /usr/local/bin/zerotier-cli, /usr/bin/systemctl, /usr/bin/tailscale, /usr/bin/mmcli, /usr/bin/journalctl
SUDOEOF
    chmod 440 /etc/sudoers.d/dronepi

    # ── Ensure config files are writable by the service user ──────
    chown "$SERVICE_USER:$SERVICE_USER" "$CONFIG_DIR"/*.yml "$CONFIG_DIR"/*.json "$CONFIG_DIR"/*.conf 2>/dev/null || true

    log_info "Services created ✓"
}

configure_firewall() {
    log_step "Configuring firewall (mode: $FIREWALL_MODE)..."

    PORTS_TCP="22 8080 8554 8322 8888 8889 5760 1935"
    PORTS_UDP="14550 14551 14552 14553 14554 14555 5600"

    if [[ "$FIREWALL_MODE" == "ufw" ]]; then
        ufw --force reset
        ufw default deny incoming
        ufw default allow outgoing
        for p in $PORTS_TCP; do ufw allow ${p}/tcp  comment "DronePI"; done
        for p in $PORTS_UDP; do ufw allow ${p}/udp  comment "DronePI"; done
        ufw allow 14550:14555/udp comment "MAVLink UDP range"
        ufw --force enable
        log_info "UFW configured ✓"
    else
        # iptables fallback — compatible with netfilter-persistent
        iptables -C INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
            iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
        iptables -A INPUT -i lo -j ACCEPT
        for p in $PORTS_TCP; do
            iptables -C INPUT -p tcp --dport $p -j ACCEPT 2>/dev/null || \
            iptables -A INPUT -p tcp --dport $p -j ACCEPT
        done
        for p in $PORTS_UDP; do
            iptables -C INPUT -p udp --dport $p -j ACCEPT 2>/dev/null || \
            iptables -A INPUT -p udp --dport $p -j ACCEPT
        done
        iptables -A INPUT -p udp --dport 14550:14555 -j ACCEPT
        # Persist rules
        mkdir -p /etc/iptables
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
        apt_install "iptables-persistent" iptables-persistent || true
        log_info "iptables rules applied ✓"
    fi
}

print_done() {
    IP=$(hostname -I | awk '{print $1}')
    echo ""
    echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}${BOLD}║     DronePI5 Installation Complete! 🚁  v1.2    ║${NC}"
    echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${CYAN}Web GUI:${NC}       http://$IP:8080"
    echo -e "  ${CYAN}Config file:${NC}   $CONFIG_DIR/dronepi.json"
    echo -e "  ${CYAN}Firewall mode:${NC} $FIREWALL_MODE"
    echo ""
    echo -e "  ${YELLOW}Start the interface:${NC}"
    echo -e "  sudo systemctl start dronepi-web"
    echo ""
    echo -e "  ${YELLOW}Live logs:${NC}"
    echo -e "  sudo journalctl -u dronepi-web -f"
    echo ""
}

# ─── MAIN ────────────────────────────────────────────────────────────────
main() {
    print_banner
    check_root
    bootstrap_from_github "$@"
    check_rpi5
    update_system          # also calls detect_firewall_mode
    create_dirs
    install_nodejs
    install_mavlink_router
    install_zerotier
    install_tailscale
    install_modem_manager
    install_gstreamer
    install_mediamtx
    install_tak_bridge
    write_default_config
    install_web_backend
    create_services
    configure_firewall
    print_done
}

main "$@"
