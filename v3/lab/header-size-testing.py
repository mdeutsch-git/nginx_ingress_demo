#!/usr/bin/env python3
"""
Test large header buffer limits against an Envoy/Istio gateway.
Usage: python3 test_headers.py <ip> [port] [path]
"""

import http.client
import base64
import sys

def make_token(size_bytes: int) -> str:
    return base64.b64encode(b'A' * size_bytes).decode()

def test(ip: str, port: int, path: str, label: str, headers: dict):
    try:
        conn = http.client.HTTPConnection(ip, port, timeout=10)
        conn.request("GET", path, headers=headers)
        resp = conn.getresponse()
        print(f"[{label}] HTTP {resp.status} {resp.reason}")
        conn.close()
    except Exception as e:
        print(f"[{label}] ERROR: {e}")

def main():
    if len(sys.argv) < 2:
        print("Usage: python3 test_headers.py <ip> [port] [path]")
        sys.exit(1)

    ip   = sys.argv[1]
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 80
    path = sys.argv[3]      if len(sys.argv) > 3 else "/echo"
    HOST = "myapp.example.com"

    print(f"Target: http://{ip}:{port}{path}\n")

    # 1. Baseline — small token, should always pass
    test(ip, port, path,
         label="baseline (1KB)",
         headers={"Host": HOST, "Authorization": f"Bearer {make_token(1_000)}"})

    # 2. Binary search across increasing sizes
    for size in [50_000, 100_000, 200_000, 350_000, 400_000, 450_000]:
        test(ip, port, path,
             label=f"single header ({size // 1000}KB)",
             headers={"Host": HOST, "Authorization": f"Bearer {make_token(size)}"})

    # 3. Multi-header test — mirrors real SAML/OIDC patterns
    chunk = make_token(90_000)
    test(ip, port, path,
         label="multi-header (4 x 90KB)",
         headers={
             "Host": HOST,
             "Authorization":        f"Bearer {chunk}",
             "X-Saml-Assertion":     chunk,
             "X-Forwarded-User-Info": chunk,
             "X-Custom-Claims":      chunk,
         })

if __name__ == "__main__":
    main()