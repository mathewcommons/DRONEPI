# DronePI5

Networked drone plugin suite for Raspberry Pi 5. Provides a web-based management interface for video streaming, MAVLink telemetry routing, ZeroTier/Tailscale networking, and TAK integration.

## Quick Install

```bash
curl -fsSL https://raw.githubusercontent.com/mathewcommons/DRONEPI/main/install.sh | sudo bash
```

Or clone and run manually:

```bash
git clone https://github.com/mathewcommons/DRONEPI.git
cd DRONEPI
sudo bash install.sh
```

## What It Does

- **Video Pipeline** - FFmpeg captures from USB/CSI camera, encodes H.264, publishes via MediaMTX (RTSP/WebRTC/HLS/RTMP)
- **Web UI** - Management dashboard at `http://<pi-ip>:8080` with live video preview, pipeline controls, terminal, and plugin management
- **MAVLink Router** - Routes MAVLink telemetry from flight controller to multiple GCS endpoints
- **ZeroTier / Tailscale** - VPN overlay networking for remote access
- **TAK Bridge** - MAVLink to Cursor-on-Target conversion for ATAK/WinTAK
- **ModemManager** - LTE modem support

## Requirements

- Raspberry Pi 5 (64-bit OS)
- Raspberry Pi OS Bookworm or Trixie
- USB or CSI camera (tested with Logitech C270)

## After Install

- Web UI: `http://<pi-ip>:8080`
- RTSP: `rtsp://<pi-ip>:8554/drone0`
- WebRTC: `http://<pi-ip>:8889/drone0/`
- Default user: `dronepi`

## Project Structure

```
install.sh          # Main installer (also works via curl|bash)
web/
  server.js         # Express + WebSocket backend
  package.json      # Node.js dependencies
  public/
    index.html      # Single-page web UI
config/
  *.default         # Default configuration templates
```
