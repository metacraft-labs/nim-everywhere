## RS256 verification, against a vector produced by a DIFFERENT implementation.
##
## ## Why the vector is not generated here
##
## A test that signs and then verifies with the same library proves the library
## agrees with itself, which is true of a library that is wrong. The vector
## below was produced by **Node 24's `crypto.subtle`** — BoringSSL, through
## V8's WebCrypto — and is verified here by **libcrypto**, loaded at runtime.
## Two independent implementations of RSASSA-PKCS1-v1_5 and SHA-256 agreeing on
## the same 256 bytes is the property worth asserting.
##
## Provenance, so it can be regenerated rather than trusted:
##
##     node -e 'const s = globalThis.crypto.subtle; (async () => {
##       const p = await s.generateKey({name:"RSASSA-PKCS1-v1_5",
##         modulusLength:2048, publicExponent:new Uint8Array([1,0,1]),
##         hash:"SHA-256"}, true, ["sign","verify"]);
##       const jwk = await s.exportKey("jwk", p.publicKey);
##       const sig = new Uint8Array(await s.sign({name:"RSASSA-PKCS1-v1_5"},
##         p.privateKey, new TextEncoder().encode(MESSAGE)));
##       ... })()'
##
## The key is a throwaway generated for this file and its private half was
## never written down, which is the only property a committed test key needs.
##
## ## Both backends, and they assert different things
##
## The DER and base64url cases are backend-independent and run everywhere. The
## verification cases cannot be: on the JS backend `verifyRs256` answers
## `rs256Unavailable` by design, because the browser's RSASSA-PKCS1-v1_5 is
## asynchronous and a synchronous seam cannot reach it. So the JS lane asserts
## exactly that — and asserts it as a POSITIVE claim about the contract rather
## than skipping, because a suite that quietly runs three cases on one backend
## and thirteen on the other is how a backend stops being tested.
##
## ## The positive control is the first case, deliberately
##
## Every "does not verify" assertion below is satisfied by a verifier that
## refuses everything — including a broken one, including one whose libcrypto
## did not load. So the suite asserts a genuine signature VERIFIES first, and
## `rs256IsAvailable()` separately, and neither the flipped-bit cases nor the
## malformed-key cases mean anything without them.

import std/[unittest, strutils]
import ../src/nim_everywhere/rs256

const
  KatModulus = "pepoGt0bV51rzT4VQlWbyNltDXScSy-xor3hzuDW9Ld8vDM0SOh48DUzT-ULPaQqsLBh-r8PAiEVAO8PuX2km__NmdNQbtJfSIwZQlinyUY_BU4YpA-PB3e0I7-HREkc6NOTix9zz12ZuNfoYBwhu8pksGJdgUb0ckbsd0Kru7lKxZtPJytNAjTi0gzwDDdHO0yL8tpmlcDFK01DZ6MW0xJHhtNjflY7hQUxHD0c1rQNs9cunPRLGW1JbXgtv0uJuH6Xx0gyufNDOnfrJH7qqWhZpHflv102WC96yf5Z9dzJhtcP7hY3hBrloVQJC5q6pKmKwCdvTUYP1Sei2o2G6w"
  KatExponent = "AQAB"
  KatSignature = "Z4JC4zgH6CqJVhBn7iAwoxanUSoHdjGpzmzH2ZhXii7SUqBLkKRHM1On3M9-fp_dL9OZ-yIxX-pYdwz83Yg4BneoOHAl2dAGbnsgi-SGi3zWwBMJA79BOocX2ZbWqqczwC7wAAYqRXPah-lEhyJU9I5Q4FMKl7lW8jrMkAioWfmf1i6BBWG_kwgPUm5JF2BPlZnxziDnrQWAA2QQTRYW-FWzRp4LS1x2CtGfu1yb9z7-mkaGU3Nc9n6fRbr_meRyVIGPWfzG8Gr97sY4jgWs8RRw4oybhWJ9qj25IzO7jWflvTSYga3QAbxEg6-qyjTsyowRlr1QkAl04z8EeHJ0Ug"
  # A real JWS signing input: `base64url(header).base64url(payload)`.
  KatSigningInput = "eyJhbGciOiJSUzI1NiIsImtpZCI6Im52LTEifQ.eyJpc3MiOiJodHRwczovL2xvZ2luLm1ldGFjcmFmdC1sYWJzLmNvbSIsInN1YiI6Im52LWthdCJ9"

