from std.os import getenv
from webpush import encrypt, authorization
from crypto import base64, json_string


def main() raises:
    var data = encrypt(
        getenv("TEST_PEER", ""), getenv("TEST_AUTH", ""), "Campfire push ✓"
    )
    print(
        '{"encrypted":'
        + json_string(base64(data))
        + ',"authorization":'
        + json_string(authorization("https://push.example.test", 1700000000))
        + "}"
    )
