# Security Policy

## Supported versions

| Version         | Supported |
| --------------- | --------- |
| 0.1.x           | Yes       |
| Earlier builds  | No        |

## Reporting a vulnerability

Please report suspected vulnerabilities privately:

1. Open the repository's **Security** tab on GitHub.
2. Choose **Report a vulnerability**. This uses GitHub's private vulnerability reporting, or go directly to <https://github.com/virajshoor/Ferox/security/advisories/new>.

Do not open a public issue, pull request or discussion for an unfixed vulnerability.

A useful report includes:

- the affected version or commit;
- the macOS version and Mac model or chip;
- steps to reproduce, with a minimal project or input file where possible (attach files rather than pasting large payloads);
- the impact you expect, and any mitigation you have identified.

## What to expect

These are the goals we work towards, not guaranteed service levels:

- Acknowledge receipt of a report within a few business days.
- Confirm or decline the issue, and share an initial severity assessment.
- Agree a fix and a coordinated disclosure date with the reporter.
- Credit the reporter in the advisory and the changelog, unless they prefer to remain anonymous.

## Scope

Swift Engine Ferox (Ferox) processes some untrusted input. The following areas deserve particular attention:

- **Asset importers** (glTF, image formats and JSON scene files). Malformed or hostile files should not cause crashes, memory exhaustion or out-of-bounds access.
- **Networking module**. Messages from peers and servers must be validated before use.
- **Shader hot-reload**. Reloaded shader source must not cause code to be loaded or executed from unexpected locations.

Vulnerabilities in macOS, Xcode or Apple's frameworks should be reported to Apple. Problems in a game built with Ferox are the responsibility of that game's developers, unless they are caused by Ferox itself.
