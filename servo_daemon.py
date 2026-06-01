#!/usr/bin/env python3
"""Persistent servo daemon for fpp-servo-calibrator.
Keeps the I2C bus open so per-command latency is ~2ms instead of ~150ms.

I2C ownership is on-demand — the daemon starts without touching the bus or
disabling fppd's PCA9685 output.  When the user enables test mode the UI
sends action=open, which disables fppd's output and claims the I2C bus.
action=close releases the bus and re-enables fppd's output immediately via
the FPP API so other plugins (e.g. live-follow) are not affected.
"""
from http.server import HTTPServer, BaseHTTPRequestHandler
import json, signal, sys, time, urllib.request
import smbus2

CONFIG        = '/home/fpp/media/config/co-other.json'
HOST          = '127.0.0.1'
PORT_NUM      = 5003
_CO_OTHER_API = 'http://localhost/api/channel/output/co-other'

outputs   = []
i2c_open  = False   # True only while we hold the I2C bus


def _set_fpp_pca9685_output(enabled: bool) -> bool:
    """Enable or disable fppd's PCA9685 output via the FPP API.

    Both enable and disable use the API so the change takes effect immediately
    without waiting for an fppd restart.  Returns True on success.
    """
    try:
        with urllib.request.urlopen(_CO_OTHER_API, timeout=3) as resp:
            cfg = json.loads(resp.read())
        changed = False
        for out in cfg.get('channelOutputs', []):
            if out.get('type') == 'PCA9685':
                out['enabled'] = 1 if enabled else 0
                changed = True
        if not changed:
            return True
        data = json.dumps(cfg).encode()
        req  = urllib.request.Request(_CO_OTHER_API, data=data, method='POST',
                                      headers={'Content-Type': 'application/json'})
        urllib.request.urlopen(req, timeout=3)
        print(f'[ServoCalibrator] FPP PCA9685 output {"enabled" if enabled else "disabled"}.')
        return True
    except Exception as exc:
        print(f'[ServoCalibrator] Could not toggle FPP PCA9685 output: {exc}', file=sys.stderr)
        return False


def load_outputs():
    with open(CONFIG) as f:
        cfg = json.load(f)
    result = []
    for out in cfg.get('channelOutputs', []):
        if not out.get('ports'):
            continue
        dev  = out.get('device', 'i2c-1')
        addr = out.get('deviceID', 0x40)
        bus  = smbus2.SMBus(int(dev.split('-')[-1]))
        m = bus.read_byte_data(addr, 0x00)
        if m & 0x10:
            bus.write_byte_data(addr, 0x00, m & ~0x10)
            time.sleep(0.005)
        pre  = bus.read_byte_data(addr, 0xFE)
        freq = 25_000_000 / (4096 * (pre + 1))
        result.append({'bus': bus, 'addr': addr, 'freq': freq, 'ports': out['ports']})
    return result


def close_outputs(outs):
    for o in outs:
        try: o['bus'].close()
        except: pass


def us_to_counts(us, freq):
    return round(us * freq * 4096 / 1_000_000)


def set_ch(bus, addr, ch, counts):
    base = 0x06 + ch * 4
    bus.write_byte_data(addr, base,   0)
    bus.write_byte_data(addr, base+1, 0)
    bus.write_byte_data(addr, base+2, counts & 0xFF)
    bus.write_byte_data(addr, base+3, counts >> 8)


def do_open() -> str | None:
    """Claim the I2C bus: disable fppd's PCA9685 output then open smbus2.

    Returns None on success, error string on failure.
    """
    global outputs, i2c_open
    if i2c_open:
        return None
    for attempt in range(8):
        if _set_fpp_pca9685_output(False):
            break
        print(f'[ServoCalibrator] Waiting for FPP API (attempt {attempt + 1}/8)...')
        time.sleep(2)
    else:
        return 'Could not disable FPP PCA9685 output'
    time.sleep(0.5)
    try:
        close_outputs(outputs)
        outputs  = load_outputs()
        i2c_open = True
        return None
    except Exception as exc:
        _set_fpp_pca9685_output(True)
        return str(exc)