proc katSignature(): string = decodeB64Url(KatSignature)

proc verify(input, sig: string): Rs256Verdict =
  verifyRs256(input, sig, KatModulus, KatExponent)

suite "rs256 encoding":

  test "base64url decodes, and refuses standard base64":
    check decodeB64Url("AQAB") == "\x01\x00\x01"
    check decodeB64Url("") == ""
    # `-_` against `+/`. A decoder that takes both takes keys the issuer never
    # published, so the refusal is the assertion.
    expect ValueError: discard decodeB64Url("ab+d")
    expect ValueError: discard decodeB64Url("ab/d")
    expect ValueError: discard decodeB64Url("abcd=")

  test "a DER INTEGER whose magnitude has its top bit set gains a leading zero":
    # Not decoration: a 2048-bit modulus has its top bit set about half the
    # time, and without this byte libcrypto reads it as a negative number and
    # `d2i_PUBKEY` refuses the key. The encoding is checked directly so that a
    # regression here is not diagnosed as "signatures stopped verifying".
    let der = rsaSpkiDer("\x80\x01", "\x01\x00\x01")
    check der[0] == '\x30'                  # outer SEQUENCE
    check der.contains("\x02\x03\x00\x80\x01")   # INTEGER, 3 bytes, zero-padded
    # ...and a magnitude whose top bit is clear does NOT gain one.
    let plain = rsaSpkiDer("\x7f\x01", "\x01\x00\x01")
    check plain.contains("\x02\x02\x7f\x01")
    check not plain.contains("\x02\x03\x00\x7f\x01")

  test "a leading zero byte in the published magnitude is stripped":
    # DER requires the minimal encoding and a JWKS value sometimes carries a
    # leading zero; re-emitting it produces a non-minimal INTEGER.
    check rsaSpkiDer("\x00\x7f", "\x01") == rsaSpkiDer("\x7f", "\x01")

when defined(js):
  suite "rs256 on the JS backend":

    test "verification is unavailable, and says so rather than refusing":
      # Not `rs256Rejected`. A browser CAN verify RS256 — through
      # `crypto.subtle`, asynchronously — so answering "invalid" here would
      # tell a caller its token is bad when the truth is that it asked the
      # wrong seam.
      check not rs256IsAvailable()
      check verify(KatSigningInput, katSignature()) == rs256Unavailable

