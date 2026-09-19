#!/usr/bin/env python3
"""Static HTTP server with Range support, for pxe.sh.

The archiso initramfs probes the live image with a one-byte Range request
before downloading it; the stock http.server ignores Range and would send the
whole image twice.  usage: pxe-httpd.py PORT BIND DIRECTORY
"""
import os
import re
import sys
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer


class RangeHandler(SimpleHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def send_head(self):
        path = self.translate_path(self.path)
        rng = self.headers.get("Range")
        if not rng or os.path.isdir(path):
            return super().send_head()
        m = re.fullmatch(r"bytes=(\d*)-(\d*)", rng.strip())
        if not m or not os.path.isfile(path):
            return super().send_head()
        size = os.path.getsize(path)
        start = int(m.group(1)) if m.group(1) else None
        end = int(m.group(2)) if m.group(2) else None
        if start is None:            # suffix range: last N bytes
            start, end = max(size - (end or 0), 0), size - 1
        else:
            end = min(end if end is not None else size - 1, size - 1)
        if start > end or start >= size:
            self.send_error(416, "Requested Range Not Satisfiable")
            return None
        f = open(path, "rb")
        f.seek(start)
        self.range_length = end - start + 1
        self.send_response(206)
        self.send_header("Content-Type", self.guess_type(path))
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.send_header("Content-Length", str(self.range_length))
        self.end_headers()
        return f

    def copyfile(self, src, dst):
        left = getattr(self, "range_length", None)
        if left is None:
            return super().copyfile(src, dst)
        self.range_length = None
        while left > 0:
            chunk = src.read(min(left, 1 << 20))
            if not chunk:
                break
            dst.write(chunk)
            left -= len(chunk)


def main():
    port, bind, directory = int(sys.argv[1]), sys.argv[2], sys.argv[3]
    os.chdir(directory)
    handler = lambda *a, **kw: RangeHandler(*a, directory=directory, **kw)
    ThreadingHTTPServer((bind, port), handler).serve_forever()


if __name__ == "__main__":
    main()
