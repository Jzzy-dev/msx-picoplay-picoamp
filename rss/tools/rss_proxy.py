#!/usr/bin/env python3
"""rss_proxy.py - https for an MSX whose network has no TLS.

The MSX RSS reader sends "GET https://host/path HTTP/1.0" here when the
TCP/IP UNAPI implementation cannot do TLS (openMSXnet in openMSX, GR8NET,
Obsonet, DenYoNet, ...) and RSS.INI has  proxy=<this computer>:8088
This fetches the page over https and gives it back as plain HTTP (status,
Location, Content-Length, Date and the body; redirects are passed on, the
reader follows them).

    python3 rss_proxy.py [port]          (default 8088, all interfaces)

Standard library only. Use it on your own network: it fetches what it is asked.
"""
import http.client, socketserver, ssl, sys, urllib.parse

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8088
CTX = ssl.create_default_context()


class Handler(socketserver.StreamRequestHandler):
    timeout = 60

    def handle(self):
        line = self.rfile.readline(4096).decode('latin-1').strip()
        while True:                                     # (the rest of the request: not needed)
            h = self.rfile.readline(4096)
            if not h or h in (b'\r\n', b'\n'):
                break
        try:
            method, url, _ = line.split(' ', 2)
            u = urllib.parse.urlsplit(url)
            if method != 'GET' or u.scheme not in ('http', 'https') or not u.hostname:
                raise ValueError(line)
            path = (u.path or '/') + ('?' + u.query if u.query else '')
            cls = http.client.HTTPSConnection if u.scheme == 'https' else http.client.HTTPConnection
            kw = {'context': CTX} if u.scheme == 'https' else {}
            c = cls(u.hostname, u.port, timeout=30, **kw)
            c.request('GET', path, headers={'Host': u.netloc, 'User-Agent': 'MSX-RSS/1.0 (proxy)',
                                            'Accept': '*/*', 'Accept-Encoding': 'identity'})
            r = c.getresponse()
            body = r.read()
            out = 'HTTP/1.0 %d %s\r\n' % (r.status, r.reason or 'X')
            for k in ('Location', 'Date', 'Content-Type'):
                v = r.getheader(k)
                if v:
                    if k == 'Location':
                        v = urllib.parse.urljoin(url, v)
                    out += '%s: %s\r\n' % (k, v)
            out += 'Content-Length: %d\r\nConnection: close\r\n\r\n' % len(body)
            self.wfile.write(out.encode('latin-1') + body)
            print('%d %7d %s' % (r.status, len(body), url), flush=True)
        except Exception as e:                          # noqa: BLE001 - tell the MSX, carry on
            msg = ('%s' % e).encode('latin-1', 'replace')[:200]
            self.wfile.write(b'HTTP/1.0 502 Bad Gateway\r\nContent-Length: %d\r\nConnection: close\r\n\r\n' % len(msg) + msg)
            print('502 %s (%s)' % (line, e), flush=True)


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


if __name__ == '__main__':
    print('MSX RSS https proxy on port %d' % PORT, flush=True)
    Server(('', PORT), Handler).serve_forever()
