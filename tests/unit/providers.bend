# Provider endpoint contracts and print-only safety defaults.

import Base
import ../../src/providers.bend as P
import ../../src/json.bend as J

def settings(s: P.Settings) -> String:
  match s:
    case P.Manual{reason}:
      "manual"
    case P.Remote{imap, imap_port, smtp, smtp_port, tls, save_sent, policy}:
      String.join([imap, imap_port, smtp, smtp_port, tls, save_sent], "|")

def render_text(r: Result<&2, &2, String, String>) -> String:
  match r:
    case Done{text}:
      text
    case Fail{reason}:
      reason

def succeeds(r: Result<&2, &2, String, String>) -> Bool:
  match r:
    case Done{text}:
      True{}
    case Fail{reason}:
      False{}

def safe(+text: String) -> Bool:
  Bool.not(String.contains(text, "MAILBEND_APP_PASSWORD")) &&
    Bool.not(String.contains(text, "MAILBEND_CA_FILE"))

def rendered(r: Result<&2, &2, String, String>, shell: String, json: String) -> Bool:
  match r:
    case Done{+text}:
      safe(text) && String.contains(text, shell) && String.contains(text, json)
    case Fail{reason}:
      False{}

def refused(r: Result<&2, &2, String, String>) -> Bool:
  match r:
    case Done{text}:
      False{}
    case Fail{+reason}:
      safe(reason) && Bool.not(String.contains(reason, "```"))

def web_de_refusals(emails: List<&2, String>) -> Bool:
  match emails:
    case Nil{}:
      True{}
    case email <> rest:
      refused(P.render("web.de", email)) && web_de_refusals(rest)

def rows(xs: List<&2, P.Preset>) -> IO(Unit):
  match xs:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case P.Preset{+name, s, username, prerequisites, sources, tier} <> t:
      do IO<Unit>:
        IO.print(name ++ "|" ++ settings(s) ++ "|" ++ tier)
        IO.print(String.join(sources, " "))
        IO.print(Bool.show(safe(render_text(P.render(name,
          Bool.pick(String, String.eq(name, "web.de"), "Reader.Name@web.de", "reader@example.com"))))))
        rows(t)

def main() -> IO(Unit):
  do IO<Unit>:
    rows(P.presets())
    IO.print(P.shell_quote("o'hara+$`whoami`@example.com"))
    IO.print(Bool.show(succeeds(P.render("GMAIL", "reader@example.com"))))
    IO.print(Bool.show(succeeds(P.render("unknown", "reader@example.com"))))
    IO.print(Bool.show(succeeds(P.render("outlook", "reader@example.com"))))
    IO.print(Bool.show(succeeds(P.render("hotmail.com", "reader@example.com"))))
    IO.print(Bool.show(succeeds(P.render("office365", "reader@example.com"))))
    IO.print(Bool.show(succeeds(P.render("gmail", "reader@example.com\nexport BAD=1"))))
    IO.print(Bool.show(succeeds(P.render("gmail", "Name <reader@example.com>"))))
    IO.print(Bool.show(succeeds(P.render("gmail", "reader@example.com (comment)"))))
    IO.print(Bool.show(succeeds(P.render("gmail", " reader@example.com"))))
    IO.print(Bool.show(succeeds(P.render("gmail", "no-address"))))
    IO.print(J.show(J.obj(P.env_fields(
      P.Remote{"imap.example.com", "993", "smtp.example.com", "465", "implicit", "0", P.EmailFallback{}},
      "o'hara+$`whoami`@example.com", ""))))
    IO.print(Bool.show(rendered(P.render("web.de", "Reader.Name@web.de"),
      "export MAILBEND_EMAIL='Reader.Name@web.de'\nexport MAILBEND_LOGIN='Reader.Name'\n",
      "{\"env\":{\"MAILBEND_EMAIL\":\"Reader.Name@web.de\",\"MAILBEND_LOGIN\":\"Reader.Name\",\"MAILBEND_PASSWORD_FILE\":\"/absolute/path/to/mailbend-password\",\"MAILBEND_IMAP_HOST\":\"imap.web.de\",\"MAILBEND_IMAP_PORT\":\"993\",\"MAILBEND_SMTP_HOST\":\"smtp.web.de\",\"MAILBEND_SMTP_PORT\":\"465\",\"MAILBEND_SMTP_TLS_MODE\":\"implicit\",\"MAILBEND_READ_ONLY\":\"1\",\"MAILBEND_SAVE_SENT\":\"0\"}}"))))
    IO.print(Bool.show(rendered(P.render("WEB.DE", "Reader.Name@WEB.DE"),
      "export MAILBEND_EMAIL='Reader.Name@WEB.DE'\nexport MAILBEND_LOGIN='Reader.Name'\n",
      "\"MAILBEND_EMAIL\":\"Reader.Name@WEB.DE\",\"MAILBEND_LOGIN\":\"Reader.Name\""))))
    IO.print(Bool.show(rendered(P.render("web.de", "o'hara+$`whoami`@web.de"),
      "export MAILBEND_LOGIN='o'\"'\"'hara+$`whoami`'\n",
      "\"MAILBEND_EMAIL\":\"o'hara+$`whoami`@web.de\",\"MAILBEND_LOGIN\":\"o'hara+$`whoami`\""))))
    IO.print(Bool.show(web_de_refusals(["reader@example.com", "reader@sub.web.de",
      "reader@web.de.example", "reader@web.de.", "reader@notweb.de",
      "@web.de", "reader@", "reader@@web.de", " reader@web.de", "reader@web.de ",
      "Name <reader@web.de>", "reader@web.de (comment)", "reader@web.de\n",
      "é@web.de", "missing-at"])))
    IO.print(Bool.show(rendered(P.render("gmail", "Reader.Name@web.de"),
      "export MAILBEND_LOGIN=''\n",
      "\"MAILBEND_EMAIL\":\"Reader.Name@web.de\",\"MAILBEND_LOGIN\":\"\""))))
    IO.print(Bool.show(refused(P.render("proton-bridge", "Reader.Name@web.de"))))

