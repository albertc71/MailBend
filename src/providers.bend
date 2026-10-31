# Reviewed, print-only provider configurations. No environment or IO access.

import Base
import ./json.bend as J
import ./mime.bend as M

type Settings is Data:
  Remote{imap: String, imap_port: String, smtp: String, smtp_port: String,
    tls: String, save_sent: String}
  Manual{reason: String}

type Preset is Data:
  Preset{name: String, settings: Settings, username: String, prerequisites: String,
    sources: List<&2, String>, tier: String}

def reviewed_on() -> String:
  "2026-10-31"

def presets() -> List<&2, Preset>:
  [
    Preset{"icloud", Remote{"imap.mail.me.com", "993", "smtp.mail.me.com", "587",
      "starttls", "1"}, "Full primary iCloud Mail address for both protocols.",
      "Create an Apple app-specific password with two-factor authentication enabled. " ++
      "Apple permits the full address for IMAP and requires it for SMTP. " ++
      "The existing iCloud profile recommends saving a Sent copy.",
      ["https://support.apple.com/102525", "https://support.apple.com/102654"],
      "documented; existing default profile, not newly live-tested"},
    Preset{"gmail", Remote{"imap.gmail.com", "993", "smtp.gmail.com", "465", "implicit", "0"},
      "Full Google account email address.",
      "Use an app password, not the account password. Enable 2-Step Verification first. " ++
      "App passwords may be unavailable with security-key-only verification, organization " ++
      "accounts, or Advanced Protection. Do not weaken account protection to use MailBend. " ++
      "Gmail saves SMTP-sent mail automatically. Review label visibility in IMAP settings.",
      ["https://developers.google.com/workspace/gmail/imap/imap-smtp",
        "https://support.google.com/accounts/answer/185833",
        "https://support.google.com/mail/answer/78892"], "documented; not live-tested"},
    Preset{"yahoo", Remote{"imap.mail.yahoo.com", "993", "smtp.mail.yahoo.com", "465",
      "implicit", "0"}, "Full Yahoo Mail account address.",
      "Generate a third-party app password in Yahoo account security. " ++
      "Review Sent-copy behavior before enabling writes.",
      ["https://help.yahoo.com/kb/SLN4075.html"], "documented; not live-tested"},
    Preset{"aol", Remote{"imap.aol.com", "993", "smtp.aol.com", "465", "implicit", "0"},
      "Full AOL Mail account address. This is not the Verizon.net SMTP profile.",
      "Generate a third-party app password in AOL account security. " ++
      "Provider help was unreadable during review; endpoints were checked in Thunderbird ISPDB. " ++
      "Review Sent-copy behavior before enabling writes.",
      ["https://github.com/thunderbird/autoconfig/blob/master/ispdb/aol.com.xml",
        "https://help.aol.com/articles/create-and-manage-app-password"],
      "ISPDB-reviewed; not provider-page-verified or live-tested"},
    Preset{"fastmail", Remote{"imap.fastmail.com", "993", "smtp.fastmail.com", "465",
      "implicit", "0"}, "Full primary Fastmail username, not an alias.",
      "Create an app password with mail access. The regular password does not work. " ++
      "Basic plans do not include IMAP or SMTP. Review Sent-copy behavior before enabling writes.",
      ["https://www.fastmail.help/hc/en-us/articles/1500000278342-Server-names-and-ports"],
      "documented; not live-tested"},
    Preset{"zoho", Remote{"imap.zoho.com", "993", "smtp.zoho.com", "465", "implicit", "0"},
      "Full Zoho Mail account address.",
      "Only the .com personal-account server profile is printed. Paid organizations use " ++
      "different hosts, and other datacenters differ. Compare both hosts with your account's " ++
      "Server Configuration Details before using this output. Enable IMAP for an eligible " ++
      "plan and use an app password with two-factor authentication. " ++
      "Zoho normally saves SMTP-sent mail; review that account setting.",
      ["https://www.zoho.com/mail/help/imap-access.html",
        "https://www.zoho.com/mail/help/zoho-smtp.html"],
      "documented .com personal profile only; not live-tested"},
    Preset{"gmx", Remote{"imap.gmx.com", "993", "mail.gmx.com", "465", "implicit", "0"},
      "Full GMX account address for the documented GMX.com profile.",
      "Enable POP3/IMAP access in GMX settings; it is off by default. " ++
      "Use an application-specific password. Review Sent-copy behavior before enabling writes.",
      ["https://support.gmx.com/pop-imap/imap/server.html",
        "https://support.gmx.com/pop-imap/toggle.html",
        "https://support.gmx.com/security/2fa/application-specific-passwords.html"],
      "documented GMX.com profile; not live-tested"},
    Preset{"web.de", Manual{"Thunderbird ISPDB specifies a local-part username for WEB.DE. " ++
      "MailBend uses one full email address for both login and sending, and full-address " ++
      "login was not established by the reviewed provider documentation. " ++
      "No configuration was guessed; this profile needs manual compatibility review."},
      "ISPDB specifies the part before @; full-address login is unverified.",
      "Enable POP3/IMAP access in WEB.DE settings and create an app password. " ++
      "Review Sent-copy behavior before enabling writes.",
      ["https://hilfe.web.de/pop-imap/imap/imap-serverdaten.html",
        "https://github.com/thunderbird/autoconfig/blob/master/ispdb/web.de.xml",
        "https://hilfe.web.de/sicherheit/2fa/anwendungsspezifisches-passwort.html"],
      "manual review required"},
    Preset{"mailbox.org", Remote{"imap.mailbox.org", "993", "smtp.mailbox.org", "465",
      "implicit", "0"}, "Full main mailbox.org address, not an alias.",
      "Create an email application password, required when two-factor authentication is on. " ++
      "Enable both IMAP and SMTP for that password. " ++
      "Review Sent-copy behavior before enabling writes.",
      ["https://kb.mailbox.org/en/private/e-mail/e-mail-configuration/",
        "https://kb.mailbox.org/en/private/security-and-privacy/e-mail-password/"],
      "documented; not live-tested"},
    Preset{"posteo", Remote{"posteo.de", "993", "posteo.de", "465", "implicit", "0"},
      "Full primary Posteo email address.",
      "Check Posteo's app-password and additional email account protection requirements. " ++
      "Provider help could not be fetched during review; endpoints were checked in " ++
      "Thunderbird ISPDB. Do not weaken protection to use MailBend. " ++
      "Review Sent-copy behavior before enabling writes.",
      ["https://github.com/thunderbird/autoconfig/blob/master/ispdb/posteo.de.xml",
        "https://posteo.de/en/blog/how-to-use-app-passwords-with-posteo"],
      "ISPDB-reviewed; prerequisites need local review; not live-tested"},
    Preset{"proton-bridge", Manual{"Proton Mail Bridge needs account-specific local ports, " ++
      "connection modes, and an explicit decision to trust its self-signed certificate. " ++
      "MailBend requires verified TLS and IMAP implicit TLS. No safe copyable preset is " ++
      "available without that manual review; no configuration was generated."},
      "Use only the username shown by Bridge, after manual review.",
      "Bridge must run locally. Review its settings and certificate with the account owner. " ++
      "Setup does not install Bridge, change trust, or bypass TLS verification.",
      ["https://proton.me/support/comprehensive-guide-to-bridge-settings",
        "https://proton.me/support/bridge-ssl-connection-issue"], "manual review required"}
  ]

