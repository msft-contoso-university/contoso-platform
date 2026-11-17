import argparse
import ipaddress
import json
import sys

PRIVATE = tuple(ipaddress.ip_network(cidr) for cidr in (
    "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"
))


def network(value):
    if not isinstance(value, str):
        raise ValueError("network prefixes must be strings")
    result = ipaddress.ip_network(value, strict=True)
    if result.version != 4:
        raise ValueError("only IPv4 network prefixes are supported")
    return result


def validate(config):
    if not isinstance(config, dict):
        raise ValueError("network configuration must be an object")
    address_space = network(config["addressPrefix"])
    if not any(address_space.subnet_of(private) for private in PRIVATE):
        raise ValueError("VNet address space must be RFC 1918 private space")
    subnets = [
        ("runner", network(config["runnerSubnetPrefix"])),
        ("private-endpoints", network(config["endpointSubnetPrefix"])),
    ]
    app_subnets = config["applicationSubnets"]
    if not isinstance(app_subnets, list):
        raise ValueError("applicationSubnets must be an array")
    for subnet in app_subnets:
        if not isinstance(subnet, dict) or not isinstance(subnet.get("name"), str) or not subnet["name"]:
            raise ValueError("each application subnet needs a name and addressPrefix")
        subnets.append((subnet["name"], network(subnet["addressPrefix"])))
    names = set()
    for index, (name, subnet) in enumerate(subnets):
        if name.lower() in names:
            raise ValueError(f"duplicate subnet name: {name}")
        names.add(name.lower())
        if not subnet.subnet_of(address_space):
            raise ValueError(f"subnet {name} is outside the VNet")
        if any(subnet.overlaps(other) for _, other in subnets[:index]):
            raise ValueError(f"subnet {name} overlaps another subnet")
    egress = config["runnerHttpsEgressPrefixes"]
    if not isinstance(egress, list) or not egress or len(egress) > 1000:
        raise ValueError("one to 1000 explicit runner HTTPS egress prefixes are required")
    for value in egress:
        prefix = network(value)
        if prefix.prefixlen < 8 or not prefix.is_global:
            raise ValueError("runner HTTPS egress must use bounded public IPv4 prefixes")


def main():
    parser = argparse.ArgumentParser(description="Validate shared VNet and explicit runner egress inputs.")
    parser.add_argument("config", help="Path to a JSON network configuration object")
    args = parser.parse_args()
    try:
        with open(args.config, encoding="utf-8") as source:
            validate(json.load(source))
    except (OSError, KeyError, ValueError) as error:
        print(f"Invalid network configuration: {error}", file=sys.stderr)
        return 1
    print("Network configuration is structurally valid; connectivity and permissions remain unverified.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
