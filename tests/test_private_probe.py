import importlib.util
import unittest
from pathlib import Path
from unittest.mock import patch

PATH = Path(__file__).resolve().parents[1] / "infra" / "modules" / "private-probe.py"
spec = importlib.util.spec_from_file_location("private_probe", PATH)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class PrivateProbeTests(unittest.TestCase):
    def test_rejects_non_service_host_and_unsupported_kind(self):
        for endpoint in [
            {"host": "example.com", "kind": "https"},
            {"host": "host.database.windows.net", "kind": "shell"},
            {"host": "host.database.windows.net;echo", "kind": "sql"},
        ]:
            with self.subTest(endpoint=endpoint), self.assertRaises(ValueError):
                module.check_endpoint(endpoint)

    def test_rejects_any_public_dns_result_before_connecting(self):
        addresses = [(2, 1, 6, "", ("10.0.0.1", 1433)), (2, 1, 6, "", ("8.8.8.8", 1433))]
        with patch.object(module.socket, "getaddrinfo", return_value=addresses), \
             patch.object(module.socket, "create_connection") as connect:
            with self.assertRaisesRegex(ValueError, "exclusively"):
                module.check_endpoint({"host": "school.database.windows.net", "kind": "sql"})
            connect.assert_not_called()

    def test_connects_to_resolved_private_sql_address(self):
        addresses = [(2, 1, 6, "", ("10.1.2.3", 1433))]
        with patch.object(module.socket, "getaddrinfo", return_value=addresses), \
             patch.object(module.socket, "create_connection") as connect:
            result = module.check_endpoint({"host": "school.database.windows.net", "kind": "sql"})
        connect.assert_called_once_with(("10.1.2.3", 1433), timeout=10)
        self.assertEqual(result["result"], "reachable")

    def test_https_validates_tls_using_original_hostname(self):
        addresses = [(2, 1, 6, "", ("10.1.2.4", 443))]
        host = "school.scm.azurewebsites.net"
        with patch.object(module.socket, "getaddrinfo", return_value=addresses), \
             patch.object(module.socket, "create_connection") as connect, \
             patch.object(module.ssl, "create_default_context") as context:
            module.check_endpoint({"host": host, "kind": "https"})
        context.return_value.wrap_socket.assert_called_once_with(
            connect.return_value.__enter__.return_value, server_hostname=host
        )

    def test_connection_failure_is_not_reported_as_success(self):
        addresses = [(2, 1, 6, "", ("10.1.2.3", 1433))]
        with patch.object(module.socket, "getaddrinfo", return_value=addresses), \
             patch.object(module.socket, "create_connection", side_effect=TimeoutError):
            with self.assertRaises(TimeoutError):
                module.check_endpoint({"host": "school.database.windows.net", "kind": "sql"})


if __name__ == "__main__":
    unittest.main()
