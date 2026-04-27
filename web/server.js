/**
 * DronePI5 Web Management Backend
 * Express + WebSocket server with live terminal (node-pty)
 */
const express = require('express');
const expressWs = require('express-ws');
const { exec, spawn } = require('child_process');
const fs = require('fs');
const path = require('path');
const os = require('os');

let pty;
try { pty = require('node-pty'); } catch { pty = null; }

const app = express();
expressWs(app);

const PORT = process.env.PORT || 8080;
const CONFIG_FILE = '/etc/dronepi/dronepi.json';
const CONFIG_DIR  = '/etc/dronepi';
const LOG_DIR     = '/var/log/dronepi';

// ─── Middleware ────────────────────────────────────────────────────────────
app.use(express.json());
app.use(express.static(path.join(__dirname, 'public')));

// ─── Config helpers ────────────────────────────────────────────────────────
function readConfig() {
    try { return JSON.parse(fs.readFileSync(CONFIG_FILE, 'utf8')); }
    catch { return {}; }
}
function writeConfig(cfg) {
    fs.writeFileSync(CONFIG_FILE, JSON.stringify(cfg, null, 2));
}
function execCmd(cmd) {
    return new Promise((res, rej) => {
        exec(cmd, { timeout: 15000 }, (err, stdout, stderr) => {
            if (err) rej(stderr || err.message); else res(stdout.trim());
        });
    });
}

// ─── System info ──────────────────────────────────────────────────────────
function getSystemInfo() {
    const uptime = os.uptime();
    const loadAvg = os.loadavg();
    const totalMem = os.totalmem();
    const freeMem = os.freemem();
    return {
        hostname: os.hostname(), uptime,
        load: loadAvg[0].toFixed(2),
        memUsed: Math.round((totalMem - freeMem) / 1024 / 1024),
        memTotal: Math.round(totalMem / 1024 / 1024),
        platform: os.platform(), arch: os.arch(), timestamp: Date.now()
    };
}

async function getServiceStatus(name) {
    try { const o = await execCmd(`systemctl is-active ${name} 2>/dev/null`); return o.trim() === 'active'; }
    catch { return false; }
}

// ─── Routes: Config ────────────────────────────────────────────────────────
app.get('/api/config', (req, res) => res.json(readConfig()));
app.post('/api/config', (req, res) => {
    try { const cfg = readConfig(); Object.assign(cfg, req.body); writeConfig(cfg); res.json({ ok: true }); }
    catch (e) { res.status(500).json({ ok: false, error: e.message }); }
});

// ─── Routes: System ────────────────────────────────────────────────────────
app.get('/api/system', (req, res) => res.json(getSystemInfo()));
app.get('/api/system/cpu-temp', async (req, res) => {
    try { const r = fs.readFileSync('/sys/class/thermal/thermal_zone0/temp','utf8'); res.json({ temp: (parseInt(r)/1000).toFixed(1) }); }
    catch { res.json({ temp: null }); }
});
app.get('/api/system/network', (req, res) => {
    try {
        const ifaces = os.networkInterfaces();
        const result = {};
        for (const [name, addrs] of Object.entries(ifaces)) result[name] = addrs.filter(a => !a.internal);
        res.json(result);
    } catch(e) { res.status(500).json({ error: e.message }); }
});

// ─── Routes: Services ──────────────────────────────────────────────────────
const SERVICE_MAP = {
    mavlink_router: 'mavlink-router', zerotier: 'zerotier-one',
    tailscale: 'tailscaled', modem_manager: 'ModemManager',
    mediamtx: 'mediamtx', tak_bridge: 'tak-bridge', gstreamer: 'dronepi-gstreamer'
};

app.get('/api/services', async (req, res) => {
    const s = {};
    for (const [k, v] of Object.entries(SERVICE_MAP)) s[k] = await getServiceStatus(v);
    res.json(s);
});

app.post('/api/services/:plugin', async (req, res) => {
    const { plugin } = req.params; const { enabled } = req.body;
    const svc = SERVICE_MAP[plugin];
    if (!svc) return res.status(404).json({ error: 'Unknown plugin' });
    try {
        await execCmd(`sudo systemctl ${enabled ? 'start' : 'stop'} ${svc}`);
        const cfg = readConfig();
        if (cfg.plugins?.[plugin]) { cfg.plugins[plugin].enabled = enabled; writeConfig(cfg); }
        res.json({ ok: true });
    } catch(e) { res.status(500).json({ ok: false, error: String(e) }); }
});

