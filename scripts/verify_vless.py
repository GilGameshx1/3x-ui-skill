#!/usr/bin/env python3
"""Сквозная проверка VLESS Reality: локальный xray-клиент -> socks -> публичный IP.

Usage:
  verify_vless.py --ip 203.0.113.10 --uuid UUID --pbk PUBKEY --sni yahoo.com \
                  [--sid SID] [--flow xtls-rprx-vision] [--port 8443] [--expect 203.0.113.10]

  verify_vless.py --ip 2001:db8::10 --uuid UUID --pbk PUBKEY --sni yahoo.com \
                  --family 6 --expect-family 6

Запускать на самом сервере: подключение идёт на его публичный адрес, поэтому
проверяются вход, маршрут и ключи сразу. Печатает exit IP и PASS/FAIL.

--family 4|6|auto  — каким семейством проверять: 4 = https://ipv4.icanhazip.com
                     и outbound domainStrategy UseIPv4, 6 = https://ipv6.icanhazip.com
                     и UseIPv6, auto (по умолчанию) = прежнее поведение
                     (ifconfig.me, api.ipify.org, без domainStrategy).
--expect-family 4|6 — ожидаемое семейство exit IP; проверяется через ipaddress.
                     По умолчанию берётся из --family (для auto не проверяется).

Коды возврата: 0 = PASS, 1 = через прокси не удалось получить exit IP,
2 = exit IP не тот / не того семейства.
"""
import argparse
import ipaddress
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

# URL, которые показывают exit IP только нужного семейства.
FAMILY_URLS = {
    '4': ('https://ipv4.icanhazip.com',),
    '6': ('https://ipv6.icanhazip.com',),
    'auto': ('https://ifconfig.me', 'https://api.ipify.org'),
}

# domainStrategy outbound'а: без него xray отдаёт домен системному резолверу
# и семейство exit IP зависит от A/AAAA и happy eyeballs.
FAMILY_STRATEGY = {'4': 'UseIPv4', '6': 'UseIPv6', 'auto': None}


def find_xray(explicit=None):
    for p in ([explicit] if explicit else []) + XRAY_CANDIDATES:
        if p and os.path.isfile(p) and os.access(p, os.X_OK):
            return p
    sys.exit('xray binary not found; pass --xray /path/to/xray')


def normalize_server(addr):
    """Адрес сервера для xray JSON: IPv6-литерал пишется без скобок.

    В vless:// и в curl скобки обязательны, в конфиге xray — наоборот:
    "[2001:db8::10]" там не резолвится. Поэтому снимаем их, если передали.
    """
    addr = addr.strip()
    if addr.startswith('[') and addr.endswith(']'):
        addr = addr[1:-1]
    return addr


def build_config(server, port, uuid, pbk, sid, sni, flow, socks_port, family):
    reality = {'serverName': sni, 'fingerprint': 'chrome',
               'publicKey': pbk, 'spiderX': '/'}
    if sid:
        reality['shortId'] = sid
    outbound = {
        'protocol': 'vless',
        'settings': {'vnext': [{'address': server, 'port': port,
                                'users': [{'id': uuid, 'encryption': 'none',
                                           'flow': flow}]}]},
        'streamSettings': {'network': 'tcp', 'security': 'reality',
                           'realitySettings': reality},
    }
    strategy = FAMILY_STRATEGY[family]
    if strategy:
        outbound['domainStrategy'] = strategy
    return {
        'log': {'loglevel': 'warning'},
        'inbounds': [{'listen': '127.0.0.1', 'port': socks_port,
                      'protocol': 'socks', 'settings': {'udp': False}}],
        'outbounds': [outbound],
    }


def ip_family(value):
    """4/6 для IP-литерала, None если это не IP (домен, мусор)."""
    try:
        return ipaddress.ip_address(value).version
    except ValueError:
        return None


def extract_ip(text):
    """Первый токен ответа, который парсится как IP; иначе исходная строка."""
    for token in text.split():
        if ip_family(token):
            return token
    return text.strip() or None


def same_ip(left, right):
    try:
        return ipaddress.ip_address(left) == ipaddress.ip_address(right)
    except ValueError:
        return left.strip().lower() == right.strip().lower()


def probe(opener, urls):
    for url in urls:
        try:
            body = opener.open(url, timeout=20).read().decode().strip()
        except Exception:
            continue
        ip = extract_ip(body)
        if ip:
            return ip
    return None


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
    ap.add_argument('--family', choices=('4', '6', 'auto'), default='auto',
                    help='семейство IP для проверки: 4, 6 или auto (прежнее поведение)')
    ap.add_argument('--expect-family', choices=('4', '6'), default=None,
                    help='ожидаемое семейство exit IP (по умолчанию из --family)')
    a = ap.parse_args()

    expect_family = a.expect_family
    if expect_family is None and a.family != 'auto':
        expect_family = a.family

    xray = find_xray(a.xray)
    server = normalize_server(a.ip)
    cfg = build_config(server, a.port, a.uuid, a.pbk, a.sid, a.sni,
                       a.flow, a.socks_port, a.family)

    fd, path = tempfile.mkstemp(suffix='.json', prefix='vless-probe-')
    with os.fdopen(fd, 'w') as f:
        json.dump(cfg, f)

    proc = subprocess.Popen([xray, 'run', '-c', path],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(2)
    try:
        proxy = 'socks5h://127.0.0.1:%d' % a.socks_port
        opener = urllib.request.build_opener(
            urllib.request.ProxyHandler({'https': proxy, 'http': proxy}))
        exit_ip = probe(opener, FAMILY_URLS[a.family])
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
        os.unlink(path)

    if not exit_ip:
        hint = ''
        if a.family == '6':
            hint = ('; для --family 6 проверь IPv6 на сервере, default-маршрут '
                    'и domainStrategy UseIPv6, а в --ip лучше IPv6-литерал')
        elif a.family == '4':
            hint = '; для --family 4 проверь, что сервер выходит в IPv4'
        print('FAIL: соединение через прокси не установлено '
              '(ключи/порт/SNI/flow?)%s' % hint)
        return 1

    if expect_family:
        actual = ip_family(exit_ip)
        if actual is None:
            print('FAIL: exit IP %r не разбирается как IP-адрес, '
                  'ожидался IPv%s' % (exit_ip, expect_family))
            return 2
        if str(actual) != expect_family:
            print('FAIL: exit IP %s — IPv%d, а ожидался IPv%s '
                  '(--expect-family %s)' % (exit_ip, actual, expect_family, expect_family))
            return 2

    expect = a.expect or server
    ok = same_ip(exit_ip, expect)
    print('%s: exit IP %s (ожидался %s)' % ('PASS' if ok else 'FAIL', exit_ip, expect))
    return 0 if ok else 2


if __name__ == '__main__':
    sys.exit(main())
