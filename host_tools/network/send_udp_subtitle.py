#!/usr/bin/env python3
"""Send one ASCII subtitle packet to the HX4S20 UDP endpoint."""

import argparse
import socket


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("text", help="ASCII subtitle, at most 32 characters")
    parser.add_argument("--ip", default="192.168.240.1")
    parser.add_argument("--port", type=int, default=5000)
    parser.add_argument(
        "--source-ip",
        default="192.168.240.2",
        help="local IPv4 address connected to the FPGA",
    )
    args = parser.parse_args()

    try:
        payload = args.text.encode("ascii")
    except UnicodeEncodeError as exc:
        raise SystemExit("Current FPGA font path accepts ASCII only.") from exc

    if not 1 <= len(payload) <= 32:
        raise SystemExit("Subtitle length must be between 1 and 32 bytes.")

    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        try:
            sock.bind((args.source_ip, 0))
        except OSError as exc:
            raise SystemExit(
                f"Cannot bind source address {args.source_ip}; "
                "check the Ethernet adapter IPv4 setting."
            ) from exc
        sent = sock.sendto(payload, (args.ip, args.port))
        source_ip, source_port = sock.getsockname()
    print(
        f"sent {sent} bytes from {source_ip}:{source_port} "
        f"to {args.ip}:{args.port}: {args.text}"
    )


if __name__ == "__main__":
    main()
