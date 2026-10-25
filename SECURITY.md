# Security

Mondek is experimental and has no supported stable release series yet. Do not assume a response-time or security-update commitment for an arbitrary development revision.

Report a suspected vulnerability privately to Pit Kleyersburg at [pitkley@googlemail.com](mailto:pitkley@googlemail.com). Include the affected revision, relevant configuration with secrets removed, reproduction steps and expected impact. Keep credentials, sensitive monitoring data and exploit details out of public issues while the report is being assessed.

Review [the controller trust boundary](docs/CONTROLLER-AUTH.md) before running an installation. The controller's operator UI and API require deployment-level access protection; runner code and its datasource credentials belong on the runner. A local demonstration is not a hardened network deployment.

Validation workflows use read permissions and receive no registry publishing credentials. Source/license and offline workflow audits are useful checks with finite coverage; they do not replace review of consumer code, deployment access or release artifacts.
