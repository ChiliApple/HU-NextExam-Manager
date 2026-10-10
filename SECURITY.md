# Security Policy

## Supported Versions

| Version | Supported |
|---------|-----------|
| 3.2+    | Yes       |
| < 3.2   | No (unsigned updates - please update) |

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
- **Signed updates (v3.2.0+):** Updates are only taken from GitHub releases that carry
  `HU-NextExam-Manager-files.sha256` (SHA256 of every file, built by CI) and a detached
  PKCS#7 signature `HU-NextExam-Manager-files.sha256.p7s` made with the publisher's
  certificate (thumbprint `1B669AE240DA1A91043C4576763D9F8E0BF762FA`, built into the tool).
  The private key never touches GitHub. All files are downloaded and verified before any
  file is replaced.
- **GitHub token (v3.4.0+):** The optional GitHub PAT (rate limits only) is entered in
  `Config\config.json` (`ToolSettings.GitHubToken`); on the next elevated start the tool moves it to
  `Config\github-token.dat` (DPAPI LocalMachine, readable by SYSTEM/Administrators only) and clears
  the field. Use a fine-grained read-only token scoped to this repository only.
