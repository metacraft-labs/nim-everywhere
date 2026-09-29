## RS256 signature verification — RSASSA-PKCS1-v1_5 over SHA-256, against a
## key published as a JWKS `n`/`e` pair.
##
## ## Why this is in nim-everywhere and not in the two products that need it
##
## Both `codetracer` and `isonim-platform` federate to the same OpenID Connect
## issuer, and both therefore have to check an RS256 ID token. When this module
## was written they each had their own answer, and one of them had already
## written the DER encoder below by hand. Two hand-written ASN.1 encoders for
## the same structure in two repositories is the shape of a defect that gets
## fixed once.
##
## It belongs *here* specifically because the thing that differs between them
## is the backend, which is what this library is for: the same call has to mean
## something on native Nim and something else under `nim js`. That is the seam,
## and a seam is not product-specific.
##
## ## This is the NATIVE half, and the JS half is deliberately absent
##
## A browser already has RSASSA-PKCS1-v1_5, in `crypto.subtle`, and
## `crypto.subtle.verify` returns a promise. There is no synchronous WebCrypto,
## so a synchronous seam cannot express it — and widening this one to be
## asynchronous everywhere would force a native caller, which needs no
## asynchrony at all, to acquire an event loop to check a signature.
##
## So on the JS backend `verifyRs256` answers `rs256Unavailable`, and a JS
## caller is expected to reach for `crypto.subtle` with its own async plumbing.
## That is not a stub standing in for missing work: it is the correct answer,
## and it is the same answer this module gives a native host with no libcrypto.
##
## ## Three verdicts, because "cannot check" is not "invalid"
##
## A verifier that cannot run must never mean "accept" — and it must not mean
## "reject" either. Collapsing `rs256Unavailable` into `rs256Rejected` makes a
## host with no libcrypto look exactly like a user presenting forged tokens,
## which sends whoever is debugging it to the wrong place entirely. Every
## caller has to be able to tell a configuration problem from an authentication
## one.
##
## ## libcrypto is loaded, not linked
##
## `std/openssl` binds its entry points with `{.dynlib.}`, which resolves at
## module-init time and aborts the process when the library is absent. That is
## the wrong failure for this: a missing libcrypto is exactly the case
## `rs256Unavailable` exists to report, and a caller cannot report what has
## already killed it. `licensing_ffi.nim` in `codetracer-native-recorder` makes
## the same choice for the same reason, and states it: the pragma "generates
## module-init `dlopen` before user code runs".
##
## So the library is opened with `std/dynlib` on first use and each symbol is
## bound by name. Absence, and a libcrypto too old to export one of them, both
## arrive as `rs256Unavailable`.
##
## ## The key is rebuilt as a DER SubjectPublicKeyInfo
##
## `d2i_PUBKEY` takes SPKI and needs nothing else. The alternative — `RSA_new`
## plus `RSA_set0_key` — is deprecated in OpenSSL 3 and only present while a
## distribution keeps the deprecated symbols exported, so a build against a
## stricter libcrypto would fail to bind them.

import std/[base64, strutils]

type
  Rs256Verdict* = enum
    ## Deliberately not a `bool`. See the header: the third state is the whole
    ## point, and an enum makes a caller that ignores it fail to compile rather
    ## than silently treat it as one of the other two.
    rs256Valid
    rs256Rejected
    rs256Unavailable

proc decodeB64Url*(s: string): string =
  ## base64url with padding restored, raising `ValueError` on anything else.
  ## JWKS publishes `n` and `e` this way (RFC 7518 §6.3.1), and a decoder that
  ## also accepted standard base64 would accept keys the issuer never
  ## published.
  for c in s:
    if c in {'+', '/', '='}:
      raise newException(ValueError,
        "the value uses standard base64 ('" & c & "'), not base64url")
  var t = s.replace('-', '+').replace('_', '/')
  case t.len mod 4
  of 2: t.add("==")
  of 3: t.add("=")
  of 0: discard
  else: raise newException(ValueError, "not a valid base64url length")
  decode(t)

# ---------------------------------------------------------------------------
# DER. Small enough to read in one sitting, which is the reason it is written
# out rather than pulled in.
# ---------------------------------------------------------------------------
proc derLen(n: int): string =
  if n < 0x80:
    result = $char(n)
  else:
    var body = ""
    var v = n
    while v > 0:
      body = $char(v and 0xff) & body
      v = v shr 8
    result = $char(0x80 or body.len) & body

proc derTlv(tag: int; body: string): string =
  $char(tag) & derLen(body.len) & body