def names(xs: List<&2, Preset>) -> List<&2, String>:
  match xs:
    case Nil{}:
      []
    case Preset{name, settings, username, prerequisites, sources, tier} <> t:
      name <> names(t)

def find(xs: List<&2, Preset>, +name: String) -> Maybe<&2, Preset>:
  match xs:
    case Nil{}:
      None{}
    case +p <> t:
      Preset{id, settings, username, prerequisites, sources, tier} = p
      Bool.pick(Maybe<&2, Preset>, String.eq(id, name), Some{p}, find(t, name))

def password_path() -> String:
  "/absolute/path/to/mailbend-password"

def env_fields(s: Settings, email: String) -> List<&2, J.Json>:
  match s:
    case Manual{reason}:
      []
    case Remote{imap, imap_port, smtp, smtp_port, tls, save_sent}:
      [J.kv("MAILBEND_EMAIL", J.str(email)),
        J.kv("MAILBEND_PASSWORD_FILE", J.str(password_path())),
        J.kv("MAILBEND_IMAP_HOST", J.str(imap)), J.kv("MAILBEND_IMAP_PORT", J.str(imap_port)),
        J.kv("MAILBEND_SMTP_HOST", J.str(smtp)), J.kv("MAILBEND_SMTP_PORT", J.str(smtp_port)),
        J.kv("MAILBEND_SMTP_TLS_MODE", J.str(tls)),
        J.kv("MAILBEND_READ_ONLY", J.str("1")), J.kv("MAILBEND_SAVE_SENT", J.str(save_sent))]

def shell_quote.body(s: String) -> String:
  match s:
    case SNil{}:
      ""
    case SCon{'\'', t}:
      "'\"'\"'" ++ shell_quote.body(t)
    case SCon{c, t}:
      SCon{c, shell_quote.body(t)}

