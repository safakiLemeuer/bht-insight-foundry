# Security Policy

## Reporting a vulnerability

Do not open public issues containing vulnerability details, credentials, tenant identifiers, or customer data.

Use GitHub private vulnerability reporting when enabled, or contact the repository owner through an approved private channel.

## Security principles

- Prefer Microsoft Entra ID and managed identity over stored credentials.
- Store production secrets in Azure Key Vault.
- Apply least-privilege Azure RBAC.
- Validate all external input.
- Treat retrieved documents as untrusted content.
- Defend against direct and indirect prompt injection.
- Do not log prompts, documents, or model outputs containing sensitive data without explicit authorization.
- Use timeouts, bounded retries, rate limiting, and token limits.
- Deny unsupported file types and oversized uploads.
- Keep dependencies patched and reviewed.
