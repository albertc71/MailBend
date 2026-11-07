"""Synthetic auth/greeting refusal matrix shared by transport and client tests."""


def cases(password):
    # Fake secrets and token-looking prose must never become diagnostic facts.
    hostile = ' private-server-marker ' + password + ' mailbend-auth: credentials'
    for code, reason in (('UNAVAILABLE', 'temporary'), ('LIMIT', 'limit'),
                         ('INUSE', 'in_use'), ('EXPIRED', 'expired'),
                         ('CONTACTADMIN', 'contact_admin'),
                         ('AUTHENTICATIONFAILED', 'credentials'),
                         ('X-PRIVATE', 'unknown'), ('', 'credentials')):
        response = 'NO ' + (f'[{code}]' if code else '') + hostile
        yield 'imap-' + (code or 'no-code'), 'imap', 'authentication', reason, 4, 1, {
            'imap_auth_refusal': response}
    for bye, label in (('BYE', 'codeless'), ('BYE [UNAVAILABLE]', 'temporary')):
        for response, reason in (('NO [AUTHENTICATIONFAILED]', 'credentials'),
                                 ('NO', 'credentials'),
                                 ('NO [UNAVAILABLE]', 'temporary'),
                                 ('BAD', 'unknown')):
            suffix = response.replace(' ', '-').replace('[', '').replace(']', '')
            yield f'imap-bye-{label}-then-{suffix}', 'imap', 'authentication', reason, 4, 1, {
                'imap_auth_bye': bye + hostile,
                'imap_auth_refusal': response + hostile}
    for bye, reason in (('BYE', 'unknown'), ('BYE [UNAVAILABLE]', 'temporary'),
                        ('BYE [X-PRIVATE]', 'unknown')):
        label = bye.replace(' ', '-').replace('[', '').replace(']', '')
        yield f'imap-{label}-then-close', 'imap', 'authentication', reason, 6, 1, {
            'imap_auth_bye': bye + hostile}
    # Substrings and server prose cannot impersonate a response code.
    for code in ('XUNAVAILABLE', 'UNAVAILABLEX'):
        yield 'imap-' + code, 'imap', 'authentication', 'unknown', 4, 1, {
            'imap_auth_refusal': f'NO [{code}]' + hostile}
    # A familiar code cannot rescue a malformed tagged response status.
    for status in ('NOPE', 'BYE'):
        yield 'imap-tagged-' + status, 'imap', 'authentication', 'unknown', 4, 1, {
            'imap_auth_refusal': status + ' [UNAVAILABLE]' + hostile}
    for response, reason in (('BYE', 'greeting_refused'),
                             ('BYE [UNAVAILABLE]', 'temporary')):
        yield 'imap-greeting-' + reason, 'imap', 'greeting', reason, 6, 0, {
            'imap_greeting_refusal': response + hostile}
    for mechanism, stages in (('PLAIN', ('command',)),
                              ('LOGIN', ('command', 'user', 'password'))):
        for stage in stages:
            for code, reason in ((454, 'temporary'), (421, 'temporary'),
                                 (535, 'credentials'), (550, 'unknown')):
                yield f'smtp-{mechanism}-{stage}-{code}', 'smtp', 'authentication', reason, 4, {
                    'command': 1, 'user': 2, 'password': 3}[stage], {
                        'smtp_auth': mechanism,
                        'smtp_auth_refusal_stage': stage,
                        'smtp_auth_refusal': str(code) + hostile}
    for code, reason in ((421, 'temporary'), (554, 'greeting_refused')):
        yield f'smtp-greeting-{code}', 'smtp', 'greeting', reason, 6, 0, {
            'smtp_greeting_refusal': str(code) + hostile}
