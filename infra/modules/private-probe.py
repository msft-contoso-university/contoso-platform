import ipaddress
import json
import os
import re
import socket
import ssl
import sys

PRIVATE_NETWORKS = tuple(ipaddress.ip_network(cidr) for cidr in (
    "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"
))
HOST = re.compile(r"^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)+$")
SUFFIXES = {
    "https": (".scm.azurewebsites.net", ".azurecr.io"),
    "sql": (".database.windows.net",),
}


def check_endpoint(endpoint):
    if not isinstance(endpoint, dict) or set(endpoint) != {"host", "kind"}:
        raise ValueError("each endpoint must contain exactly host and kind")
    host, kind = endpoint["host"], endpoint["kind"]
    if not isinstance(host, str) or not isinstance(kind, str) or kind not in SUFFIXES:
        raise ValueError("invalid endpoint kind or host")
    if len(host) > 253 or not HOST.fullmatch(host) or not host.endswith(SUFFIXES[kind]):
        raise ValueError("endpoint must be an allowlisted Azure service hostname")
    port = 443 if kind == "https" else 1433
    addresses = {entry[4][0] for entry in socket.getaddrinfo(host, port, socket.AF_INET, socket.SOCK_STREAM)}
    if not addresses or any(
        not any(ipaddress.ip_address(address) in network for network in PRIVATE_NETWORKS)
        for address in addresses
    ):
        raise ValueError("endpoint DNS did not resolve exclusively to private IPv4 addresses")
    for address in sorted(addresses):
        with socket.create_connection((address, port), timeout=10) as connection:
            if kind == "https":
                with ssl.create_default_context().wrap_socket(connection, server_hostname=host):
                    pass
    return {"host": host, "kind": kind, "result": "reachable"}


def main():
    endpoints = json.loads(os.environ["PROBE_ENDPOINTS"])
    if not isinstance(endpoints, list) or not 1 <= len(endpoints) <= 8:
        raise ValueError("one to eight endpoints are required")
    results = [check_endpoint(endpoint) for endpoint in endpoints]
    with open(os.environ["AZ_SCRIPTS_OUTPUT_PATH"], "w", encoding="utf-8") as output:
        json.dump({"result": "reachable", "endpoints": results}, output)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError, json.JSONDecodeError) as error:
        print(f"Private network probe failed: {error}", file=sys.stderr)
        sys.exit(1)
