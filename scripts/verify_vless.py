#!/usr/bin/env python3
"""Сквозная проверка VLESS Reality: локальный xray-клиент -> socks -> публичный IP.

Usage:
  verify_vless.py --ip 203.0.113.10 --uuid UUID --pbk PUBKEY --sni yahoo.com \
                  [--sid SID] [--flow xtls-rprx-vision] [--port 8443] [--expect 203.0.113.10]

Запускать на самом сервере: подключение идёт на его публичный адрес, поэтому
проверяются вход, маршрут и ключи сразу. Печатает exit IP и PASS/FAIL.
"""
import argparse
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.request

XRAY_CANDIDATES = [
    '/usr/local/x-ui/bin/xray-linux-amd64',
    '/usr/local/bin/xray',
    '/usr/local/x-ui/bin/xray',
]


def find_xray(explicit=None):
    for p in ([explicit] if explicit else []) + XRAY_CANDIDATES:
        if p and os.path.isfile(p) and os.access(p, os.X_OK):
            return p
    sys.exit('xray binary not found; pass --xray /path/to/xray')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--ip', required=True)
    ap.add_argument('--port', type=int, default=8443)
    ap.add_argument('--uuid', required=True)
    ap.add_argument('--pbk', required=True)
    ap.add_argument('--sid', default='')
    ap.add_argument('--sni', required=True)
    ap.add_argument('--flow', default='xtls-rprx-vision')
    ap.add_argument('--socks-port', type=int, default=18080)
    ap.add_argument('--expect', default=None, help='ожидаемый exit IP (по умолчанию --ip)')
    ap.add_argument('--xray', default=None)
    a = ap.parse_args()

    xray = find_xray(a.xray)
    reality = {'serverName': a.sni, 'fingerprint': 'chrome',
               'publicKey': a.pbk, 'spiderX': '/'}
    if a.sid:
        reality['shortId'] = a.sid
    cfg = {
        'log': {'loglevel': 'warning'},
        'inbounds': [{'listen': '127.0.0.1', 'port': a.socks_port,
                      'protocol': 'socks', 'settings': {'udp': False}}],
        'outbounds': [{
            'protocol': 'vless',
            'settings': {'vnext': [{'address': a.ip, 'port': a.port,
                                    'users': [{'id': a.uuid, 'encryption': 'none',
                                               'flow': a.flow}]}]},
            'streamSettings': {'network': 'tcp', 'security': 'reality',
                               'realitySettings': reality},
        }],
    }

    fd, path = tempfile.mkstemp(suffix='.json', prefix='vless-probe-')
    with os.fdopen(fd, 'w') as f:
        json.dump(cfg, f)

    proc = subprocess.Popen([xray, 'run', '-c', path],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(2)
    exit_ip = None
    try:
        proxy = 'socks5h://127.0.0.1:%d' % a.socks_port
        opener = urllib.request.build_opener(
            urllib.request.ProxyHandler({'https': proxy, 'http': proxy}))
        for url in ('https://ifconfig.me', 'https://api.ipify.org'):
            try:
                exit_ip = opener.open(url, timeout=20).read().decode().strip()
                if exit_ip:
                    break
            except Exception:
                continue
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
        os.unlink(path)

    if not exit_ip:
        print('FAIL: соединение через прокси не установлено (ключи/порт/SNI/flow?)')
        return 1
    expect = a.expect or a.ip
    ok = exit_ip == expect
    print('%s: exit IP %s (ожидался %s)' % ('PASS' if ok else 'FAIL', exit_ip, expect))
    return 0 if ok else 2


if __name__ == '__main__':
    sys.exit(main())
