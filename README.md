# contoso-platform
Reproducible Azure ADLC demo lifecycle with azd, Bicep, GitHub agents and SRE

**Not deployable yet.** The canonical azd entrypoint, private deployment
execution, infrastructure, integrations and teardown remain unimplemented.

## Locked source bootstrap

Run `pwsh -File scripts\materialize-sources.ps1` before azd evaluates service
project paths. It materializes only the four allowlisted public application
repositories at the exact commits in `sources.lock.json`, and refuses to
overwrite, switch or clean an existing checkout. If a clone fails, inspect the
named partial checkout before retrying. The current lock records initial
baselines, not an approved release: three repositories contain documentation
only, and the students main branch contains characterization tests only.

`pwsh -File scripts\materialize-sources.ps1 -ValidateOnly` checks lock structure
without network access; it does not verify release readiness or deploy anything.

## Private execution foundation (incomplete)

The shared foundation Bicep composes one VNet, a delegated ACI runner subnet,
NAT, restrictive runner NSG, private DNS zones, and a dedicated deployment-script
identity and storage account. It also composes a private Premium registry,
shared Log Analytics workspace, and separate dev/staging Application Insights
resources. A separate awaited probe checks private DNS and TCP/TLS connectivity.
These modules have only been compiled and unit-tested;
they are not yet wired to azd, deploy workloads, or establish that a runner works
in Azure. Do not deploy them independently as a substitute for the stack.

The storage account follows the documented private deployment-script path:
shared-key capability is enabled, public network access is restricted by a
deny-by-default firewall, a storage service endpoint and trusted-services
exception, and an Azure Files private endpoint. The runner identity receives
Storage File Data Privileged Contributor only on that storage account. These
requirements and their permissions must be reviewed before deployment.

The caller must validate explicit network inputs with
`python scripts\validate-network-inputs.py <network-config.json>`; this check is
not yet connected to an azd lifecycle. It rejects overlapping or non-private
VNet subnets and unbounded runner HTTPS egress. The HTTPS destination list must
be derived and maintained for the actual deployment and authenticated control
plane; structural validation does not establish connectivity or trust. The NSG
allows private endpoint ports 443, 445, and 1433, DNS, storage service traffic,
and those explicit HTTPS ranges, and denies other runner outbound traffic.
SQL connectivity must use a policy compatible with this port restriction.
Application Insights local authentication is disabled: workloads need managed
identity-based telemetry authentication and a scoped ingestion role. Neither
the role wiring nor end-to-end telemetry has been implemented yet.

The SQL modules define private, Entra-only servers and one database per service.
Each environment has a separate bootstrap identity; the private grant script
assigns runtime identities read/write access and grants DDL only to distinct
migration identities. SQL principal discovery permissions, the azd hook,
application identity wiring, migrations, and the Azure execution itself are
not yet complete. The copied Azure SQL grant scripts must not be run directly
from an ordinary workstation against a private endpoint.

`scripts\stack-lock.py` implements an experimental GitHub-backed stack lock:
create is atomic and release checks the owner's operation ID and current blob
SHA. All generations of the same tenant/subscription/environment share a lock.
It requires a separately provisioned `adlc-state` branch and tightly scoped
write credentials, neither of which has been configured or verified. The
lifecycle does not yet invoke it. Do not clear an abandoned lock until the
owning operation is known to have stopped and the exact recovery is approved.
