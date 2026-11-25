"""Shared by every module: configuration, errors, the Qumulo REST client, and the hub.

Configuration comes from environment variables set by bootstrap/. The hub's node IPs are
looked up at run time, by the hub's Qumulo-Cluster tag, so replacing the hub's nodes
doesn't leave the control plane with stale addresses.
"""

import json
import os
import re
import ssl
import urllib.error
import urllib.parse
import urllib.request

import boto3
from botocore.config import Config

API_PORT = 8000
PORTAL_PORT = 3713

HUB_NAME = os.environ.get("HUB_NAME", "")
HUB_REGION = os.environ.get("HUB_REGION", "")
HUB_VPC_ID = os.environ.get("HUB_VPC_ID", "")
HUB_VPC_CIDR = os.environ.get("HUB_VPC_CIDR", "")
HUB_SECRET_ARN = os.environ.get("HUB_SECRET_ARN", "")
STATE_BUCKET = os.environ.get("STATE_BUCKET", "")
DEFAULT_INSTANCE_TYPE = os.environ.get("DEFAULT_INSTANCE_TYPE", "")
DEFAULT_NODE_COUNT = int(os.environ.get("DEFAULT_NODE_COUNT", "3"))
PORTAL_TYPE = os.environ.get("PORTAL_TYPE", "PORTAL_READ_WRITE")
EXTRA_TAGS = json.loads(os.environ.get("EXTRA_TAGS") or "{}")

SUPPORTED_FAMILIES = ("m6idn", "m6i", "m7i", "i3en", "i4i", "i7i", "i7ie")

# For calls into regions other than the hub's (quota checks, capacity requests): a
# region that doesn't answer must not stall a whole round, so fail fast and move on.
FAST = Config(connect_timeout=5, read_timeout=15, retries={"max_attempts": 2, "mode": "standard"})


def regional(service, region):
    # Create these in the calling thread only: boto3 clients are safe to use from several
    # threads but not to create from them. One session shares the loaded service models;
    # a session per client loads them again each time (enough to exhaust the Lambda's
    # memory across ~30 regions).
    return boto3.client(service, region_name=region, config=FAST)


class WorkflowError(Exception):
    """A failure the operator should read: bad input or an unexpected cluster state."""


# -----------------------------------------------------------------------------
# Per invocation: the hub's identity and current node IPs
# -----------------------------------------------------------------------------

_invocation = {"hub_uuid": os.environ.get("HUB_CLUSTER_UUID", ""), "hub_ips": None}


def begin_invocation(event):
    """Called by the handler first. The hub's UUID is recorded by bootstrap after this
    function exists, so the workflows pass it in; the IPs are looked up afresh."""
    _invocation["hub_uuid"] = event.get("hub_uuid") or _invocation["hub_uuid"]
    _invocation["hub_ips"] = None


def hub_uuid():
    return _invocation["hub_uuid"]


def hub_ips():
    """The hub's running nodes' private IPs, found by their Qumulo-Cluster tag."""
    if _invocation["hub_ips"] is None:
        ec2 = boto3.client("ec2", region_name=HUB_REGION)
        ips = []
        pages = ec2.get_paginator("describe_instances").paginate(
            Filters=[
                {"Name": "tag:Qumulo-Cluster", "Values": [HUB_NAME]},
                {"Name": "instance-state-name", "Values": ["running"]},
                {"Name": "vpc-id", "Values": [HUB_VPC_ID]},
            ]
        )
        for page in pages:
            for r in page["Reservations"]:
                ips += [i["PrivateIpAddress"] for i in r["Instances"] if i.get("PrivateIpAddress")]
        if not ips:
            raise WorkflowError(
                f"No running hub nodes tagged Qumulo-Cluster = {HUB_NAME} in {HUB_VPC_ID} ({HUB_REGION}). "
                "Is the hub stopped?"
            )
        _invocation["hub_ips"] = sorted(ips)
    return _invocation["hub_ips"]


# -----------------------------------------------------------------------------
# Qumulo REST client
# -----------------------------------------------------------------------------

# CNQ clusters present self-signed certificates, so the REST API's certificate isn't
# verified. The calls go only to cluster nodes' private addresses, inside the hub VPC or
# across the hub-spoke VPC peering, never over the internet.
_SSL = ssl.create_default_context()
_SSL.check_hostname = False
_SSL.verify_mode = ssl.CERT_NONE

# A busy node can answer a read with one of these; another node (or a later retry) may not.
_TRANSIENT_HTTP = {502, 503, 504}


