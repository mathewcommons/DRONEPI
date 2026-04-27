#!/usr/bin/env python3
"""DronePI TAK Bridge — MAVLink -> CoT for TAK/ATAK/WinTAK

Connects to mavlink-router on TCP :5760, reads GLOBAL_POSITION_INT,
builds Cursor-on-Target XML, and sends via UDP to a TAK server or
multicast group.
"""
import asyncio
import json
import logging
import socket
import struct
import time
from pathlib import Path

CONFIG_FILE = "/etc/dronepi/tak_bridge.json"
LOG = logging.getLogger("tak_bridge")

DEFAULT_CFG = {
    "enabled": False,
    "mavlink_host": "127.0.0.1",
    "mavlink_port": 5760,
    "tak_host": "239.2.3.1",
    "tak_port": 6969,
    "multicast": True,
    "callsign": "DRONE-1",
    "uid": "DRONEPI-001",
    "cot_type": "a-f-A-M-F-Q",
    "stale_seconds": 30,
    "update_interval": 1,
}


def load_cfg():
    try:
        return {**DEFAULT_CFG, **json.loads(Path(CONFIG_FILE).read_text())}
    except Exception:
        return dict(DEFAULT_CFG)


def build_cot(lat, lon, alt, cfg):
    now = time.strftime("%Y-%m-%dT%H:%M:%S.00Z", time.gmtime())
    stale = time.strftime(
        "%Y-%m-%dT%H:%M:%S.00Z",
        time.gmtime(time.time() + cfg["stale_seconds"]),
    )
    return (
        f'<?xml version="1.0"?>'
        f'<event version="2.0" uid="{cfg["uid"]}" type="{cfg["cot_type"]}" '
        f'time="{now}" start="{now}" stale="{stale}" how="m-g">'
        f'<point lat="{lat:.7f}" lon="{lon:.7f}" hae="{alt:.2f}" '
        f'ce="9999999" le="9999999"/>'
        f'<detail><contact callsign="{cfg["callsign"]}"/>'
        f"<track speed=\"0\" course=\"0\"/>"
        f"</detail></event>"
    )


def create_udp_socket(cfg):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    if cfg["multicast"]:
        ttl = struct.pack("b", 32)
        sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, ttl)
    return sock


async def run():
    cfg = load_cfg()
    if not cfg["enabled"]:
        LOG.info("TAK Bridge disabled in config — waiting 60s then exiting")
        await asyncio.sleep(60)
        return

    LOG.info(
        f"TAK Bridge starting: MAVLink tcp:{cfg['mavlink_host']}:{cfg['mavlink_port']} "
        f"-> CoT {cfg['tak_host']}:{cfg['tak_port']} "
        f"({'multicast' if cfg['multicast'] else 'unicast'})"
    )

    # Import pymavlink here so the script doesn't crash on import if disabled
    from pymavlink import mavutil

    udp_sock = create_udp_socket(cfg)
    dest = (cfg["tak_host"], cfg["tak_port"])
    interval = cfg.get("update_interval", 1)

    while True:
        mav = None
        try:
            LOG.info(f"Connecting to mavlink-router at tcp:{cfg['mavlink_host']}:{cfg['mavlink_port']}")
            mav = mavutil.mavlink_connection(
                f"tcp:{cfg['mavlink_host']}:{cfg['mavlink_port']}",
                source_system=254,
                source_component=1,
            )
            LOG.info("Connected, waiting for heartbeat...")
            mav.wait_heartbeat(timeout=30)
            LOG.info(f"Heartbeat from system {mav.target_system}")

            while True:
                msg = mav.recv_match(
                    type="GLOBAL_POSITION_INT", blocking=True, timeout=5
                )
                if msg is None:
                    continue

                lat = msg.lat / 1e7
                lon = msg.lon / 1e7
                alt = msg.alt / 1000.0

                # Skip if no GPS fix (0,0)
                if lat == 0.0 and lon == 0.0:
                    continue

                cot = build_cot(lat, lon, alt, cfg)
                udp_sock.sendto(cot.encode("utf-8"), dest)
                LOG.debug(f"CoT sent: {lat:.5f},{lon:.5f} alt={alt:.0f}m")
                await asyncio.sleep(interval)

        except Exception as e:
            LOG.warning(f"MAVLink connection error: {e} — retrying in 5s")
            if mav:
                try:
                    mav.close()
                except Exception:
                    pass
            await asyncio.sleep(5)


if __name__ == "__main__":
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(name)s] %(levelname)s %(message)s",
    )
    asyncio.run(run())