// ─── Routes: Telemetry / Video endpoints ───────────────────────────────────
app.get('/api/telemetry', (req, res) => res.json(readConfig().telemetry_endpoints || []));
app.post('/api/telemetry', async (req, res) => {
    try {
        const cfg = readConfig(); cfg.telemetry_endpoints = req.body; writeConfig(cfg); await regenerateMavlinkConfig(cfg);
        try { await execCmd('sudo /usr/bin/systemctl restart mavlink-router'); } catch {}
        res.json({ ok: true });
    } catch(e) { res.status(500).json({ ok: false, error: e.message }); }
});
app.get('/api/video/endpoints', (req, res) => res.json(readConfig().video_endpoints || []));
app.post('/api/video/endpoints', async (req, res) => {
    try {
        const cfg = readConfig();
        cfg.video_endpoints = req.body;
        writeConfig(cfg);
        fs.writeFileSync(MEDIAMTX_CONFIG_FILE, generateMediamtxYml(cfg));
        try { await execCmd('sudo systemctl restart mediamtx'); } catch {}
        res.json({ ok: true });
    } catch(e) { res.status(500).json({ ok: false, error: e.message }); }
});
app.get('/api/video/config', (req, res) => res.json(readConfig().video || {}));
app.post('/api/video/config', async (req, res) => {
    try {
        const cfg = readConfig();
        cfg.video = { ...cfg.video, ...req.body };
        writeConfig(cfg);
        fs.writeFileSync(MEDIAMTX_CONFIG_FILE, generateMediamtxYml(cfg));
        try { await execCmd('sudo systemctl restart mediamtx'); } catch {}
        res.json({ ok: true });
    } catch(e) { res.status(500).json({ ok: false, error: e.message }); }
});

// ─── Routes: Video Apply & Status ─────────────────────────────────────────
app.post('/api/video/apply', async (req, res) => {
    try {
        const cfg = readConfig();
        fs.writeFileSync(MEDIAMTX_CONFIG_FILE, generateMediamtxYml(cfg));
        await execCmd('sudo systemctl restart mediamtx');
        res.json({ ok: true });
    } catch(e) { res.status(500).json({ ok: false, error: String(e) }); }
});

app.get('/api/video/status', async (req, res) => {
    try {
        const mediamtx_active = await getServiceStatus('mediamtx');

        let ffmpeg_running = false;
        let ffmpeg_pid = null;
        let publishing_path = null;
        try {
            const pidOut = await execCmd("pgrep -f 'ffmpeg.*rtsp://localhost'");
            if (pidOut) {
                ffmpeg_running = true;
                ffmpeg_pid = parseInt(pidOut.split('\n')[0], 10) || null;
            }
        } catch {}

        if (ffmpeg_running) {
            try {
                const psOut = await execCmd("ps aux | grep 'ffmpeg.*rtsp://localhost' | grep -v grep");
                const m = psOut.match(/rtsp:\/\/localhost:\d+\/(\S+)/);
                if (m) publishing_path = m[1];
            } catch {}
        }

        let uptime = null;
        if (mediamtx_active) {
            try {
                const propOut = await execCmd('systemctl show mediamtx --property=ActiveEnterTimestamp');
                const ts = propOut.replace('ActiveEnterTimestamp=', '').trim();
                if (ts) {
                    const started = new Date(ts);
                    const diff = Math.floor((Date.now() - started.getTime()) / 1000);
                    const h = Math.floor(diff / 3600);
                    const m = Math.floor((diff % 3600) / 60);
                    const s = diff % 60;
                    uptime = `${h}h ${m}m ${s}s`;
                }
            } catch {}
        }

        res.json({ mediamtx_active, ffmpeg_running, ffmpeg_pid, publishing_path, uptime });
    } catch(e) { res.status(500).json({ error: e.message }); }
});