def do_close():
    """Release the I2C bus: center servos, close smbus2, re-enable fppd output."""
    global outputs, i2c_open
    if not i2c_open:
        return
    for o in outputs:
        bus, addr, freq, ports = o['bus'], o['addr'], o['freq'], o['ports']
        for i, p in enumerate(ports):
            mn  = p.get('min', 500)
            mx  = p.get('max', 2500)
            ctr = p.get('center', (mn + mx) // 2)
            try:
                set_ch(bus, addr, i, us_to_counts(ctr, freq))
            except Exception:
                pass
    close_outputs(outputs)
    outputs  = []
    i2c_open = False
    _set_fpp_pca9685_output(True)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def reply(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        global outputs, i2c_open
        try:
            length = int(self.headers.get('Content-Length', 0))
            req    = json.loads(self.rfile.read(length))
        except Exception:
            self.reply(400, {'status': 'error', 'message': 'Bad request'})
            return

        action  = req.get('action', '')
        out_idx = int(req.get('out', 0))

        if action == 'open':
            err = do_open()
            if err:
                self.reply(500, {'status': 'error', 'message': err})
            else:
                self.reply(200, {'status': 'ok', 'action': 'open'})
            return

        if action == 'close':
            do_close()
            self.reply(200, {'status': 'ok', 'action': 'close'})
            return

        if action == 'reload':
            if not i2c_open:
                self.reply(200, {'status': 'ok', 'action': 'reload'})
                return
            try:
                close_outputs(outputs)
                outputs = load_outputs()
                self.reply(200, {'status': 'ok', 'action': 'reload'})
            except Exception as e:
                self.reply(500, {'status': 'error', 'message': str(e)})
            return

        if not i2c_open:
            self.reply(400, {'status': 'error', 'message': 'Not open — call open first'})
            return

        if out_idx < 0 or out_idx >= len(outputs):
            self.reply(400, {'status': 'error', 'message': f'Output {out_idx} not found'})
            return

        o    = outputs[out_idx]
        bus, addr, freq, ports = o['bus'], o['addr'], o['freq'], o['ports']

        try:
            if action == 'set':
                port = int(req.get('port', -1))
                us   = max(0, min(4000, int(req.get('us', 0))))
                set_ch(bus, addr, port, us_to_counts(us, freq))
                self.reply(200, {'status': 'ok', 'port': port, 'us': us})

            elif action == 'set_all':
                for ch in req.get('channels', []):
                    port = int(ch.get('port', -1))
                    us   = max(0, min(4000, int(ch.get('us', 0))))
                    if 0 <= port < len(ports):
                        set_ch(bus, addr, port, us_to_counts(us, freq))
                self.reply(200, {'status': 'ok', 'action': 'set_all'})

            elif action == 'stop':
                for i, p in enumerate(ports):
                    mn  = p.get('min', 500)
                    mx  = p.get('max', 2500)
                    ctr = p.get('center', (mn + mx) // 2)
                    set_ch(bus, addr, i, us_to_counts(ctr, freq))
                self.reply(200, {'status': 'ok', 'action': 'stop'})

            else:
                self.reply(400, {'status': 'error', 'message': f'Unknown action: {action}'})

        except Exception as e:
            self.reply(500, {'status': 'error', 'message': str(e)})


def main():
    def shutdown(sig, frame):
        do_close()
        sys.exit(0)
    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT,  shutdown)

    server = HTTPServer((HOST, PORT_NUM), Handler)
    print(f'[ServoCalibrator] Daemon listening on {HOST}:{PORT_NUM} (I2C idle — send open to claim bus)', flush=True)
    server.serve_forever()


if __name__ == '__main__':
    main()
