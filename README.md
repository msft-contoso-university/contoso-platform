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