// ─── Routes: Video Devices ─────────────────────────────────────────────────
app.get('/api/video/devices', async (req, res) => {
    try {
        const devices = [];
        const out = await execCmd('v4l2-ctl --list-devices 2>/dev/null || echo ""');
        const lines = out.split('\n');
        let currentName = '';
        // Skip internal Pi ISP (pispbe) and decoder devices - only list real cameras
        const skipPrefixes = ['pispbe', 'rpi-hevc', 'rpi-h264', 'bcm2835'];
        for (const line of lines) {
            if (!line.startsWith('\t') && !line.startsWith(' ') && line.trim()) {
                currentName = line.replace(/\s*\(.*\)\s*:?\s*$/, '').trim();
            } else if (line.trim().startsWith('/dev/video')) {
                const skip = skipPrefixes.some(p => currentName.toLowerCase().startsWith(p));
                if (!skip && !devices.find(d => d.name === currentName)) {
                    devices.push({ path: line.trim(), name: currentName || line.trim() });
                }
            }
        }
        if (!devices.length) devices.push({ path: '/dev/video0', name: 'Default Camera' });
        res.json(devices);
    } catch { res.json([{ path: '/dev/video0', name: 'Default Camera' }]); }
});

// ─── Routes: GStreamer ─────────────────────────────────────────────────────
let gstProcess = null;
app.post('/api/video/pipeline/start', async (req, res) => {
    const { pipeline } = req.body;
    if (!pipeline) return res.status(400).json({ error: 'No pipeline' });
    if (gstProcess) { gstProcess.kill(); gstProcess = null; }
    try {
        gstProcess = spawn('gst-launch-1.0', pipeline.split(/\s+/).filter(Boolean));
        res.json({ ok: true, pid: gstProcess.pid });
    } catch(e) { res.status(500).json({ ok: false, error: e.message }); }
});
app.post('/api/video/pipeline/stop', (req, res) => {
    if (gstProcess) { gstProcess.kill(); gstProcess = null; }
    res.json({ ok: true });
});

// ─── Input sanitizer (prevent command injection) ──────────────────────────
function sanitizeArg(str) {
    return String(str || '').replace(/[^a-zA-Z0-9._\-]/g, '');
}

// ─── Routes: ZeroTier / Tailscale / Modem ─────────────────────────────────
app.get('/api/zerotier/status', async (req, res) => {
    try { res.json({ output: await execCmd('sudo /usr/sbin/zerotier-cli status 2>/dev/null') }); }
    catch { res.json({ output: 'ZeroTier not running' }); }
});
app.post('/api/zerotier/join', async (req, res) => {
    const nid = sanitizeArg(req.body.network_id);
    if (!nid || nid.length < 10) return res.status(400).json({ ok: false, error: 'Invalid network ID' });
    try { res.json({ ok: true, output: await execCmd(`sudo /usr/sbin/zerotier-cli join ${nid}`) }); }
    catch(e) { res.status(500).json({ ok: false, error: String(e) }); }
});
app.post('/api/zerotier/leave', async (req, res) => {
    const nid = sanitizeArg(req.body.network_id);
    if (!nid) return res.status(400).json({ ok: false, error: 'Invalid network ID' });
    try { res.json({ ok: true, output: await execCmd(`sudo /usr/sbin/zerotier-cli leave ${nid}`) }); }
    catch(e) { res.status(500).json({ ok: false, error: String(e) }); }
});
app.get('/api/tailscale/status', async (req, res) => {
    try { res.json({ output: await execCmd('sudo /usr/bin/tailscale status 2>/dev/null') }); }
    catch { res.json({ output: 'Tailscale not running' }); }
});
app.post('/api/tailscale/up', async (req, res) => {
    const key = sanitizeArg(req.body.auth_key);
    try { res.json({ ok: true, output: await execCmd(key ? `sudo /usr/bin/tailscale up --authkey=${key}` : 'sudo /usr/bin/tailscale up') }); }
    catch(e) { res.status(500).json({ ok: false, error: String(e) }); }
});
app.get('/api/modem/list', async (req, res) => {
    try { res.json({ output: await execCmd('sudo /usr/bin/mmcli -L 2>/dev/null') }); }
    catch { res.json({ output: 'No modems found' }); }
});

// ─── Routes: Logs ──────────────────────────────────────────────────────────
app.get('/api/logs/:service', (req, res) => {
    const svc = req.params.service.replace(/[^a-z0-9\-]/gi, '');
    exec(`sudo /usr/bin/journalctl -u ${svc} -n 150 --no-pager 2>/dev/null`, (err, stdout) => {
        res.json({ lines: (stdout || '').split('\n').filter(Boolean) });
    });
});

