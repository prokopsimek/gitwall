#!/usr/bin/env python3
"""Minimal App Store Connect API client used by the release process (no third-party modules).

Environment: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH (the .p8 file, keep it outside the repository).

  Scripts/asc.py token
  Scripts/asc.py get  /v1/apps?filter[bundleId]=cz.prokopsimek.gitwall
  Scripts/asc.py post /v1/appStoreVersionLocalizations '{"data": {...}}'
  Scripts/asc.py patch /v1/appInfos/<id> '{"data": {...}}'
  Scripts/asc.py delete /v1/appScreenshots/<id>
  Scripts/asc.py upload-screenshots <appStoreVersionLocalizationId> APP_DESKTOP file.png [file.png ...]
  Scripts/asc.py upload-review-attachment <appStoreReviewDetailId> demo.mp4 [--replace]
"""

import base64
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

API = "https://api.appstoreconnect.apple.com"


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def der_to_raw(der: bytes, size: int = 32) -> bytes:
    """ECDSA DER SEQUENCE(INTEGER r, INTEGER s) -> fixed-size r||s as JWS requires."""
    assert der[0] == 0x30
    index = 2 if der[1] < 0x80 else 2 + (der[1] & 0x7F)
    parts = []
    for _ in range(2):
        assert der[index] == 0x02
        length = der[index + 1]
        value = der[index + 2:index + 2 + length].lstrip(b"\x00")
        parts.append(value.rjust(size, b"\x00"))
        index += 2 + length
    return b"".join(parts)


def token() -> str:
    key_id, issuer, key_path = (os.environ.get(name) for name in ("ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_KEY_PATH"))
    if not (key_id and issuer and key_path):
        sys.exit("set ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH")
    now = int(time.time())
    header = b64url(json.dumps({"alg": "ES256", "kid": key_id, "typ": "JWT"}, separators=(",", ":")).encode())
    payload = b64url(json.dumps({"iss": issuer, "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"}, separators=(",", ":")).encode())
    signing_input = f"{header}.{payload}".encode()
    with tempfile.NamedTemporaryFile() as message:
        message.write(signing_input)
        message.flush()
        der = subprocess.run(["openssl", "dgst", "-sha256", "-sign", key_path, message.name], check=True, capture_output=True).stdout
    return f"{header}.{payload}.{b64url(der_to_raw(der))}"


def request(method: str, path: str, body=None, raw: bytes | None = None, headers: dict | None = None):
    url = path if path.startswith("http") else API + path
    data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
    req = urllib.request.Request(url, data=data, method=method)
    if headers is None:
        req.add_header("Authorization", f"Bearer {token()}")
        if body is not None:
            req.add_header("Content-Type", "application/json")
    else:
        for name, value in headers.items():
            req.add_header(name, value)
    try:
        with urllib.request.urlopen(req) as response:
            text = response.read()
            return json.loads(text) if text else {}
    except urllib.error.HTTPError as error:
        detail = error.read().decode(errors="replace")
        sys.exit(f"{method} {url} -> {error.code}\n{detail}")


def checksum(path: str) -> str:
    digest = hashlib.md5()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def deliver(resource: str, created: dict, path: str) -> str:
    """Runs a reservation's upload operations, commits it and waits for the asset to be accepted.

    Shared by screenshots and review attachments: same three steps, same commit that occasionally does not take
    on the first try and leaves the asset in UPLOAD_COMPLETE, which blocks submission.
    """
    with open(path, "rb") as handle:
        for operation in created["attributes"]["uploadOperations"]:
            handle.seek(operation["offset"])
            headers = {h["name"]: h["value"] for h in operation["requestHeaders"]}
            request(operation["method"], operation["url"], raw=handle.read(operation["length"]), headers=headers)
    digest = checksum(path)
    state = "UPLOAD_COMPLETE"
    for attempt in range(40):
        if attempt % 5 == 0:
            request("PATCH", f"/v1/{resource}/{created['id']}", {"data": {
                "type": resource, "id": created["id"],
                "attributes": {"uploaded": True, "sourceFileChecksum": digest},
            }})
        time.sleep(3)
        state = request("GET", f"/v1/{resource}/{created['id']}")["data"]["attributes"]["assetDeliveryState"]["state"]
        if state == "COMPLETE":
            return state
        if state == "FAILED":
            sys.exit(f"{path}: asset delivery failed")
    sys.exit(f"{path}: still {state} after waiting; commit it again with PATCH uploaded=true")


def upload_review_attachment(detail_id: str, path: str, replace: bool = False):
    """The demo recording App Review asks for under guideline 2.1(a), on App Review Information."""
    existing = request("GET", f"/v1/appStoreReviewDetails/{detail_id}/appStoreReviewAttachments")["data"]
    for attachment in existing:
        name = attachment["attributes"].get("fileName")
        if replace:
            request("DELETE", f"/v1/appStoreReviewAttachments/{attachment['id']}")
            print(f"removed\t{name}\t{attachment['id']}")
        else:
            print(f"kept\t{name}\t{attachment['id']}\t(pass --replace to remove)")
    created = request("POST", "/v1/appStoreReviewAttachments", {"data": {
        "type": "appStoreReviewAttachments",
        "attributes": {"fileName": os.path.basename(path), "fileSize": os.path.getsize(path)},
        "relationships": {"appStoreReviewDetail": {"data": {"type": "appStoreReviewDetails", "id": detail_id}}},
    }})["data"]
    state = deliver("appStoreReviewAttachments", created, path)
    print(f"{os.path.basename(path)}\t{created['id']}\t{state}")


def upload_screenshots(localization_id: str, display_type: str, files: list[str]):
    sets = request("GET", f"/v1/appStoreVersionLocalizations/{localization_id}/appScreenshotSets")["data"]
    existing = next((s for s in sets if s["attributes"]["screenshotDisplayType"] == display_type), None)
    if existing is None:
        existing = request("POST", "/v1/appScreenshotSets", {"data": {
            "type": "appScreenshotSets",
            "attributes": {"screenshotDisplayType": display_type},
            "relationships": {"appStoreVersionLocalization": {"data": {"type": "appStoreVersionLocalizations", "id": localization_id}}},
        }})["data"]
    set_id = existing["id"]
    for path in files:
        created = request("POST", "/v1/appScreenshots", {"data": {
            "type": "appScreenshots",
            "attributes": {"fileName": os.path.basename(path), "fileSize": os.path.getsize(path)},
            "relationships": {"appScreenshotSet": {"data": {"type": "appScreenshotSets", "id": set_id}}},
        }})["data"]
        state = deliver("appScreenshots", created, path)
        print(f"{os.path.basename(path)}\t{created['id']}\t{state}")
    print(f"set\t{set_id}")


def main(argv: list[str]):
    if len(argv) < 2:
        sys.exit(__doc__)
    command = argv[1]
    if command == "token":
        print(token())
    elif command in ("get", "delete"):
        print(json.dumps(request(command.upper(), argv[2]), indent=2))
    elif command in ("post", "patch"):
        print(json.dumps(request(command.upper(), argv[2], json.loads(argv[3])), indent=2))
    elif command == "upload-screenshots":
        upload_screenshots(argv[2], argv[3], argv[4:])
    elif command == "upload-review-attachment":
        upload_review_attachment(argv[2], argv[3], "--replace" in argv[4:])
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv)
