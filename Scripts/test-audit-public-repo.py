#!/usr/bin/env python3
"""Fixture test for the inline-secret-assignment rule, both directions: a
reference passed where a secret's value goes is silent, and a real literal
in the same position still matches.
"""
import importlib.util
from pathlib import Path

ROOT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("audit_public_repo", ROOT / "audit-public-repo.py")
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)

RULE = dict(audit.CONTENT_RULES)["inline secret assignment"]


def matches(text: str) -> bool:
    return RULE.search(text) is not None


assert not matches("CaptureIntent.hostScreen(token: tokenA)"), \
    "a bare identifier argument is not a literal secret"
assert not matches("CaptureIntent.hostScreen(token: tokenA) == CaptureIntent.hostScreen(token: tokenA)"), \
    "the same shape repeated (both call sites in the real test file) must not match either"
assert not matches("SessionStateMachine(captureIntent: .hostScreen(token: tokenA))"), \
    "a bare identifier still reads as an identifier when nested one call deeper"
assert not matches("password = adminPassword;"), \
    "a bare identifier terminated by a semicolon is excluded the same way as one terminated by a parenthesis"
assert not matches("secret: nextValue,\n"), \
    "a bare identifier terminated by a comma (a middle argument, not the last) is excluded the same way"

# A dotted member-access path is no more a hardcoded secret than a bare identifier.
assert not matches("token: scenario.token,"), \
    "a dotted member-access path is not a literal secret"
assert not matches("guard.admit(deviceKey: key, token: fixture.expectedToken)"), \
    "a dotted path nested inside a real call, not just the minimal reproduction, is still excluded"
assert not matches("secret: config.nested.value;"), \
    "a path more than one dot deep is still a reference, not a literal, and is excluded the same way"

# A reference invoked as a call -- the identifier or dotted path is itself
# calling something, not holding a value -- is excluded too.
assert not matches("let token = Self.secureRandomToken()"), \
    "a dotted reference immediately invoked with empty parens is not a literal secret"
assert not matches("token: Data([0x01, 0x02])"), \
    "a bare identifier immediately invoked with a literal argument (constructing fixture bytes, not holding a secret string) must not match"
assert not matches("token = offerAndExtractToken(fixture.controller)"), \
    "a bare identifier naming a function, invoked with a reference argument, must not match"

# A reference that is the right-hand side of a `guard`/`if let ... else`
# binding is excluded the same way as an argument reference.
assert not matches("guard let token = wire.hostScreenToken else {"), \
    "a dotted reference bound by `guard let ... else` is not a literal secret"
assert not matches("if let apiKey = self.config.apiKey else {"), \
    "a deeper dotted path in the identical `if let ... else` position is still excluded"

# A reference that names an Optional type, not a value, is excluded the
# same way: a Swift parameter like `token: Data?` binds no literal at all.
assert not matches("func selectRealScreen(token: Data?)"), \
    "an Optional-typed parameter is not a literal secret"
assert not matches("func selectRealScreen(token: Data?) {}"), \
    "the same parameter shape with a following function body brace is still excluded"

# A reference that is the source of an `as`/`as?`/`as!` cast is excluded
# the same way: casting a reference to a type is not holding a literal
# secret value either.
assert not matches("let token = sender.representedObject as? Data"), \
    "a dotted reference cast with `as?` is not a literal secret"
assert not matches("let secret = value as! Data"), \
    "the same shape with a forced cast (`as!`) is still excluded"
assert not matches("let apiKey = config.rawKey as Data"), \
    "the same shape with an unconditional cast (`as`, no `?` or `!`) is still excluded"

# A reference position with no identifier at all -- the terminator sitting
# directly after the colon, no space, no name -- is excluded too: prose
# naming a parameter label by itself holds no value.
assert not matches("`token:)`/`shouldStartHostScreenRequest`"), \
    "a parameter label closed by its own paren, immediately followed by an unrelated code span with " \
    "no space between, is not a literal secret"
assert not matches("(token:)"), \
    "the same shape without the surrounding markdown backticks is still excluded"
assert not matches("secret:,"), \
    "the same shape terminated by a comma instead of a parenthesis is still excluded"

# The zero-identifier exclusion only covers terminators that cannot start a
# value in that same label-only shape -- `)`, `?`, `else`, `as` -- never
# `(`, `,`, or `;`, which a real literal can start with when nothing
# precedes it.
assert matches("token = (abcdef1234567890)"), \
    "a literal immediately wrapped in its own parens, nothing before the paren -- must still match: an" \
    " opening paren is never a terminator, identifier-less or not"
assert matches("secret: (abcdef1234567890)"), \
    "the same shape with a colon separator instead of `=` must still match"
assert matches("token: ,abcdef1234567890"), \
    "a literal immediately preceded by a bare comma -- nothing before it -- must still match: a comma" \
    " terminates an argument that came before it, never stands in for one"
assert matches("token = ;abcdef1234567890"), \
    "the same shape with a semicolon in place of the comma must still match"

# A genuine literal in the exact same syntactic position is still caught:
# proof this narrowed the false-positive shape specifically, not secret
# detection generally.
assert matches('CaptureIntent.hostScreen(token: "abcdef123456")'), \
    "a quoted literal passed in the identical argument position as the false positive still matches"
assert matches('token: "scenario.token"'), \
    "a quoted string that merely looks like a dotted path is still a literal and still matches -- the quotes, not the shape of what is inside them, decide this one"
assert matches('password = "hunter2fallback"'), \
    "a quoted string literal assignment still matches"
assert matches("apiKey = 0xDEADBEEF12345678"), \
    "an unquoted numeric/hex literal still matches -- it cannot be mistaken for an identifier, since identifiers cannot start with a digit"
assert matches("secret: correct-horse-battery-staple"), \
    "an unquoted value containing hyphens cannot be an identifier in any language this rule needs to cover, so it is never excluded regardless of what terminates it"
assert matches("token=abc123xyz456\n"), \
    "a bare identifier-shaped value with no call/statement terminator after it -- end of line, the shape an unquoted secret takes in a shell or .env-style config line -- still matches; only the specific argument-position shape (immediately followed by `)`, `,`, or `;`) is excluded"
assert matches("token=abc123xyz456"), \
    "the same value at true end of string (no trailing newline) still matches too"
assert matches('token: "abcdef123456"(x)'), \
    "a quoted literal immediately followed by a call still matches -- only a bare identifier invoking one is excluded"
assert matches('secret = "hunter2fallback" else {'), \
    "a quoted literal in the identical `... else` position as the guard-let false positive still matches"


# A `_key`/`_token` compound name and a JSON-quoted key must both match.
assert matches("secret_key=abcdef1234567890"), \
    "a `_key`-suffixed keyword assigned a literal must match -- the suffix does not turn it into a" \
    " different, unmonitored word"
assert matches('"token": "abcdef1234567890"'), \
    "a JSON-quoted key assigned a quoted literal must match -- the closing quote before the colon" \
    " must not hide the keyword from the rule"

print("PASS: audit-public-repo inline-secret-assignment fixtures")