#|icloud|imap.mail.me.com|993|smtp.mail.me.com|587|starttls|1|documented; existing default profile, not newly live-tested
#|https://support.apple.com/102525 https://support.apple.com/102654
#|True
#|gmail|imap.gmail.com|993|smtp.gmail.com|465|implicit|0|documented; not live-tested
#|https://developers.google.com/workspace/gmail/imap/imap-smtp https://support.google.com/accounts/answer/185833 https://support.google.com/mail/answer/78892
#|True
#|yahoo|imap.mail.yahoo.com|993|smtp.mail.yahoo.com|465|implicit|0|documented; not live-tested
#|https://help.yahoo.com/kb/SLN4075.html
#|True
#|aol|imap.aol.com|993|smtp.aol.com|465|implicit|0|ISPDB-reviewed; not provider-page-verified or live-tested
#|https://github.com/thunderbird/autoconfig/blob/master/ispdb/aol.com.xml https://help.aol.com/articles/create-and-manage-app-password
#|True
#|fastmail|imap.fastmail.com|993|smtp.fastmail.com|465|implicit|0|documented; not live-tested
#|https://www.fastmail.help/hc/en-us/articles/1500000278342-Server-names-and-ports
#|True
#|zoho|imap.zoho.com|993|smtp.zoho.com|465|implicit|0|documented .com personal profile only; not live-tested
#|https://www.zoho.com/mail/help/imap-access.html https://www.zoho.com/mail/help/zoho-smtp.html
#|True
#|gmx|imap.gmx.com|993|mail.gmx.com|465|implicit|0|documented GMX.com profile; not live-tested
#|https://support.gmx.com/pop-imap/imap/server.html https://support.gmx.com/pop-imap/toggle.html https://support.gmx.com/security/2fa/application-specific-passwords.html
#|True
#|web.de|imap.web.de|993|smtp.web.de|465|implicit|0|endpoints documented; username ISPDB-reviewed 2026-11-08; not live-tested
#|https://hilfe.web.de/pop-imap/imap/imap-serverdaten.html https://github.com/thunderbird/autoconfig/blob/3a5b95752363cdcdad8928d7d29a993cbdabcad2/ispdb/web.de.xml https://hilfe.web.de/sicherheit/2fa/anwendungsspezifisches-passwort.html
#|True
#|mailbox.org|imap.mailbox.org|993|smtp.mailbox.org|465|implicit|0|documented; not live-tested
#|https://kb.mailbox.org/en/private/e-mail/e-mail-configuration/ https://kb.mailbox.org/en/private/security-and-privacy/e-mail-password/
#|True
#|posteo|posteo.de|993|posteo.de|465|implicit|0|ISPDB-reviewed; prerequisites need local review; not live-tested
#|https://github.com/thunderbird/autoconfig/blob/master/ispdb/posteo.de.xml https://posteo.de/en/blog/how-to-use-app-passwords-with-posteo
#|True
#|proton-bridge|manual|manual review required
#|https://proton.me/support/comprehensive-guide-to-bridge-settings https://proton.me/support/bridge-ssl-connection-issue
#|True
#|'o'"'"'hara+$`whoami`@example.com'
#|True
#|False
#|False
#|False
#|False
#|False
#|False
#|False
#|False
#|False
#|{"MAILBEND_EMAIL":"o'hara+$`whoami`@example.com","MAILBEND_LOGIN":"","MAILBEND_PASSWORD_FILE":"/absolute/path/to/mailbend-password","MAILBEND_IMAP_HOST":"imap.example.com","MAILBEND_IMAP_PORT":"993","MAILBEND_SMTP_HOST":"smtp.example.com","MAILBEND_SMTP_PORT":"465","MAILBEND_SMTP_TLS_MODE":"implicit","MAILBEND_READ_ONLY":"1","MAILBEND_SAVE_SENT":"0"}
#|True
#|True
#|True
#|True
#|True
#|True
