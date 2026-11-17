import importlib.util
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
        ],
        "devAppSubnetName": "dev-apps",
        "stagingAppSubnetName": "staging-apps",
        "runnerHttpsEgressPrefixes": ["20.0.0.0/8"],
    }


class NetworkInputTests(unittest.TestCase):
    def test_valid_configuration(self):
        module.validate(valid_config())

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


if __name__ == "__main__":
    unittest.main()