// ─── WebSocket: Live stats ─────────────────────────────────────────────────
app.ws('/ws/stats', (ws) => {
    const iv = setInterval(async () => {
        if (ws.readyState !== 1) { clearInterval(iv); return; }
        try {
            let temp = null;
            try { temp = (parseInt(fs.readFileSync('/sys/class/thermal/thermal_zone0/temp','utf8'))/1000).toFixed(1); } catch {}
            ws.send(JSON.stringify({ ...getSystemInfo(), temp }));
        } catch {}
    }, 2000);
    ws.on('close', () => clearInterval(iv));
});

// ─── WebSocket: PTY Terminal ───────────────────────────────────────────────
const terminals = new Map();

app.ws('/ws/terminal', (ws, req) => {
    let term = null;

    if (pty) {
        try {
            term = pty.spawn(process.env.SHELL || 'bash', [], {
                name: 'xterm-256color',
                cols: 120, rows: 40,
                cwd: process.env.HOME || os.homedir() || '/home/dronepi',
                env: {
                    ...process.env,
                    TERM: 'xterm-256color',
                    COLORTERM: 'truecolor',
                    PS1: '\\[\\033[01;32m\\]dronepi\\[\\033[00m\\]:\\[\\033[01;34m\\]\\w\\[\\033[00m\\]\\$ '
                }
            });
            const id = Date.now();
            terminals.set(id, term);

            term.onData(data => {
                if (ws.readyState === 1) ws.send(JSON.stringify({ type: 'data', data }));
            });
            term.onExit(() => {
                terminals.delete(id);
                if (ws.readyState === 1) ws.send(JSON.stringify({ type: 'exit' }));
            });

            ws.send(JSON.stringify({ type: 'ready' }));

            ws.on('message', (msg) => {
                try {
                    const m = JSON.parse(msg);
                    if (m.type === 'data') term.write(m.data);
                    else if (m.type === 'resize') term.resize(m.cols, m.rows);
                } catch {}
            });

            ws.on('close', () => {
                term.kill();
                terminals.delete(id);
            });
        } catch(e) {
            ws.send(JSON.stringify({ type: 'data', data: '\r\n\x1b[31mFailed to open PTY: ' + e.message + '\x1b[0m\r\n' }));
        }
    } else {
        // Fallback: basic command execution without PTY
        ws.send(JSON.stringify({ type: 'data', data: '\r\n\x1b[33m[Fallback mode — node-pty not available. Commands run via exec.]\x1b[0m\r\n\x1b[32mdronepi:~$\x1b[0m ' }));
        let buf = '';
        ws.on('message', (msg) => {
            try {
                const m = JSON.parse(msg);
                if (m.type !== 'data') return;
                const ch = m.data;
                if (ch === '\r' || ch === '\n') {
                    ws.send(JSON.stringify({ type: 'data', data: '\r\n' }));
                    const cmd = buf.trim();
                    buf = '';
                    if (!cmd) { ws.send(JSON.stringify({ type: 'data', data: '\x1b[32mdronepi:~$\x1b[0m ' })); return; }
                    exec(cmd, { timeout: 10000 }, (err, stdout, stderr) => {
                        const out = (stdout || '') + (stderr || '');
                        ws.send(JSON.stringify({ type: 'data', data: out.replace(/\n/g, '\r\n') + '\r\n\x1b[32mdronepi:~$\x1b[0m ' }));
                    });
                } else if (ch === '\x7f') {
                    if (buf.length > 0) { buf = buf.slice(0,-1); ws.send(JSON.stringify({ type: 'data', data: '\b \b' })); }
                } else {
                    buf += ch;
                    ws.send(JSON.stringify({ type: 'data', data: ch }));
                }
            } catch {}
        });
    }
});

// ─── Routes: MediaMTX Config ───────────────────────────────────────────────
const MEDIAMTX_CONFIG_FILE = '/etc/dronepi/mediamtx.yml';

function parseMtxConfig(raw) {
    const get = k => { const m = raw.match(new RegExp(`^${k}:\\s*(.+)$`, 'm')); return m ? m[1].trim() : null; };
    const port = addr => (addr || '').replace(':', '');
    const paths = [];
    const sec = raw.match(/^paths:\n([\s\S]*)$/m);
    if (sec) {
        let cur = null;
        for (const ln of sec[1].split('\n')) {
            const pm = ln.match(/^  (\S+):$/);
            const sm = ln.match(/^    source:\s*(.+)$/);
            if (pm) { cur = { name: pm[1], source: 'publisher' }; paths.push(cur); }
            else if (sm && cur) cur.source = sm[1].trim();
        }
    }
    return {
        logLevel:   get('logLevel')      || 'info',
        logFile:    get('logFile')       || '/var/log/dronepi/mediamtx.log',
        rtspPort:   port(get('rtspAddress'))   || '8554',
        rtspsPort:  port(get('rtspsAddress'))  || '8322',
        rtmpPort:   port(get('rtmpAddress'))   || '1935',
        hlsPort:    port(get('hlsAddress'))    || '8888',
        webrtcPort: port(get('webrtcAddress')) || '8889',
        srtPort:    port(get('srtAddress'))    || '8890',
        paths: paths.length ? paths : [
            { name: 'drone0', source: 'publisher' },
            { name: 'drone1', source: 'publisher' },
            { name: 'drone2', source: 'publisher' },
        ],
    };
}

