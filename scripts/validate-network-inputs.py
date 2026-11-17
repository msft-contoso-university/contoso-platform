import argparse
import ipaddress
import json
import os
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
    app_by_name = {subnet["name"].lower(): subnet for subnet in app_subnets}
    dev_name = config["devAppSubnetName"]
    staging_name = config["stagingAppSubnetName"]
    if not isinstance(dev_name, str) or not isinstance(staging_name, str) or dev_name.lower() == staging_name.lower():
        raise ValueError("dev and staging App Service subnets must be distinct names")
    for name in (dev_name, staging_name):
        subnet = app_by_name.get(name.lower())
        if (subnet is None or subnet.get("delegation") != "Microsoft.Web/serverFarms"
                or network(subnet["addressPrefix"]).prefixlen > 28):
            raise ValueError(f"App Service subnet {name} must exist, be at least /28, and be delegated to Microsoft.Web/serverFarms")
    container_names = (config["devContainerSubnetName"], config["stagingContainerSubnetName"])
    if any(not isinstance(name, str) or not name for name in container_names):
        raise ValueError("Container Apps subnet names must be nonempty strings")
    all_names = [dev_name.lower(), staging_name.lower(), *(name.lower() for name in container_names)]
    if len(set(all_names)) != 4:
        raise ValueError("App Service and Container Apps subnets must all be distinct")
    for name in container_names:
        subnet = app_by_name.get(name.lower())
        if (subnet is None or subnet.get("delegation") != "Microsoft.App/environments"
                or network(subnet["addressPrefix"]).prefixlen > 27):
            raise ValueError(f"Container Apps subnet {name} must exist, be at least /27, and be delegated to Microsoft.App/environments")
    egress = config["runnerHttpsEgressPrefixes"]
    if not isinstance(egress, list) or not egress or len(egress) > 1000:
        raise ValueError("one to 1000 explicit runner HTTPS egress prefixes are required")
    for value in egress:
        prefix = network(value)
        if prefix.prefixlen < 8 or not prefix.is_global:
            raise ValueError("runner HTTPS egress must use bounded public IPv4 prefixes")


def azd_environment_config(environment):
    variables = {
        "addressPrefix": "ADLC_VNET_PREFIX",
        "runnerSubnetPrefix": "ADLC_RUNNER_SUBNET_PREFIX",
        "endpointSubnetPrefix": "ADLC_ENDPOINT_SUBNET_PREFIX",
        "applicationSubnets": "ADLC_APPLICATION_SUBNETS",
        "devAppSubnetName": "ADLC_DEV_APP_SUBNET_NAME",
        "stagingAppSubnetName": "ADLC_STAGING_APP_SUBNET_NAME",
        "devContainerSubnetName": "ADLC_DEV_CONTAINER_SUBNET_NAME",
        "stagingContainerSubnetName": "ADLC_STAGING_CONTAINER_SUBNET_NAME",
        "runnerHttpsEgressPrefixes": "ADLC_RUNNER_HTTPS_EGRESS_PREFIXES",
    }
    config = {}
    for key, name in variables.items():
        value = environment.get(name)
        if not isinstance(value, str) or not value.strip():
            raise ValueError(f"Missing required azd network input: {name}")
        config[key] = json.loads(value) if key in ("applicationSubnets", "runnerHttpsEgressPrefixes") else value
    return config


def main():
    parser = argparse.ArgumentParser(description="Validate shared VNet and explicit runner egress inputs.")
    parser.add_argument("config", nargs="?", help="Path to a JSON network configuration object")
    parser.add_argument("--azd-env", action="store_true", help="Read the current hook's azd environment inputs")
    args = parser.parse_args()
    if bool(args.config) == args.azd_env:
        parser.error("Provide exactly one JSON configuration path or --azd-env.")
    try:
        if args.azd_env:
            config = azd_environment_config(os.environ)
        else:
            with open(args.config, encoding="utf-8") as source:
                config = json.load(source)
        validate(config)
    except (OSError, KeyError, ValueError) as error:
        print(f"Invalid network configuration: {error}", file=sys.stderr)
        return 1
    print("Network configuration is structurally valid; connectivity and permissions remain unverified.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
