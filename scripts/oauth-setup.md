# Mail OAuth client setup

The native mail client uses XOAUTH2 over IMAP+SMTP. Each OAuth
provider needs a *Native* / *Desktop* client registration before the
mail flow will work end to end. PKCE replaces the client secret per
RFC 8252, so the values below are the only thing you need to paste in.

The Rust side reads each client ID from an environment variable at
autoconfig time, falling back to a compile-time placeholder otherwise:

| Provider | Env var |
|----------|---------|
| Google (Gmail, Stanford / Google Workspace, etc.) | `CLOME_GOOGLE_OAUTH_CLIENT_ID` |
| Microsoft (Outlook.com, Office 365, Hotmail, …) | `CLOME_MS_OAUTH_CLIENT_ID` |

Set them in whatever shell you launch `bun run tauri dev` from.

```sh
# ~/.zshrc (or wherever you keep dev env vars)
export CLOME_GOOGLE_OAUTH_CLIENT_ID="1060508097351-d64t2sfotpi30out0v42ffckblghi9vq.apps.googleusercontent.com"
export CLOME_MS_OAUTH_CLIENT_ID="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
```

Restart the Tauri dev process once they're in your shell.

---

## Google (Gmail, Workspace)

1. Open the Google Cloud Console: <https://console.cloud.google.com/>.
2. Create a new project (or pick an existing one). Name doesn't
   matter; only Rany sees it during dev.
3. Enable the **Gmail API** for the project — APIs & Services →
   Library → "Gmail API" → Enable. Required even for IMAP+SMTP via
   XOAUTH2 because Google's OAuth ties the consent to API surface.
4. APIs & Services → **OAuth consent screen**.
   * User Type = **External**.
   * App name = "Clome (dev)" or similar.
   * Developer email = your address.
   * Scopes: skip the "add scope" picker. The runtime requests
     `https://mail.google.com/` directly via the auth URL — Google
     accepts that without it being pre-listed, but it triggers a
     consent warning the first time.
   * Test users: add your own Google addresses (Gmail + Workspace,
     e.g. `ranycs@stanford.edu`). Google blocks anyone not on this
     list while the consent screen is in *Testing* status.
5. APIs & Services → **Credentials** → Create credentials →
   **OAuth client ID** → Application type = **Desktop app**.
6. Copy the resulting `…-….apps.googleusercontent.com` client ID
   into `CLOME_GOOGLE_OAUTH_CLIENT_ID`.

The Desktop-app client type is what makes Google accept arbitrary
`http://127.0.0.1:<port>/cb` redirect URIs without us pre-registering
them — exactly what `mail::oauth::begin` needs.

> **Stanford accounts:** Google Workspace tenants often disable
> third-party app access by default. If `ranycs@stanford.edu` bounces
> at the Google consent screen with "Access blocked", you'll need
> Stanford IT to allow your client ID, OR run the flow against a
> personal Gmail account first.

---

## Microsoft (Outlook.com, Office 365)

1. Azure Portal → **App registrations** → New registration:
   <https://portal.azure.com/#blade/Microsoft_AAD_RegisteredApps/ApplicationsListBlade>.
2. Name = "Clome (dev)".
3. Supported account types = **Personal Microsoft accounts only** for
   pure outlook.com testing, OR **Accounts in any organizational
   directory and personal Microsoft accounts** if you also want to
   target work/school accounts.
4. Redirect URI = **Public client/native (mobile & desktop)** →
   `http://localhost`. Microsoft accepts loopback redirects on this
   client type without pre-registering each port (RFC 8252 § 7.3).
5. Copy the **Application (client) ID** into `CLOME_MS_OAUTH_CLIENT_ID`.
6. **API permissions** → Add a permission → APIs my organization uses
   → search "Office 365 Exchange Online" → Delegated → check:
     * `IMAP.AccessAsUser.All`
     * `SMTP.Send`
     * `offline_access`
   Grant admin consent if you have it; otherwise the consent dialog
   will ask the user the first time.

---

## iCloud, Fastmail, Yahoo

These don't have public OAuth endpoints suitable for native clients
(see Open Question #2 in `blueprint/mail-client/plan-mail-client.md`).
For now, those providers will surface in `mail_autoconfig` with
`oauth = None`, and the v1 onboarding modal explains that an
**app-specific password** is required. v1 doesn't yet ship the
app-specific-password code path — that lands as a Phase 3.5 / Phase 4
follow-up once the OAuth happy path is solid.

---

## Verifying

With both env vars set:

```sh
cd /Users/ranystephan/Desktop/clome_ecosystem/clome
bun run tauri dev
```

1. Open the app, click the `+` in the Mail sidebar.
2. Type your Gmail address, hit Continue.
3. The browser should hand you to a normal Google sign-in — no "App
   not verified" dead-end, no "Access blocked".
4. Approve, return to the app, click "I'm signed in".
5. Click the ↻ on the account in the sidebar to fire an initial
   sync. Messages should populate.

If you see `oauth state mismatch` or `oauth provider error: invalid_client`,
the client ID is wrong or unregistered. Re-check the env var and
restart the Tauri dev process.