def shell_quote(s: String) -> String:
  "'" ++ shell_quote.body(s) ++ "'"

def shell_fields(xs: List<&2, J.Json>) -> String:
  match xs:
    case Nil{}:
      ""
    case J.JKv{name, J.JStr{value}} <> t:
      "export " ++ name ++ "=" ++ shell_quote(value) ++ "\n" ++ shell_fields(t)
    case _ <> t:
      shell_fields(t)

def password_instructions() -> String:
  "Choose a new absolute file path outside attachment directories. " ++
  "Its parent directories must already exist and must not be symlinks. " ++
  "Replace the placeholder in both configuration blocks and in the Bash commands below. " ++
  "Use a file you own with mode 600. Unset any other password source.\n" ++
  "These are instructions for you, not commands that setup runs. " ++
  "Do not paste a password into chat, command arguments, or configuration JSON.\n\n" ++
  "```bash\n(\n  set +x\n  umask 077\n  set -o noclobber\n" ++
  "  IFS= read -rs -p 'App password: ' mailbend_password </dev/tty &&\n" ++
  "    printf '\\n' >/dev/tty &&\n" ++
  "    printf '%s' \"$mailbend_password\" > " ++ shell_quote(password_path()) ++ "\n" ++
  "  mailbend_status=$?\n  unset mailbend_password\n  exit \"$mailbend_status\"\n)\n```\n"

def metadata(p: Preset) -> String:
  Preset{name, settings, username, prerequisites, sources, tier} = p
  "Provider: " ++ name ++ "\nTier: " ++ tier ++ "\nReviewed: " ++ reviewed_on() ++
    "\nUsername: " ++ username ++ "\nPrerequisites: " ++ prerequisites ++
    "\nSources:\n" ++ String.join(sources, "\n") ++ "\n"

def render.settings(s: Settings, p: Preset, email: String) -> Result<&2, &2, String, String>:
  match s:
    case Manual{reason}:
      Fail{metadata(p) ++ reason}
    case Remote{imap, imap_port, smtp, smtp_port, tls, save_sent}:
      +fields = env_fields(Remote{imap, imap_port, smtp, smtp_port, tls, save_sent}, email)
      Done{metadata(p) ++ "\nNothing was applied or checked. " ++
        "Read-only is on; enabling writes is a separate decision. " ++
        "Sent-copy is off unless the profile explicitly recommends it.\n\n" ++
        "Environment block:\n```sh\n" ++ shell_fields(fields) ++ "```\n\n" ++
        "MCP env block:\n```json\n" ++ J.show(J.obj([J.kv("env", J.obj(fields))])) ++
        "\n```\n\n" ++ password_instructions() ++
        "\nAfter applying settings yourself, run mailbend setup --check. " ++
        "That command connects to the configured servers and reports local folder names. " ++
        "For shareable output use mailbend diagnose --imap --smtp instead.\n"}

def render.found(p: Maybe<&2, Preset>, email: String) -> Result<&2, &2, String, String>:
  match p:
    case None{}:
      Fail{"Unknown provider; no configuration was guessed. Supported names: " ++
        String.join(names(presets()), ", ") ++ ". OAuth is unsupported; see " ++
        "https://github.com/albertc71/MailBend/issues/28"}
    case Some{+preset}:
      Preset{name, settings, username, prerequisites, sources, tier} = preset
      render.settings(settings, preset, email)

def render(+provider: String, +email: String) -> Result<&2, &2, String, String>:
  do Result<&2, &2, String, String>:
    bounded : Unit <- Bool.pick(Result<&2, &2, String, Unit>,
      Nat.is_le(String.length(email), 254n), Done{Unit{}},
      Fail{"--email must be at most 254 ASCII characters"})
    valid : Unit <- Bool.pick(Result<&2, &2, String, Unit>,
      M.addr_ok(email) && String.eq(email, M.addr_spec(email)), Done{Unit{}},
      Fail{"--email must be a bare printable ASCII email address, without spaces or controls"})
    password_only : Unit <- Bool.pick(Result<&2, &2, String, Unit>,
      List.contains(~String, ~String.eq,
        ["outlook", "outlook.com", "hotmail", "hotmail.com", "office365", "microsoft365"],
        String.to_lower(provider)),
      Fail{"This provider requires OAuth, which MailBend does not support. " ++
        "No configuration was generated. See https://github.com/albertc71/MailBend/issues/28"},
      Done{Unit{}})
    render.found(find(presets(), String.to_lower(provider)), email)