else:
 const AvailabilityIsRequired = defined(linux)
   ## WHERE ABSENCE IS A BUG AND WHERE IT IS A FACT.
   ##
   ## On Linux every host that runs this — the platform servers, CI, a
   ## developer's shell — has libcrypto, so not finding one is a defect in the
   ## candidate list and the suite says so.
   ##
   ## On macOS and Windows it depends on a VERSIONED libcrypto being
   ## discoverable, and this library cannot guarantee that for a host it did
   ## not build. Apple's own `/usr/lib/libcrypto.dylib` is not an option: the
   ## OS kills a third-party process that loads it. So what is asserted there
   ## is the contract instead — it either verifies correctly, or reports itself
   ## unavailable, and it NEVER accepts. A product that needs verification on
   ## those platforms supplies `-d:nimEverywhereCryptoLib=<path>`.
   ##
   ## This is deliberately not a skip. Every case below runs on every platform
   ## and every one of them can fail; what varies is which verdict is correct,
   ## not whether the case executes.

 suite "rs256 verification":

  test "libcrypto is discoverable where this library requires it":
    # SAID OUT LOUD, because on a platform where availability is not required
    # both branches below print `[OK]` and the transcript would not say which
    # world the run was in. A macOS lane that quietly took the "unavailable"
    # path would look exactly like one that verified a real signature.
    echo "    libcrypto available on this host: ", rs256IsAvailable()
    when AvailabilityIsRequired:
      check rs256IsAvailable()
    else:
      # The weaker claim, and still falsifiable: whichever way it goes, the
      # KAT must agree with it. An "unavailable" host that answered `rs256Valid`
      # would fail here, and so would an available one that could not verify a
      # signature two other implementations agree on.
      if rs256IsAvailable():
        check verify(KatSigningInput, katSignature()) == rs256Valid
      else:
        check verify(KatSigningInput, katSignature()) == rs256Unavailable

  test "a signature produced by Node's WebCrypto verifies under libcrypto":
    # THE POSITIVE CONTROL. Two independent implementations agreeing.
    if rs256IsAvailable():
      check verify(KatSigningInput, katSignature()) == rs256Valid

  test "a one-bit-flipped signature does not verify":
    var sig = katSignature()
    sig[0] = char(uint8(sig[0]) xor 1'u8)
    # NEVER `rs256Valid` — true on a host with no libcrypto too, which is the
    # half that has to hold everywhere.
    check verify(KatSigningInput, sig) != rs256Valid
    if rs256IsAvailable():
      check verify(KatSigningInput, sig) == rs256Rejected

  test "a one-bit-flipped signing input does not verify":
    var input = KatSigningInput
    input[10] = char(uint8(input[10]) xor 1'u8)
    check verify(input, katSignature()) != rs256Valid
    if rs256IsAvailable():
      check verify(input, katSignature()) == rs256Rejected

  test "a signature one byte short does not verify":
    let sig = katSignature()
    check verify(KatSigningInput, sig[0 ..< sig.len - 1]) != rs256Valid
    if rs256IsAvailable():
      check verify(KatSigningInput, sig[0 ..< sig.len - 1]) == rs256Rejected

  test "the right signature under a different modulus does not verify":
    # The modulus with two characters transposed is still a well-formed RSA
    # key, so this reaches the arithmetic rather than being refused by the
    # parser — which is the case a key-selection bug produces.
    var other = KatModulus
    swap(other[5], other[6])
    check verifyRs256(KatSigningInput, katSignature(), other,
                      KatExponent) != rs256Valid
    if rs256IsAvailable():
      check verifyRs256(KatSigningInput, katSignature(), other,
                        KatExponent) == rs256Rejected

  test "an empty signature or an empty key half is refused, not reported unavailable":
    # `rs256Unavailable` means the HOST cannot check. None of these is about
    # the host, and reporting them that way would send whoever is debugging it
    # to look for a missing libcrypto. Only asserted where a host CAN check —
    # on one that cannot, `rs256Unavailable` is the honest answer to everything.
    if rs256IsAvailable():
      check verify(KatSigningInput, "") == rs256Rejected
      check verifyRs256(KatSigningInput, katSignature(), "",
                        KatExponent) == rs256Rejected
      check verifyRs256(KatSigningInput, katSignature(), KatModulus,
                        "") == rs256Rejected

  test "a modulus that is not base64url is refused, not reported unavailable":
    check verifyRs256(KatSigningInput, katSignature(), "!!!not-base64url!!!",
                      KatExponent) != rs256Valid
    if rs256IsAvailable():
      check verifyRs256(KatSigningInput, katSignature(), "!!!not-base64url!!!",
                        KatExponent) == rs256Rejected

  test "a modulus that is well-formed base64url but not an RSA key is refused":
    check verifyRs256(KatSigningInput, katSignature(), "AQAB",
                      KatExponent) != rs256Valid
    if rs256IsAvailable():
      check verifyRs256(KatSigningInput, katSignature(), "AQAB",
                        KatExponent) == rs256Rejected

  test "an empty signing input is still a real verification":
    # Not a crash, and not a pass: the signature covers the KAT's bytes, so a
    # verification over no bytes at all must fail. The case exists because the
    # zero-length branch skips `EVP_DigestUpdate` entirely, and a skip that
    # returned `rs256Valid` would accept every token whose signing input a bug
    # had emptied.
    check verify("", katSignature()) != rs256Valid
    if rs256IsAvailable():
      check verify("", katSignature()) == rs256Rejected