class Qumulo:
    def __init__(self, hosts, secret_arn=None, secret_region=None):
        self.hosts = list(hosts)
        self.secret_arn = secret_arn
        self.secret_region = secret_region
        self.token = None

    def _raw(self, method, host, path, body, token):
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(
            f"https://{host}:{API_PORT}{path}", data=data, method=method
        )
        req.add_header("Content-Type", "application/json")
        if token:
            req.add_header("Authorization", f"Bearer {token}")
        with urllib.request.urlopen(req, context=_SSL, timeout=20) as resp:
            text = resp.read().decode()
            return json.loads(text) if text else None

    def request(self, method, path, body=None, auth=True):
        """Try each host until one answers. HTTP errors raise WorkflowError, except a
        transient one on a GET, which moves on to the next host like a connection error
        (GETs are safe to repeat; other methods aren't retried, to avoid doing them twice).
        If no host answers, ConnectionError, which the workflows retry."""
        if auth and not self.token:
            self._login()
        last = None
        for host in self.hosts:
            try:
                return self._raw(method, host, path, body, self.token if auth else None)
            except urllib.error.HTTPError as e:
                if method == "GET" and e.code in _TRANSIENT_HTTP:
                    last = e
                    continue
                detail = e.read().decode(errors="replace")
                raise WorkflowError(f"{method} {path} on {host}: HTTP {e.code}: {detail}") from e
            except (urllib.error.URLError, TimeoutError, OSError) as e:
                last = e
        raise ConnectionError(f"No host answered {method} {path} ({self.hosts}): {last}")

    def _login(self):
        username, password = read_credentials(self.secret_arn, self.secret_region)
        resp = self.request(
            "POST", "/v1/session/login", {"username": username, "password": password}, auth=False
        )
        self.token = resp["bearer_token"]

    def version(self):
        rev = self.request("GET", "/v1/version", auth=False)["revision_id"]
        return rev.removeprefix("Qumulo Core ").strip()

    def cluster_id(self):
        return self.request("GET", "/v1/node/state")["cluster_id"]

    def attributes(self, path):
        ref = urllib.parse.quote(path, safe="")
        return self.request("GET", f"/v1/files/{ref}/info/attributes")

    def exists(self, path):
        try:
            self.attributes(path)
            return True
        except WorkflowError as e:
            if "HTTP 404" in str(e):
                return False
            raise

    def mkdir(self, parent, name):
        ref = urllib.parse.quote(parent, safe="")
        self.request(
            "POST", f"/v1/files/{ref}/entries/", {"name": name, "action": "CREATE_DIRECTORY"}
        )


def read_credentials(secret_arn, region=None):
    """Secret may be plain text (the password) or a JSON object with a password key and,
    optionally, a username key (default admin)."""
    sm = boto3.client("secretsmanager", region_name=region or _arn_region(secret_arn))
    raw = sm.get_secret_value(SecretId=secret_arn)["SecretString"]
    try:
        parsed = json.loads(raw)
    except ValueError:
        return "admin", raw
    if not isinstance(parsed, dict):
        return "admin", raw
    parsed = {str(k).lower(): v for k, v in parsed.items()}
    if "password" not in parsed:
        raise WorkflowError(
            f"Secret {secret_arn} is JSON without a password key; give the password as plain "
            'text or as {"password": "..."} (and optionally "username").'
        )
    return parsed.get("username", "admin"), parsed["password"]


def _arn_region(arn):
    return arn.split(":")[3]


def hub():
    return Qumulo(hub_ips(), HUB_SECRET_ARN, HUB_REGION)


def spoke(spoke_info):
    return Qumulo(spoke_info["primary_ips"], spoke_info["admin_secret_arn"])


def portal_hosts(ips):
    return [{"address": ip, "port": PORTAL_PORT} for ip in ips]


# -----------------------------------------------------------------------------
# Small helpers
# -----------------------------------------------------------------------------


def state_outputs(key):
    """Non-sensitive outputs of a Terraform state file; {} if it doesn't exist."""
    s3 = boto3.client("s3")
    try:
        obj = s3.get_object(Bucket=STATE_BUCKET, Key=key)
    except s3.exceptions.NoSuchKey:
        return {}
    outputs = json.loads(obj["Body"].read()).get("outputs", {})
    return {name: o["value"] for name, o in outputs.items() if not o.get("sensitive")}


def flag(value, name):
    """A true/false launch input, given as a JSON boolean or the string "true"/"false"."""
    if value in (None, ""):
        return False
    if isinstance(value, bool):
        return value
    if str(value).lower() in ("true", "false"):
        return str(value).lower() == "true"
    raise WorkflowError(f"{name} must be true or false, got {value!r}.")


def number_input(value, name, kind=int):
    """A numeric launch input (a JSON number or a numeric string), or a clear error."""
    if isinstance(value, bool):
        raise WorkflowError(f"{name} must be a number, got {value!r}.")
    try:
        return kind(value)
    except (TypeError, ValueError):
        raise WorkflowError(f"{name} must be a number, got {value!r}.") from None


def path_input(value):
    """The launch's path: a directory on the hub, as /a/b."""
    if not isinstance(value, str) or not value.strip():
        raise WorkflowError(f"path must be a directory on the hub, e.g. /my_data; got {value!r}.")
    return "/" + value.strip().strip("/")


# Option values end up in shell (user data, pipeline settings files), so this character
# list is what keeps them safe there: no spaces, quotes, $, backticks or ;.
OPTION_NAME = re.compile(r"[A-Za-z][A-Za-z0-9_]*")
OPTION_VALUE = re.compile(r"[A-Za-z0-9._:/@+=,-]*")


def options_input(value, name):
    """An object of name: value settings (application_options, pipeline_options), as strings."""
    options = value or {}
    if not isinstance(options, dict):
        raise WorkflowError(f"{name} must be an object of name: value pairs.")
    for key, v in options.items():
        if not OPTION_NAME.fullmatch(key) or not OPTION_VALUE.fullmatch(str(v)):
            raise WorkflowError(
                f"{name}: invalid name or value: {key}={v} (names: letters, digits, _; "
                "values: letters, digits and ._:/@+=,-)"
            )
    return {k: str(v) for k, v in options.items()}
