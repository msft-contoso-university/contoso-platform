import importlib.util
import json
import os
import subprocess
import sys
import unittest
from pathlib import Path

PATH = Path(__file__).resolve().parents[1] / "scripts" / "validate-network-inputs.py"
spec = importlib.util.spec_from_file_location("validate_network_inputs", PATH)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def valid_config():
    return {
        "addressPrefix": "10.60.0.0/16",
        "runnerSubnetPrefix": "10.60.0.0/24",
        "endpointSubnetPrefix": "10.60.1.0/24",
        "applicationSubnets": [
            {"name": "dev-apps", "addressPrefix": "10.60.2.0/24", "delegation": "Microsoft.Web/serverFarms"},
            {"name": "staging-apps", "addressPrefix": "10.60.3.0/24", "delegation": "Microsoft.Web/serverFarms"},
            {"name": "dev-containers", "addressPrefix": "10.60.4.0/24", "delegation": "Microsoft.App/environments"},
            {"name": "staging-containers", "addressPrefix": "10.60.5.0/24", "delegation": "Microsoft.App/environments"},
        ],
        "devAppSubnetName": "dev-apps",
        "stagingAppSubnetName": "staging-apps",
        "devContainerSubnetName": "dev-containers",
        "stagingContainerSubnetName": "staging-containers",
        "runnerHttpsEgressPrefixes": ["20.0.0.0/8"],
    }


class NetworkInputTests(unittest.TestCase):
    def test_valid_configuration(self):
        module.validate(valid_config())

    def test_azd_environment_uses_the_same_network_inputs(self):
        config = valid_config()
        names = {
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
        env = {name: json.dumps(config[key]) if isinstance(config[key], list) else config[key]
               for key, name in names.items()}
        self.assertEqual(config, module.azd_environment_config(env))
        module.validate(module.azd_environment_config(env))
        del env["ADLC_VNET_PREFIX"]
        with self.assertRaisesRegex(ValueError, "ADLC_VNET_PREFIX"):
            module.azd_environment_config(env)
        env["ADLC_VNET_PREFIX"] = config["addressPrefix"]
        env["ADLC_APPLICATION_SUBNETS"] = "{invalid"
        with self.assertRaises(ValueError):
            module.azd_environment_config(env)

    def test_azd_environment_cli_rejects_bad_effective_network(self):
        config = valid_config()
        env = os.environ.copy()
        env.update({
            "ADLC_VNET_PREFIX": config["addressPrefix"],
            "ADLC_RUNNER_SUBNET_PREFIX": config["runnerSubnetPrefix"],
            "ADLC_ENDPOINT_SUBNET_PREFIX": config["endpointSubnetPrefix"],
            "ADLC_APPLICATION_SUBNETS": json.dumps(config["applicationSubnets"]),
            "ADLC_DEV_APP_SUBNET_NAME": config["devAppSubnetName"],
            "ADLC_STAGING_APP_SUBNET_NAME": config["stagingAppSubnetName"],
            "ADLC_DEV_CONTAINER_SUBNET_NAME": config["devContainerSubnetName"],
            "ADLC_STAGING_CONTAINER_SUBNET_NAME": config["stagingContainerSubnetName"],
            "ADLC_RUNNER_HTTPS_EGRESS_PREFIXES": json.dumps(config["runnerHttpsEgressPrefixes"]),
        })
        result = subprocess.run([sys.executable, str(PATH), "--azd-env"], env=env,
                                capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        env["ADLC_ENDPOINT_SUBNET_PREFIX"] = config["runnerSubnetPrefix"]
        result = subprocess.run([sys.executable, str(PATH), "--azd-env"], env=env,
                                capture_output=True, text=True, timeout=30)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("overlaps", result.stderr)

    def test_overlapping_subnet_is_rejected(self):
        config = valid_config()
        config["applicationSubnets"][0]["addressPrefix"] = "10.60.0.0/25"
        with self.assertRaisesRegex(ValueError, "overlaps"):
            module.validate(config)

    def test_subnet_outside_vnet_is_rejected(self):
        config = valid_config()
        config["endpointSubnetPrefix"] = "10.61.0.0/24"
        with self.assertRaisesRegex(ValueError, "outside"):
            module.validate(config)

    def test_unbounded_or_private_public_egress_is_rejected(self):
        for prefix in ("*", "0.0.0.0/0", "10.0.0.0/8"):
            config = valid_config()
            config["runnerHttpsEgressPrefixes"] = [prefix]
            with self.subTest(prefix=prefix), self.assertRaises(ValueError):
                module.validate(config)

    def test_reserved_subnet_names_are_case_insensitive(self):
        config = valid_config()
        config["applicationSubnets"][0]["name"] = "RUNNER"
        with self.assertRaisesRegex(ValueError, "duplicate"):
            module.validate(config)

    def test_api_subnets_must_be_distinct_and_delegated(self):
        config = valid_config()
        config["stagingAppSubnetName"] = "DEV-APPS"
        with self.assertRaisesRegex(ValueError, "distinct"):
            module.validate(config)
        config = valid_config()
        config["applicationSubnets"][0]["delegation"] = "Microsoft.ContainerInstance/containerGroups"
        with self.assertRaisesRegex(ValueError, "delegated"):
            module.validate(config)
        config = valid_config()
        config["applicationSubnets"][0]["addressPrefix"] = "10.60.2.0/29"
        with self.assertRaisesRegex(ValueError, "at least /28"):
            module.validate(config)

    def test_container_subnets_must_be_distinct_and_delegated(self):
        config = valid_config()
        config["stagingContainerSubnetName"] = "dev-apps"
        with self.assertRaisesRegex(ValueError, "distinct"):
            module.validate(config)
        config = valid_config()
        config["applicationSubnets"][2]["delegation"] = "Microsoft.Web/serverFarms"
        with self.assertRaisesRegex(ValueError, "delegated"):
            module.validate(config)
        config = valid_config()
        config["applicationSubnets"][2]["addressPrefix"] = "10.60.4.0/28"
        with self.assertRaisesRegex(ValueError, "at least /27"):
            module.validate(config)


if __name__ == "__main__":
    unittest.main()