proc derInteger(magnitude: string): string =
  ## DER INTEGERs are signed two's complement, so an unsigned magnitude whose
  ## top bit is set needs a leading zero byte or it decodes as NEGATIVE — which
  ## for a 2048-bit modulus happens about half the time, so this is the normal
  ## case and not an edge one. Leading zeros are also stripped, because DER
  ## requires the minimal encoding and a JWKS value sometimes carries one.
  var m = magnitude
  var i = 0
  while i < m.len - 1 and m[i] == '\0': inc i
  m = m[i .. ^1]
  if m.len == 0: m = "\0"
  if (m[0].uint8 and 0x80'u8) != 0: m = "\0" & m
  derTlv(0x02, m)

const RsaEncryptionOid = "\x06\x09\x2a\x86\x48\x86\xf7\x0d\x01\x01\x01"

proc rsaSpkiDer*(modulus, exponent: string): string =
  ## SEQUENCE { SEQUENCE { OID rsaEncryption, NULL },
  ##            BIT STRING { SEQUENCE { INTEGER n, INTEGER e } } }
  ## with raw magnitudes in, not base64url.
  let algId = derTlv(0x30, RsaEncryptionOid & "\x05\x00")
  let pubKey = derTlv(0x30, derInteger(modulus) & derInteger(exponent))
  # A BIT STRING's content is prefixed by its count of unused trailing bits.
  let bitString = derTlv(0x03, "\0" & pubKey)
  derTlv(0x30, algId & bitString)

when defined(js):
  proc verifyRs256*(signingInput, signature, modulusB64Url,
                    exponentB64Url: string): Rs256Verdict =
    ## Always `rs256Unavailable` on this backend. See the header: the browser's
    ## RSASSA-PKCS1-v1_5 is asynchronous and cannot be reached through a
    ## synchronous seam, so a JS caller uses `crypto.subtle` directly.
    rs256Unavailable

  proc rs256IsAvailable*(): bool = false

else:
  import std/dynlib

  const cryptoLibOverride* {.strdefine: "nimEverywhereCryptoLib".} = ""
    ## An explicit library to try FIRST, for a product that knows where its
    ## libcrypto is — a macOS app bundle, say, which ships one under
    ## `@executable_path/../Frameworks/`. A compile-time define rather than an
    ## environment variable on purpose: a runtime knob that chooses which
    ## library verifies signatures is one edit away from choosing one that
    ## does not.

  const CryptoLibNames =
    when defined(windows):
      ["libcrypto-3-x64.dll", "libcrypto-3.dll", "libcrypto-1_1-x64.dll",
       "libcrypto-1_1.dll"]
    elif defined(macosx):
      # NO BARE `libcrypto.dylib` HERE, AND THIS IS NOT TIDINESS. On macOS that
      # name resolves to Apple's own LibreSSL in `/usr/lib`, which the OS
      # refuses to let a third-party binary load — and it refuses by printing
      # "loading libcrypto in an unsafe way" and KILLING THE PROCESS. It cannot
      # be probed and recovered from, so a candidate list containing it turns
      # "this host has no libcrypto" from a verdict into a crash.
      #
      # Measured: nim-everywhere PR #10's `test (self-hosted, macos, arm64)`
      # aborted inside `loadLib` with exactly that warning. The versioned names
      # are safe because Apple's is `libcrypto.NN.dylib` with a LibreSSL
      # number, so they cannot match it.
      ["libcrypto.3.dylib", "libcrypto.1.1.dylib"]
    else:
      # `libcrypto.so` is the development symlink and is absent on a host with
      # only the runtime package, so the versioned names come first and it is
      # the fallback rather than the first guess.
      ["libcrypto.so.3", "libcrypto.so.1.1", "libcrypto.so"]

  type
    EvpPkey = pointer
    EvpMdCtx = pointer
    EvpMd = pointer

    D2iPubkeyProc = proc (a: ptr EvpPkey; pp: ptr ptr uint8;
                          length: clong): EvpPkey {.cdecl.}
    PkeyFreeProc = proc (k: EvpPkey) {.cdecl.}
    MdCtxNewProc = proc (): EvpMdCtx {.cdecl.}
    MdCtxFreeProc = proc (c: EvpMdCtx) {.cdecl.}
    Sha256Proc = proc (): EvpMd {.cdecl.}
    VerifyInitProc = proc (ctx: EvpMdCtx; pctx: pointer; typ: EvpMd;
                           e: pointer; pkey: EvpPkey): cint {.cdecl.}
    DigestUpdateProc = proc (ctx: EvpMdCtx; data: pointer;
                             len: csize_t): cint {.cdecl.}
    VerifyFinalProc = proc (ctx: EvpMdCtx; sig: pointer;
                            siglen: csize_t): cint {.cdecl.}

  var
    libTried = false
    lib: LibHandle
    d2iPubkey: D2iPubkeyProc
    pkeyFree: PkeyFreeProc
    mdCtxNew: MdCtxNewProc
    mdCtxFree: MdCtxFreeProc
    sha256: Sha256Proc
    verifyInit: VerifyInitProc
    digestUpdate: DigestUpdateProc
    verifyFinal: VerifyFinalProc

  proc bindAll(): bool =
    ## Every symbol or none. A partial binding is worse than no binding: it
    ## would pass the availability check and then call through a nil pointer.
    template need(dest, T, name: untyped): untyped =
      dest = cast[T](lib.symAddr(name))
      if dest == nil: return false

    need(d2iPubkey, D2iPubkeyProc, "d2i_PUBKEY")
    need(pkeyFree, PkeyFreeProc, "EVP_PKEY_free")
    # `EVP_MD_CTX_create` is a compatibility MACRO in OpenSSL 1.1+, not an
    # exported symbol, so binding it by name fails on a modern libcrypto even
    # though C code calling it compiles. `EVP_MD_CTX_new` is the symbol.
    need(mdCtxNew, MdCtxNewProc, "EVP_MD_CTX_new")
    need(mdCtxFree, MdCtxFreeProc, "EVP_MD_CTX_free")
    need(sha256, Sha256Proc, "EVP_sha256")
    need(verifyInit, VerifyInitProc, "EVP_DigestVerifyInit")
    need(digestUpdate, DigestUpdateProc, "EVP_DigestUpdate")
    need(verifyFinal, VerifyFinalProc, "EVP_DigestVerifyFinal")
    true

  proc loadCrypto(): bool =
    if libTried:
      return lib != nil and d2iPubkey != nil
    libTried = true
    var candidates: seq[string] = @[]
    if cryptoLibOverride.len > 0:
      candidates.add(cryptoLibOverride)
    for n in CryptoLibNames:
      candidates.add(n)
    for name in candidates:
      lib = loadLib(name)
      if lib != nil:
        if bindAll():
          return true
        # Bound some but not all: this libcrypto cannot serve us. Keep looking
        # rather than settling for it.
        unloadLib(lib)
        lib = nil
    false

  proc rs256IsAvailable*(): bool =
    ## Whether a verification could run at all. A caller should ask before
    ## reporting a token as invalid, so that "your session is not valid" is
    ## never shown for "this build cannot check signatures".
    loadCrypto()

  proc verifyRs256*(signingInput, signature, modulusB64Url,
                    exponentB64Url: string): Rs256Verdict =
    ## `signingInput` and `signature` are RAW bytes — the JWS signing input as
    ## received and the decoded signature. The key halves are base64url, as the
    ## JWKS publishes them.
    if not loadCrypto():
      return rs256Unavailable
    if signature.len == 0 or modulusB64Url.len == 0 or exponentB64Url.len == 0:
      # Not `rs256Unavailable`: nothing about the host is wrong. An empty
      # signature or an empty key half is a refusal, and the reason it is
      # spelled out here is that OpenSSL will happily accept a zero-length
      # modulus and then fail to verify, which would report the same verdict
      # for a much less obvious reason.
      return rs256Rejected

    var der: string
    try:
      der = rsaSpkiDer(decodeB64Url(modulusB64Url), decodeB64Url(exponentB64Url))
    except ValueError:
      return rs256Rejected

    var derCopy = der
    var p = cast[ptr uint8](addr derCopy[0])
    let pkey = d2iPubkey(nil, addr p, clong(derCopy.len))
    if pkey == nil:
      # The bytes are not a well-formed RSA public key. That is the issuer's
      # key being unusable, not this host being unable to verify.
      return rs256Rejected
    defer: pkeyFree(pkey)

    let ctx = mdCtxNew()
    if ctx == nil:
      return rs256Unavailable
    defer: mdCtxFree(ctx)

    if verifyInit(ctx, nil, sha256(), nil, pkey) != 1:
      return rs256Unavailable
    if signingInput.len > 0:
      if digestUpdate(ctx, unsafeAddr signingInput[0],
                      csize_t(signingInput.len)) != 1:
        return rs256Unavailable

    # ONLY 1 IS A PASS. `EVP_DigestVerifyFinal` returns 0 for a bad signature
    # and a negative value for an internal error, and a verifier that treats an
    # internal error as success is worse than no verifier at all.
    if verifyFinal(ctx, unsafeAddr signature[0],
                   csize_t(signature.len)) == 1:
      rs256Valid
    else:
      rs256Rejected