function buildFfmpegCommand(video, rtspPath) {
    const w = video.width || 1280;
    const h = video.height || 720;
    const fps = video.fps || 30;
    const bitrate = video.bitrate || 2000;
    const gop = fps * 2;
    const device = video.device || '/dev/video0';
    const dest = `rtsp://localhost:8554/${rtspPath || 'drone0'}`;
    const encode = `-pix_fmt yuv420p -c:v libx264 -preset ultrafast -tune zerolatency -profile:v baseline -level 3.1 -b:v ${bitrate}k -g ${gop} -f rtsp ${dest}`;

    switch (video.source_type) {
        case 'usb':
            return `/usr/bin/ffmpeg -f v4l2 -input_format mjpeg -video_size ${w}x${h} -framerate ${fps} -i ${device} ${encode}`;
        case 'csi':
            return `/usr/bin/ffmpeg -f v4l2 -video_size ${w}x${h} -framerate ${fps} -i ${device} ${encode}`;
        case 'test':
            return `/usr/bin/ffmpeg -f lavfi -i testsrc=size=${w}x${h}:rate=${fps} ${encode}`;
        default:
            return null; // rtsp_in and unknown types don't use runOnInit
    }
}

function generateMediamtxYml(cfg) {
    // Get mediamtx port settings from existing config or defaults
    let mtx = {
        logLevel: 'info', logFile: '/var/log/dronepi/mediamtx.log',
        rtspPort: '8554', rtspsPort: '8322', rtmpPort: '1935',
        hlsPort: '8888', webrtcPort: '8889', srtPort: '8890',
    };
    try {
        const existing = parseMtxConfig(fs.readFileSync(MEDIAMTX_CONFIG_FILE, 'utf8'));
        Object.assign(mtx, existing);
    } catch {}
    // Allow overrides from cfg.mediamtx if present
    if (cfg.mediamtx) Object.assign(mtx, cfg.mediamtx);

    const video = cfg.video || {};

    let y = `logLevel: ${mtx.logLevel || 'info'}\n`;
    y += `logFile: ${mtx.logFile || '/var/log/dronepi/mediamtx.log'}\n`;
    y += `rtspAddress: :${mtx.rtspPort || '8554'}\n`;
    y += `rtspsAddress: :${mtx.rtspsPort || '8322'}\n`;
    y += `rtmpAddress: :${mtx.rtmpPort || '1935'}\n`;
    y += `hlsAddress: :${mtx.hlsPort || '8888'}\n`;
    y += `webrtcAddress: :${mtx.webrtcPort || '8889'}\n`;
    y += `srtAddress: :${mtx.srtPort || '8890'}\n`;
    y += `paths:\n`;

    // drone0: primary path with ffmpeg ingest or rtsp pull
    y += `  drone0:\n`;
    if (video.source_type === 'rtsp_in' && video.pipeline_custom) {
        y += `    source: ${video.pipeline_custom}\n`;
    } else {
        const ffCmd = buildFfmpegCommand(video, 'drone0');
        if (ffCmd) {
            y += `    runOnInit: ${ffCmd}\n`;
            y += `    runOnInitRestart: yes\n`;
        } else {
            y += `    source: publisher\n`;
        }
    }

    // drone1, drone2: secondary paths
    y += `  drone1:\n`;
    y += `    source: publisher\n`;
    y += `  drone2:\n`;
    y += `    source: publisher\n`;

    return y;
}

