# Security Policy

## Supported Versions

| Version | Supported |
|---------|-----------|
| 2.x     | Yes       |
| < 2.0   | No        |

## Scope

HU-NextExam-Manager manages Group Policy Objects (GPOs), WMI Filters, file shares,
and Intune/MDM deployments via Microsoft Graph API. Security issues in these areas
can have significant impact on school IT infrastructure.

## Reporting a Vulnerability

If you discover a security vulnerability, please report it responsibly:

1. **Do NOT open a public GitHub Issue**
2. Use [GitHub Security Advisories](https://github.com/ChiliApple/HU-NextExam-Manager/security/advisories/new) (preferred)
   or open a private issue via GitHub
3. Include:
   - Description of the vulnerability
   - Steps to reproduce
   - Potential impact
   - Suggested fix (if any)

You will receive an acknowledgment within 48 hours. Critical issues will be
addressed in a patch release within 7 days.

## Security Considerations

- **Credentials:** The tool stores Graph API secrets via DPAPI encryption.
  Never commit `config.json` with real tokens to version control.
- **GPO Permissions:** GPO creation requires Domain Admin or delegated
  Group Policy Creator Owners rights.
- **Network Shares:** MSI share paths should have restricted write access
  (admin-only write, authenticated users read).
- **Pull Script:** The GitHub PAT in `config.json` should be a fine-grained
  read-only token scoped to this repository only.
