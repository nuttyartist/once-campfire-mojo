# Independent RFC 8291 section 5 vector, also used by the Rust reference tests.
import native_boundary as native
from byte_buffer import Bytes
from crypto import base64, unbase64
from webpush import encrypt_with


def main() raises:
    var private = unbase64("yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw")
    var public = List[UInt8](length=65, fill=0)
    if native.p256_public(private.as_bytes(), public) != 0:
        raise Error("Public key derivation failed")
    var result = encrypt_with(
        private,
        Bytes(public^),
        unbase64(
            "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4"
        ),
        unbase64("BTBZMqHH6r4Tts7J_aSIgg"),
        unbase64("DGv6ra1nlYgDCS1FRnbzlw"),
        unbase64(
            "V2hlbiBJIGdyb3cgdXAsIEkgd2FudCB0byBiZSBhIHdhdGVybWVsb24"
        ).text(),
    )
    var expected = "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPTpK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN"
    if base64(result, True, False) != expected:
        raise Error("RFC 8291 ciphertext mismatch")
    print("PASS: RFC 8291 byte-for-byte encrypted payload vector")
