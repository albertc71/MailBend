# Exact diagnostic dispatch and near-misses retain the original closed vocabulary.

import Base
import ../../src/diagnostics.bend as D
import ../../src/json.bend as J

type GuidanceCase is Data:
  GuidanceCase{key: String, expected: String}

type PlatformCase is Data:
  PlatformCase{key: String, expected: J.Json}

def upper_head(s: String) -> String:
  match s:
    case SCon{c, rest}:
      SCon{Char.from_u32((Char.to_u32(c) - 32 : U32)), rest}
    case SNil{}:
      ""

def guidance_default(s: String) -> Bool:
  String.eq(D.guidance(s),
    "Check provider availability and protocol support; retry within the diagnostic deadline.")

def guidance_near(+key: String) -> Bool:
  guidance_default("x" ++ key) && guidance_default(key ++ "x") &&
    guidance_default(key ++ SCon{Char.from_u32(0), ""}) &&
    guidance_default(upper_head(key))

def guidance_cases(xs: List<&2, GuidanceCase>) -> Bool:
  match xs:
    case Nil{}:
      guidance_default("")
    case GuidanceCase{key, expected} <> rest:
      +key = key
      String.eq(D.guidance(key), expected) && guidance_near(key) && guidance_cases(rest)

def platform_default(s: String) -> Bool:
  String.eq(J.show(D.platform_line(s)), J.show(D.platform_error("invalid_diagnostic_response")))

def platform_near(+key: String) -> Bool:
  platform_default("x" ++ key) && platform_default(key ++ "x") &&
    platform_default(key ++ SCon{Char.from_u32(0), ""}) && platform_default(upper_head(key))

def platform_cases(xs: List<&2, PlatformCase>) -> Bool:
  match xs:
    case Nil{}:
      platform_default("")
    case PlatformCase{key, expected} <> rest:
      +key = key
      String.eq(J.show(D.platform_line(key)), J.show(expected)) &&
        platform_near(key) && platform_cases(rest)

def main() -> IO(Unit):
  do IO<Unit>:
    IO.print(Bool.show(guidance_cases([
      GuidanceCase{"configuration", "Check documented switches, host, port, connection IP and DoH settings."},
      GuidanceCase{"credentials", "Configure one password source and account; OAuth is unsupported. Never share secrets."},
      GuidanceCase{"trust_store", "Check system CAs, SSL_CERT_FILE, SSL_CERT_DIR or MAILBEND_CA_FILE; " ++
        "verification is mandatory."},
      GuidanceCase{"helper", "Rebuild with scripts/install.sh; use an absolute executable MAILBEND_TLS_HELPER path."},
      GuidanceCase{"dns", "Check DNS or DoH connectivity and resolver configuration."},
      GuidanceCase{"connect", "Check the configured port, firewall and provider connectivity."},
      GuidanceCase{"tls", "Check the configured SMTP TLS mode and port; IMAP uses implicit verified TLS."},
      GuidanceCase{"authentication", "Check provider password-login support and credentials; SMTP needs AUTH PLAIN or LOGIN."},
      GuidanceCase{"folders", "Inspect mail_probe locally; resolve each missing or ambiguous role with an existing folder."}
    ])))
    IO.print(Bool.show(platform_cases([
      PlatformCase{"openat2 ok", D.platform_fact("openat2", "ok", "ok")},
      PlatformCase{"openat2 unsupported", D.platform_fact("openat2", "failed", "unsupported")},
      PlatformCase{"attach_dir ok", D.platform_fact("attach_dir", "ok", "ok")},
      PlatformCase{"attach_dir refused", D.platform_fact("attach_dir", "failed", "refused")},
      PlatformCase{"attach_dir unset", D.platform_fact("attach_dir", "skipped", "unset")},
      PlatformCase{"download_tmpfile ok", D.platform_fact("download_tmpfile", "ok", "ok")},
      PlatformCase{"download_tmpfile unsupported", D.platform_fact("download_tmpfile", "failed", "unsupported")},
      PlatformCase{"download_tmpfile refused", D.platform_fact("download_tmpfile", "failed", "refused")},
      PlatformCase{"download_tmpfile unset", D.platform_fact("download_tmpfile", "skipped", "unset")},
      PlatformCase{"arch x86_64", D.platform_fact("arch", "ok", "x86_64")},
      PlatformCase{"arch aarch64", D.platform_fact("arch", "ok", "aarch64")},
      PlatformCase{"arch other", D.platform_fact("arch", "ok", "other")}
    ])))

#|True
#|True
