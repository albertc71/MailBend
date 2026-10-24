# Bounded SMTP session model: transport ordering, not cryptographic correctness.

import Base

type Mode is Data:
  StartTls{}
  Implicit{}

type SmtpEvent is Data:
  Greeting{}
  Ehlo{}
  StartTlsCommand{}
  Verified{}
  Failed{}
  Auth{}

# Maps to smtp/session.rs negotiate_tls and run. All non-TLS replies succeed;
# their failures only shorten a trace before AUTH. TLS verification is atomic.

def implicit_trace(verified: Bool) -> List<&2, SmtpEvent>:
  match verified:
    case True{}:
      [Verified{}, Greeting{}, Ehlo{}, Auth{}]
    case False{}:
      [Failed{}]

def starttls_trace(verified: Bool) -> List<&2, SmtpEvent>:
  match verified:
    case True{}:
      [Greeting{}, Ehlo{}, StartTlsCommand{}, Verified{}, Ehlo{}, Auth{}]
    case False{}:
      [Greeting{}, Ehlo{}, StartTlsCommand{}, Failed{}]

def trace(mode: Mode, verified: Bool) -> List<&2, SmtpEvent>:
  match mode:
    case StartTls{}:
      starttls_trace(verified)
    case Implicit{}:
      implicit_trace(verified)

# Every AUTH needs verified TLS; a failed handshake must end the trace.
# The safety check also checks every prefix, since each event is checked as
# it is consumed and an empty suffix is safe.

def ended(events: List<&2, SmtpEvent>) -> Bool:
  match events:
    case Nil{}:
      True{}
    case _:
      False{}

def safe(events: List<&2, SmtpEvent>, +verified: Bool) -> Bool:
  match events:
    case Nil{}:
      True{}
    case h <> t:
      match h:
        case Verified{}:
          safe(t, True{})
        case Failed{}:
          ended(t)
        case Auth{}:
          verified && safe(t, verified)
        case _:
          safe(t, verified)

# Implicit mode protects the greeting and every SMTP command, not only AUTH.

def protected(events: List<&2, SmtpEvent>, +verified: Bool) -> Bool:
  match events:
    case Nil{}:
      True{}
    case h <> t:
      match h:
        case Verified{}:
          protected(t, True{})
        case Failed{}:
          ended(t)
        case _:
          verified && protected(t, verified)

def has_auth(events: List<&2, SmtpEvent>) -> Bool:
  match events:
    case Nil{}:
      False{}
    case h <> t:
      match h:
        case Auth{}:
          True{}
        case _:
          has_auth(t)

law auth_requires_verified_tls:
  for mode: Mode
  for verified: Bool
  {safe(trace(mode, verified), False{}) == True{} : Bool}

def auth_requires_verified_tls(mode, verified):
  match mode verified:
    case StartTls{} True{}:
      {==}
    case StartTls{} False{}:
      {==}
    case Implicit{} True{}:
      {==}
    case Implicit{} False{}:
      {==}

law handshake_failure_cannot_authenticate:
  for mode: Mode
  {has_auth(trace(mode, False{})) == False{} : Bool}

def handshake_failure_cannot_authenticate(mode):
  match mode:
    case StartTls{}:
      {==}
    case Implicit{}:
      {==}

law implicit_smtp_requires_verified_tls:
  for verified: Bool
  {protected(implicit_trace(verified), False{}) == True{} : Bool}

def implicit_smtp_requires_verified_tls(verified):
  match verified:
    case True{}:
      {==}
    case False{}:
      {==}