// Keep legacy buildMtxYaml for reference, but POST /api/mediamtx/config now uses generateMediamtxYml
function buildMtxYaml(cfg) {
    let y = `logLevel: ${cfg.logLevel || 'info'}\n`;
    y += `logFile: ${cfg.logFile || '/var/log/dronepi/mediamtx.log'}\n`;
    y += `rtspAddress: :${cfg.rtspPort || '8554'}\n`;
    y += `rtspsAddress: :${cfg.rtspsPort || '8322'}\n`;
    y += `rtmpAddress: :${cfg.rtmpPort || '1935'}\n`;
    y += `hlsAddress: :${cfg.hlsPort || '8888'}\n`;
    y += `webrtcAddress: :${cfg.webrtcPort || '8889'}\n`;
    y += `srtAddress: :${cfg.srtPort || '8890'}\n`;
    y += `paths:\n`;
    for (const p of (cfg.paths || [])) {
        y += `  ${p.name}:\n`;
        y += `    source: ${p.source || 'publisher'}\n`;
    }
    return y;
}

app.get('/api/mediamtx/config', (req, res) => {
    try { res.json(parseMtxConfig(fs.readFileSync(MEDIAMTX_CONFIG_FILE, 'utf8'))); }
    catch(e) { res.status(500).json({ error: e.message }); }
});

app.post('/api/mediamtx/config', async (req, res) => {
    try {
        // Merge incoming mediamtx settings into full config and regenerate
        const cfg = readConfig();
        cfg.mediamtx = { ...(cfg.mediamtx || {}), ...req.body };
        writeConfig(cfg);
        fs.writeFileSync(MEDIAMTX_CONFIG_FILE, generateMediamtxYml(cfg));
        try { await execCmd('sudo systemctl restart mediamtx'); } catch {}
        res.json({ ok: true });
    } catch(e) { res.status(500).json({ ok: false, error: e.message }); }
});

app.get('/api/mediamtx/status', async (req, res) => {
    try {
        const active = await getServiceStatus('mediamtx');
        const logs = await new Promise(r => exec('sudo /usr/bin/journalctl -u mediamtx -n 40 --no-pager 2>/dev/null', (e, o) => r(o || '')));
        res.json({ active, logs: logs.split('\n').filter(Boolean) });
    } catch(e) { res.status(500).json({ error: e.message }); }
});

// ─── FC auto-detection ────────────────────────────────────────────────────
async function detectFCDevice() {
    // Check /dev/serial/by-id for ArduPilot / PX4 flight controllers
    try {
        const out = await execCmd('ls -la /dev/serial/by-id/ 2>/dev/null || echo ""');
        for (const line of out.split('\n')) {
            const m = line.match(/-> \.\.\/(ttyACM\d+|ttyUSB\d+)/);
            if (m && /ardupilot|px4|cuav|holybro|matek|betaflight|inav|fmu/i.test(line)) {
                return `/dev/${m[1]}`;
            }
        }
    } catch {}
    // Fallback: check for any ttyACM device
    try { await execCmd('ls /dev/ttyACM0'); return '/dev/ttyACM0'; } catch {}
    // Fallback: UART
    try { await execCmd('ls /dev/ttyAMA0'); return '/dev/ttyAMA0'; } catch {}
    return null;
}

app.get('/api/telemetry/fc', async (req, res) => {
    const device = await detectFCDevice();
    res.json({ device, detected: !!device });
});

// ─── Mavlink config regenerator ────────────────────────────────────────────
async function regenerateMavlinkConfig(cfg) {
    const fcDevice = await detectFCDevice() || '/dev/ttyAMA0';
    const baud = cfg.mavlink?.baud || 57600;
    const lines = ['[General]','TcpServerPort=5760','ReportStats=false','MavlinkDialect=common','',`[UartEndpoint FC]`,`Device=${fcDevice}`,`Baud=${baud}`,''];
    for (const ep of (cfg.telemetry_endpoints || [])) {
        if (!ep.enabled) continue;
        lines.push(`[${ep.protocol === 'tcp' ? 'TcpEndpoint' : 'UdpEndpoint'} ${ep.name.replace(/\s+/g,'_')}]`);
        lines.push('Mode=Normal'); lines.push(`Address=${ep.address}`); lines.push(`Port=${ep.port}`); lines.push('');
    }
    try { fs.writeFileSync(`${CONFIG_DIR}/mavlink-router.conf`, lines.join('\n')); } catch {}
}

// ─── Catch-all → SPA ───────────────────────────────────────────────────────
app.get('*', (req, res) => res.sendFile(path.join(__dirname, 'public', 'index.html')));

app.listen(PORT, '0.0.0.0', () => console.log(`DronePI5 running on http://0.0.0.0:${PORT}`));
