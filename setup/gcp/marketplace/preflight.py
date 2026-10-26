#!/usr/bin/env python3
"""Fundamental Platform - GCP prerequisite check.

Run this before you deploy. It is read-only: it creates nothing and changes
nothing in your project. It uses the permissions of the account gcloud is
signed in with. Checks your account is not allowed to make are marked SKIP,
not FAIL, and listed at the end so you can verify them another way.

It needs python3 (3.8 or newer) and a signed-in gcloud, and no third-party
Python packages. Every other tool it looks for is reported, not required.

The deployment runs as a deployer service account. From the "Deployer service
account" check on, every gcloud call impersonates it, so the results describe
the identity that will deploy.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import urllib.error
import urllib.request

# gcloud must never prompt: on a disabled API it offers to enable it, and this
# script changes nothing.
os.environ["CLOUDSDK_CORE_DISABLE_PROMPTS"] = "1"

TF_MIN_VERSION = "1.9.0"  # terraform/versions.tf required_version

# Derived from the resource types in the Terraform module. The deployment
# itself enables container, dns and parametermanager; the rest must be on.
APIS_REQUIRED = [
    "compute.googleapis.com",
    "cloudkms.googleapis.com",
    "secretmanager.googleapis.com",
    "artifactregistry.googleapis.com",
    "iam.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "storage.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "serviceusage.googleapis.com",
]
APIS_SELF_ENABLED = [
    "container.googleapis.com",
    "dns.googleapis.com",
    "parametermanager.googleapis.com",
]

# One permission per resource family the module creates, checked the way IAM
# evaluates them for your account (groups and inherited roles included).
PERMS = [
    "compute.networks.create",
    "compute.subnetworks.create",
    "compute.firewalls.create",
    "compute.instanceTemplates.create",
    "compute.instanceGroupManagers.create",
    "compute.addresses.create",
    "compute.forwardingRules.create",
    "compute.regionBackendServices.create",
    "compute.healthChecks.create",
    "compute.projects.setCommonInstanceMetadata",
    "compute.serviceAttachments.create",
    "container.clusters.create",
    "container.clusters.get",
    "cloudkms.keyRings.create",
    "cloudkms.cryptoKeys.create",
    "cloudkms.cryptoKeys.setIamPolicy",
    "secretmanager.secrets.create",
    "secretmanager.secrets.setIamPolicy",
    "parametermanager.parameters.create",
    "artifactregistry.repositories.create",
    "artifactregistry.repositories.uploadArtifacts",
    "dns.managedZones.create",
    "dns.changes.create",
    "iam.serviceAccounts.create",
    "iam.serviceAccounts.setIamPolicy",
    "resourcemanager.projects.setIamPolicy",
    "resourcemanager.projects.get",
    "storage.buckets.create",
    "serviceusage.services.enable",
]

# This script does not check compute capacity (machine types, the zones that
# offer them, vCPU and GPU quota). The note below sends people to the
# documentation page that covers it. Placeholder: replace it with the final wording.
COMPUTE_CAPACITY_NOTE = (
    "PLACEHOLDER: this script does not check machine types, zones or quota. "
    "See the compute capacity page in the documentation: <url>"
)

PERM_RE = re.compile(
    r"PERMISSION_DENIED|permission denied|does not have permission|"
    r"does not have [a-z.]+ access|Permission .* denied|Required .* permission|"
    r"caller does not have|\(403\)|HTTPError 403|status code 403|Forbidden|"
    r"ACCESS_TOKEN_SCOPE_INSUFFICIENT",
    re.IGNORECASE,
)

LINK_PREFIX = "https://www.googleapis.com/compute/v1/"


# ---------------------------------------------------------------- output
class Report:
    """Counts results and prints them in the PASS/FAIL/WARN/SKIP/INFO format."""

    def __init__(self) -> None:
        colour = sys.stdout.isatty() and not os.environ.get("NO_COLOR")
        self.c_pass = "\033[32m" if colour else ""
        self.c_fail = "\033[31m" if colour else ""
        self.c_warn = "\033[33m" if colour else ""
        self.c_skip = "\033[36m" if colour else ""
        self.dim = "\033[2m" if colour else ""
        self.bold = "\033[1m" if colour else ""
        self.off = "\033[0m" if colour else ""
        self.n_pass = self.n_fail = self.n_warn = self.n_skip = 0
        self.skipped: list = []

    def section(self, title: str) -> None:
        print(f"\n{self.bold}{title}{self.off}")

    def _hint(self, text: str, command: str = "") -> None:
        if text:
            print(f"         {self.dim}{text}{self.off}")
        if command:
            print(f"           {command}")

    def ok(self, msg: str) -> None:
        self.n_pass += 1
        print(f"  {self.c_pass}[PASS]{self.off} {msg}")

    def fail(self, msg: str, hint: str = "", command: str = "") -> None:
        """command: a remedy to copy as is. It goes on its own line, nothing else on it."""
        self.n_fail += 1
        print(f"  {self.c_fail}[FAIL]{self.off} {msg}")
        self._hint(hint, command)

    def warn(self, msg: str, hint: str = "", command: str = "") -> None:
        self.n_warn += 1
        print(f"  {self.c_warn}[WARN]{self.off} {msg}")
        self._hint(hint, command)

    def info(self, msg: str) -> None:
        print(f"  {self.dim}[INFO]{self.off} {msg}")

    def skip(self, what: str, needs: str) -> None:
        """what: the check that did not run. needs: the permission your account lacks."""
        self.n_skip += 1
        print(f"  {self.c_skip}[SKIP]{self.off} {what}")
        self._hint(f"Not checked: your account lacks permission. Needs: {needs}")
        self.skipped.append(f"  - {what} (needs: {needs})")

    def stop(self, msg: str) -> None:
        print(f"  {self.c_fail}{msg}{self.off}")


# ---------------------------------------------------------------- gcloud
class Result:
    """Outcome of one gcloud call. rc: 0 ok, 2 permission denied, 1 other error."""

    def __init__(self, rc: int, out: str, err: str) -> None:
        self.rc = rc
        self.out = out
        self.err = err

    @property
    def ok(self) -> bool:
        return self.rc == 0

    @property
    def denied(self) -> bool:
        return self.rc == 2

    def first_err_line(self) -> str:
        for line in self.err.splitlines():
            if not line.strip() or re.fullmatch(r"(WARNING|ERROR):?\s*", line, re.I):
                continue
            line = re.sub(r"^(ERROR|WARNING): ?", "", line)
            line = re.sub(r"^ *- ", "", line)
            return line[:160]
        return ""


class Gcloud:
    def __init__(self, exe: str) -> None:
        self.exe = exe
        self.project = ""

    def run(self, *args: str) -> Result:
        try:
            p = subprocess.run(
                [self.exe, *args], capture_output=True, text=True, errors="replace"
            )
        except OSError as e:
            return Result(1, "", str(e))
        out = p.stdout.rstrip("\n")
        if p.returncode == 0:
            return Result(0, out, p.stderr)
        return Result(2 if PERM_RE.search(p.stderr) else 1, out, p.stderr)

    def project_run(self, *args: str) -> Result:
        """Run against the project under check."""
        return self.run(*args, f"--project={self.project}")


def run_quiet(argv: list) -> str:
    """stdout of a local tool, or "" when it cannot run."""
    try:
        p = subprocess.run(argv, capture_output=True, text=True, errors="replace")
    except OSError:
        return ""
    return p.stdout


def first_line(text: str) -> str:
    for line in text.splitlines():
        if line.strip():
            return line.strip()
    return ""


def version_tuple(v: str) -> tuple:
    return tuple(int(x) for x in re.findall(r"\d+", v))


def to_int(v, default: int) -> int:
    try:
        return int(str(v).strip())
    except (TypeError, ValueError):
        return default


def as_list(v) -> list:
    if isinstance(v, list):
        return [str(x) for x in v]
    if isinstance(v, str):
        return v.split()
    return []


# ---------------------------------------------------------------- tfvars
class TfvarsError(Exception):
    pass


_TOKEN_RE = re.compile(
    r'(?P<ws>\s+)|(?P<str>"(?:[^"\\]|\\.)*")|(?P<num>-?\d+(?:\.\d+)?)|'
    r"(?P<id>[A-Za-z_][A-Za-z0-9_-]*)|(?P<p>[=\[\]{},:])"
)


def _strip_comments(src: str) -> str:
    """Remove #, // and /* */ comments outside strings."""
    out, i, n, instr = [], 0, len(src), False
    while i < n:
        c = src[i]
        if instr:
            out.append(c)
            if c == "\\" and i + 1 < n:
                out.append(src[i + 1])
                i += 2
                continue
            if c == '"':
                instr = False
            i += 1
            continue
        if c == '"':
            instr = True
            out.append(c)
            i += 1
            continue
        if c == "#" or src.startswith("//", i):
            while i < n and src[i] != "\n":
                i += 1
            continue
        if src.startswith("/*", i):
            j = src.find("*/", i + 2)
            i = n if j < 0 else j + 2
            continue
        out.append(c)
        i += 1
    return "".join(out)


class _Parser:
    """A small reader for the tfvars subset the template uses (strings,
    numbers, booleans, lists, objects, nested objects). It is not a full HCL parser.
    Scalars are kept as their source text: numbers and booleans are strings."""

    def __init__(self, src: str) -> None:
        s = _strip_comments(src)
        self.tokens, pos = [], 0
        for m in _TOKEN_RE.finditer(s):
            if m.start() != pos:
                raise TfvarsError("cannot read tfvars near: " + s[pos:pos + 40].strip())
            pos = m.end()
            if m.lastgroup != "ws":
                self.tokens.append((m.lastgroup, m.group()))
        if pos != len(s):
            raise TfvarsError("cannot read tfvars near: " + s[pos:pos + 40].strip())
        self.i = 0

    def peek(self):
        return self.tokens[self.i] if self.i < len(self.tokens) else (None, None)

    def take(self):
        if self.i >= len(self.tokens):
            raise TfvarsError("cannot read tfvars: unexpected end of file")
        t = self.tokens[self.i]
        self.i += 1
        return t

    @staticmethod
    def key_of(t) -> str:
        return t[1][1:-1] if t[0] == "str" else t[1]

    def value(self):
        k, v = self.take()
        if k == "str":
            return v[1:-1].replace('\\"', '"')
        if k in ("num", "id"):
            return v
        if v == "[":
            items = []
            while self.peek()[1] != "]":
                items.append(self.value())
                if self.peek()[1] == ",":
                    self.take()
            self.take()
            return items
        if v == "{":
            obj = {}
            while self.peek()[1] != "}":
                key = self.key_of(self.take())
                if self.peek()[1] in ("=", ":"):
                    self.take()
                obj[key] = self.value()
                if self.peek()[1] == ",":
                    self.take()
            self.take()
            return obj
        raise TfvarsError("cannot read tfvars: unexpected " + v)

    def parse(self) -> dict:
        top = {}
        while self.i < len(self.tokens):
            key = self.key_of(self.take())
            if self.peek()[1] != "=":
                raise TfvarsError("cannot read tfvars: expected = after " + key)
            self.take()
            top[key] = self.value()
        return top


class Tfvars:
    def __init__(self, data: dict, path: str = "") -> None:
        self.data = data
        self.path = path

    @classmethod
    def load(cls, path: str) -> "Tfvars":
        with open(path, encoding="utf-8") as f:
            return cls(_Parser(f.read()).parse(), path)

    @property
    def loaded(self) -> bool:
        return bool(self.path)

    def get(self, key: str, default=None):
        """Value at a dotted key, or default when unset or null."""
        node = self.data
        for part in key.split("."):
            if not isinstance(node, dict) or part not in node:
                return default
            node = node[part]
        if node is None or node == "null" or node == "":
            return default
        return node

    def get_list(self, key: str, default: list) -> list:
        v = self.get(key)
        return as_list(v) if v is not None else list(default)

    def is_set(self, key: str) -> bool:
        v = self.get(key)
        return v not in (None, "", "null", [], {})


# ---------------------------------------------------------------- helpers
def parse_link(link: str):
    """Self-link -> (project, kind, region, name); region is "-" for a network."""
    p = link[len(LINK_PREFIX):] if link.startswith(LINK_PREFIX) else link
    m = re.fullmatch(r"projects/([^/]+)/global/networks/([^/]+)", p)
    if m:
        return m.group(1), "network", "-", m.group(2)
    m = re.fullmatch(r"projects/([^/]+)/regions/([^/]+)/subnetworks/([^/]+)", p)
    if m:
        return m.group(1), "subnet", m.group(2), m.group(3)
    return None


def member_of(account: str) -> str:
    """IAM member string for a user or service account."""
    kind = "serviceAccount" if account.endswith(".gserviceaccount.com") else "user"
    return f"{kind}:{account}"


def policy_list(out: str):
    """Effective list policy -> (kind, values); kind in none, ALLOW, DENY, allowed, denied."""
    lp = json.loads(out).get("listPolicy")
    if not lp:
        return "none", []
    if lp.get("allValues") in ("ALLOW", "DENY"):
        return lp["allValues"], []
    if lp.get("allowedValues"):
        return "allowed", list(lp["allowedValues"])
    if lp.get("deniedValues"):
        return "denied", list(lp["deniedValues"])
    return "none", []


def test_iam_permissions(project: str, token: str, perms: list):
    """-> (missing permissions, "") or (None, error text)."""
    url = f"https://cloudresourcemanager.googleapis.com/v1/projects/{project}:testIamPermissions"
    req = urllib.request.Request(
        url,
        data=json.dumps({"permissions": perms}).encode("utf-8"),
        method="POST",
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            body = resp.read()
    except urllib.error.HTTPError as e:
        body = e.read()
    except (urllib.error.URLError, OSError) as e:
        return None, str(e)[:160]
    try:
        d = json.loads(body.decode("utf-8", "replace"))
    except ValueError:
        return None, ""
    if "error" in d:
        err = d["error"]
        msg = err.get("message", "") if isinstance(err, dict) else err
        return None, str(msg)[:160]
    got = set(d.get("permissions", []))
    return [p for p in perms if p not in got], ""


# ---------------------------------------------------------------- checks
class Preflight:
    def __init__(self, r: Report, gc: Gcloud, tv: Tfvars, project_id: str, deployer: str) -> None:
        self.r = r
        self.gc = gc
        self.tv = tv
        self.project_id = project_id or tv.get("project_id", "")
        self.deployer = deployer or tv.get("deployer_service_account", "")
        # Template defaults (terraform/variables.tf). Only the ones the checks need.
        self.region = tv.get("region", "us-west1")
        self.zones = tv.get_list("zones", []) or [f"{self.region}-a", f"{self.region}-b"]
        self.deployment_name = tv.get("deployment_name", "fundamental")
        self.bundle_version = tv.get("bundle_version", "")
        self.hardened_image = tv.get("hardened_image", "")
        self.producer_bucket = tv.get("producer_release_bucket_name", "fun-marketplace-us")
        self.exposure = tv.get("customer_exposure_enabled", "false") == "true"
        self.edge_cert = tv.get("edge_certificate_id", "")
        self.gpu_region = tv.get("modelgpu.region", self.region)
        self.gke_min = to_int(tv.get("gke_min_node_count_per_zone", "1"), 1)
        # Filled in as the checks run.
        self.account = ""
        self.token = ""
        self.project_number = ""
        self.state_exists = False
        self.net_name = ""
        self.hosts: list = []
        self.org_skip = False
        self._zones: dict = {}

    # ------------------------------------------------------------ 1. gcloud and sign-in
    def check_signin(self) -> None:
        r, gc = self.r, self.gc
        r.section("gcloud and sign-in")
        r.ok(f"{first_line(gc.run('version').out) or 'gcloud'} is installed.")
        self.account = gc.run("config", "get-value", "account").out.strip()
        token = gc.run("auth", "print-access-token")
        if not self.account or not token.ok:
            r.fail("You are not signed in to gcloud.", "Sign in:", "gcloud auth login")
            sys.exit(1)
        self.token = token.out.strip()
        r.ok(f"Signed in as {self.account}.")
        config_project = gc.run("config", "get-value", "project").out.strip()
        if not self.project_id:
            self.project_id = config_project
            if not self.project_id:
                r.fail("No project known.", "Pass -p <project-id>, or set a default:", "gcloud config set project <project-id>")
                print()
                sys.exit(1)
        if config_project and config_project != self.project_id:
            r.warn(
                f"gcloud's current project is {config_project}, but this check runs against {self.project_id}.",
                "The deploy script uses gcloud's current project. Before you deploy:",
                f"gcloud config set project {self.project_id}",
            )
        tv_project = self.tv.get("project_id", "")
        if tv_project and tv_project != self.project_id:
            r.warn(f"project_id in the tfvars file is {tv_project}, not {self.project_id}.", "Check -p and project_id.")
        gc.project = self.project_id

    # ------------------------------------------------------------ 2. Project
    def check_project(self) -> None:
        r, gc, pid = self.r, self.gc, self.project_id
        r.section(f"Project {pid}")
        res = gc.run("projects", "describe", pid, "--format=value(projectNumber,lifecycleState)")
        if res.ok:
            fields = (res.out.split("\t") + ["", ""])[:2]
            self.project_number, state = fields[0], fields[1]
            if state == "ACTIVE":
                r.ok(f"Project exists and is active (number {self.project_number}).")
                r.info(f"Share the project ID {pid}, the project number {self.project_number} and the region with Fundamental for onboarding.")
            else:
                r.fail(f"Project is in state {state}.", "The project must be ACTIVE.")
        elif res.denied:
            r.skip(f"Project {pid} exists and is active", "resourcemanager.projects.get on the project (roles/viewer)")
        else:
            r.fail(f"Project {pid} was not found.", "Check the project id:", "gcloud projects list")

        res = gc.run("billing", "projects", "describe", pid, "--format=value(billingEnabled)")
        if res.ok:
            if res.out.strip().lower() == "true":
                r.ok("Billing is enabled.")
            else:
                r.fail(
                    "Billing is not enabled on the project.",
                    "Link a billing account in the Console under Billing, or:",
                    f"gcloud billing projects link {pid} --billing-account <id>",
                )
        elif res.denied:
            r.skip("Billing is enabled on the project", "billing.resourceAssociations.list (roles/billing.user or roles/viewer)")
        else:
            r.warn("Could not read the billing state.", res.first_err_line())

    # ------------------------------------------------------------ 3. APIs
    def check_apis(self) -> None:
        r, gc, pid = self.r, self.gc, self.project_id
        r.section("Required APIs")
        required = list(APIS_REQUIRED)
        if self.exposure and self.edge_cert:
            required.append("certificatemanager.googleapis.com")
        res = gc.project_run("services", "list", "--enabled", "--format=value(config.name)")
        if not res.ok:
            if res.denied:
                r.skip("Required APIs are enabled", "serviceusage.services.list on the project (roles/viewer)")
            else:
                r.warn("Could not list enabled APIs.", res.first_err_line())
            return
        enabled = set(res.out.split())
        missing = [a for a in required if a not in enabled]
        if missing:
            r.fail(f"APIs not enabled: {' '.join(missing)}", "Enable them:", f"gcloud services enable {' '.join(missing)} --project {pid}")
            print()
            r.stop("Stopped here: every check below needs these APIs. Enable them, wait a minute and run the script again.")
            sys.exit(1)
        r.ok("All required APIs are enabled.")
        later = [a for a in APIS_SELF_ENABLED if a not in enabled]
        if later:
            r.warn(
                f"Not enabled yet; the deployment turns them on during the first run: {' '.join(later)}",
                "That needs serviceusage.services.enable. To enable them now:",
                f"gcloud services enable {' '.join(later)} --project {pid}",
            )
        else:
            r.ok("APIs the deployment enables itself are already on (container, dns, parametermanager).")

    # ------------------------------------------------------------ 4. Deployer service account
    def check_deployer(self) -> None:
        """The deployment runs as a service account in the project: Fundamental's
        release grant covers the project's service accounts, never a user. From
        here on every gcloud call impersonates it, so the checks that follow
        describe the identity that will deploy."""
        r, gc, pid = self.r, self.gc, self.project_id
        r.section("Deployer service account")
        if not self.deployer:
            r.fail(
                "No deployer service account given.",
                "Create it (deployment guide, Step 1) and pass -s <account>, or set deployer_service_account in the tfvars file. "
                f"Without it the deployment runs as {self.account}, which Fundamental's release grant never covers.",
            )
            print()
            r.stop("Stopped here: the checks below describe the deployer account.")
            sys.exit(1)
        if not self.deployer.endswith(f"@{pid}.iam.gserviceaccount.com"):
            r.fail(
                f"{self.deployer} is not a service account of project {pid}.",
                f"It must be <name>@{pid}.iam.gserviceaccount.com: Fundamental's release grant covers only the project's own service accounts.",
            )
        res = gc.project_run("iam", "service-accounts", "describe", self.deployer, "--format=value(email)")
        if res.ok:
            r.ok(f"Service account {self.deployer} exists.")
        elif res.denied:
            r.skip(f"Service account {self.deployer} exists", "iam.serviceAccounts.get (roles/viewer)")
        else:
            r.fail(
                f"Service account {self.deployer} was not found.",
                "Create it:",
                f"gcloud iam service-accounts create {self.deployer.split('@')[0]} --project {pid}",
            )
        token = gc.run("auth", "print-access-token", f"--impersonate-service-account={self.deployer}")
        if not token.ok:
            r.fail(
                f"{self.account} cannot act as {self.deployer}.",
                "Grant yourself the right to mint its tokens (a new binding takes about a minute to take effect):",
                f"gcloud iam service-accounts add-iam-policy-binding {self.deployer} --project {pid} "
                f"--member {member_of(self.account)} --role roles/iam.serviceAccountTokenCreator",
            )
            print()
            r.stop("Stopped here: the checks below run as the deployer account.")
            sys.exit(1)
        r.ok(f"{self.account} can act as {self.deployer}.")
        # Every gcloud call from here on, and the permission test below, run as the deployer.
        os.environ["CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT"] = self.deployer
        self.account = self.deployer
        self.token = token.out.strip()

    # ------------------------------------------------------------ 5. The deployer's permissions
    def check_permissions(self) -> None:
        r, gc, pid = self.r, self.gc, self.project_id
        r.section(f"Permissions of {self.account} on {pid}")
        member = member_of(self.account)
        res = gc.project_run("projects", "get-iam-policy", pid, "--format=json")
        if res.ok:
            try:
                bindings = json.loads(res.out).get("bindings", [])
            except ValueError:
                bindings = []
            roles = sorted(b["role"] for b in bindings if member in b.get("members", []))
            r.info(f"Roles granted to {member} directly: {', '.join(roles) or 'none'}. This does not include roles that come through groups or folders.")
            if "roles/owner" in roles:
                r.ok("The deployer holds roles/owner on the project.")
        elif res.denied:
            r.skip("The deployer's roles on the project", "resourcemanager.projects.getIamPolicy (roles/viewer)")

        missing, err = test_iam_permissions(pid, self.token, PERMS)
        if missing is None:
            r.warn("Could not test the deployer's permissions.", err)
        elif missing:
            r.fail(
                f"The deployer is missing permissions: {' '.join(missing)}",
                "Grant it roles/owner:",
                f"gcloud projects add-iam-policy-binding {pid} --member {member} --role roles/owner",
            )
        else:
            r.ok(f"The deployer holds every permission the deployment needs ({len(PERMS)} checked).")

    # ------------------------------------------------------------ 6. Local tools
    def tool(self, cmd: str, hint: str, *args: str) -> None:
        exe = shutil.which(cmd)
        if exe:
            v = first_line(run_quiet([exe, *args]))[:60]
            self.r.ok(f"{cmd} is installed" + (f" ({v})" if v else "") + ".")
        else:
            self.r.fail(f"{cmd} is not installed.", hint)

    def check_tools(self) -> None:
        r = self.r
        r.section("Local tools")
        tf = shutil.which("terraform")
        if tf:
            tf_ver = re.sub(r"^Terraform v", "", first_line(run_quiet([tf, "version"])))
            if version_tuple(tf_ver) >= version_tuple(TF_MIN_VERSION):
                r.ok(f"terraform {tf_ver} is installed (needs >= {TF_MIN_VERSION}).")
            else:
                r.fail(f"terraform {tf_ver} is too old.", f"The deployment needs Terraform >= {TF_MIN_VERSION}: https://developer.hashicorp.com/terraform/install")
        else:
            r.fail("terraform is not installed.", f"Install Terraform >= {TF_MIN_VERSION}: https://developer.hashicorp.com/terraform/install")

        helm_hint = "Install Helm 4: https://helm.sh/docs/intro/install/"
        self.tool("helm", helm_hint, "version", "--short")
        helm = shutil.which("helm")
        if helm:
            m = re.match(r"v?(\d+)", run_quiet([helm, "version", "--template", "{{.Version}}"]).strip())
            major = int(m.group(1)) if m else 0
            if major >= 4:
                r.ok(f"Helm major version is {major} (4 or newer required).")
            else:
                r.fail(f"Helm {major or 'unknown'} is too old: the deploy script uses Helm 4 flags.", helm_hint)
        self.tool("kubectl", "Install kubectl: https://kubernetes.io/docs/tasks/tools/", "version", "--client")
        self.tool("crane", "Install crane: https://github.com/google/go-containerregistry/blob/main/cmd/crane/README.md", "version")
        self.tool("perl", "Install perl (ships with macOS and most Linux distributions).", "-e", 'print "$^V\\n"')
        self.tool("python3", "Install Python 3: https://www.python.org/downloads/", "--version")
        components = self.gc.run("components", "list", "--format=value(id,state.name)").out
        if re.search(r"^gke-gcloud-auth-plugin\s+Installed", components, re.M) or shutil.which("gke-gcloud-auth-plugin"):
            r.ok("gke-gcloud-auth-plugin is installed.")
        else:
            r.fail("gke-gcloud-auth-plugin is not installed.", "kubectl needs it to reach the cluster:", "gcloud components install gke-gcloud-auth-plugin")

    # ------------------------------------------------------------ 7. Onboarding with Fundamental
    def check_onboarding(self) -> None:
        r, gc = self.r, self.gc
        r.section("Onboarding with Fundamental")
        bucket = self.producer_bucket
        not_readable = (
            f"Bundle bucket gs://{bucket} is not readable by {self.account}.",
            f"Fundamental grants read access to the service accounts of project number {self.project_number or '<project number>'} during onboarding. "
            "Confirm onboarding is complete.",
        )
        if self.bundle_version:
            if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", self.bundle_version):
                r.fail(f"bundle_version '{self.bundle_version}' is not a plain X.Y.Z.", "Use the version Fundamental named for the release, for example 1.0.2.")
            res = gc.project_run("storage", "ls", f"gs://{bucket}/bundles/{self.bundle_version}/app-manifest.json")
            if res.ok:
                r.ok(f"Bundle {self.bundle_version} is readable in gs://{bucket}.")
            elif res.denied:
                r.fail(*not_readable)
            else:
                r.fail(f"Bundle {self.bundle_version} was not found in gs://{bucket}/bundles/.", f"Check bundle_version against the release Fundamental named. {res.first_err_line()}")
        else:
            # bundles/* and not bundles/: for the plain form gcloud lists the prefix "bundles"
            # at bucket level, which the managed-folder grant does not cover.
            res = gc.project_run("storage", "ls", f"gs://{bucket}/bundles/*")
            if res.ok:
                r.ok(f"Bundle bucket gs://{bucket} is readable. Set bundle_version to check one release.")
            elif res.denied:
                r.fail(*not_readable)
            else:
                r.warn(f"Could not list gs://{bucket}/bundles/.", res.first_err_line())

        if self.hardened_image:
            res = gc.project_run("compute", "images", "describe", self.hardened_image, "--format=value(name,status)")
            if res.ok:
                status = (res.out.split("\t") + [""])[1]
                if status == "READY":
                    r.ok(f"Hardened image {self.hardened_image} is readable and READY.")
                else:
                    r.warn(f"Hardened image {self.hardened_image} is in state {status}.", "Ask Fundamental which image to use.")
            elif res.denied:
                r.fail(f"Hardened image {self.hardened_image} is not readable.", "Fundamental makes the image readable by your project during onboarding. Confirm onboarding is complete.")
            else:
                r.fail(
                    f"Hardened image {self.hardened_image} was not found.",
                    "Either the name is wrong, or Fundamental has not yet shared it with your project (onboarding). An image you cannot read also reports not found.",
                )
        else:
            r.info("hardened_image not set: the image is not checked. Pass -t with hardened_image set.")
        r.info("The attestation broker's PSC service attachment must also accept your project number. Only Fundamental can confirm that.")

    # ------------------------------------------------------------ 8. Region and zones
    def check_region(self, region: str) -> bool:
        res = self.gc.project_run("compute", "regions", "describe", region, "--format=value(status)")
        if res.ok:
            if res.out.strip() == "UP":
                self.r.ok(f"Region {region} is valid.")
            else:
                self.r.warn(f"Region {region} is in state {res.out.strip()}.")
            return True
        if res.denied:
            self.r.skip(f"Region {region} is valid", "compute.regions.get (roles/compute.viewer)")
        else:
            self.r.fail(f"Region '{region}' is not a valid region.", "Use the short name, for example us-east5. List them:", "gcloud compute regions list")
        return False

    def zones_in(self, region: str):
        """Zone names of a region, cached; None when the list could not be read."""
        if region not in self._zones:
            res = self.gc.project_run("compute", "zones", "list", f"--filter=region:({region})", "--format=value(name)")
            self._zones[region] = res.out.split() if res.ok else None
        return self._zones[region]

    def check_zones(self, label: str, region: str, zones: list) -> None:
        known = self.zones_in(region)
        bad = []
        for z in zones:
            if not z.startswith(region + "-"):
                bad.append(z)
            elif known is not None and z not in known:
                bad.append(z)
        if bad:
            self.r.fail(f"{label}: zone(s) {' '.join(bad)} are not in region {region}.", "List the zones:", f"gcloud compute zones list --filter='region:({region})'")
        else:
            self.r.ok(f"{label}: zones {' '.join(zones)} are in {region}.")

    def check_regions(self) -> None:
        r, tv = self.r, self.tv
        r.section("Region and zones")
        if self.check_region(self.region):
            self.check_zones("zones", self.region, self.zones)
        if self.region == "us-central1":
            r.info("Region is us-central1: the attestation endpoint shares the private subnet.")
        elif tv.is_set("existing_network.network"):
            r.info("The attestation endpoint needs a subnet in us-central1: existing_network.attestation_psc_subnet (checked below).")
        else:
            r.info("The attestation endpoint needs a small subnet in us-central1; the deployment creates it (attestation_psc_subnet_cidr).")
        if self.gpu_region != self.region:
            if self.check_region(self.gpu_region):
                r.info(f"modelgpu.region is set: the GPU tier runs in {self.gpu_region}.")
            if not tv.is_set("modelgpu.zones"):
                r.fail("modelgpu.region is set but modelgpu.zones is not.", f"Set modelgpu.zones to zones of {self.gpu_region}.")

    # ------------------------------------------------------------ 9. Compute capacity
    def check_capacity(self) -> None:
        self.r.section("Compute capacity")
        self.r.info(COMPUTE_CAPACITY_NOTE)

    # ------------------------------------------------------------ 10. Terraform state
    def check_state(self) -> None:
        r = self.r
        r.section("Terraform state")
        bucket = f"{self.project_id}-tfstate-fun"
        res = self.gc.project_run("storage", "buckets", "describe", f"gs://{bucket}", "--format=value(location)")
        if res.ok:
            self.state_exists = True
            r.info(f"State bucket gs://{bucket} exists (location {res.out.strip()}): an earlier deployment of this project. The deploy script continues from its state.")
        elif res.denied:
            r.skip(f"State bucket gs://{bucket}", "storage.buckets.get (roles/storage.admin or roles/viewer)")
        else:
            r.info(f"State bucket gs://{bucket} does not exist yet: the deploy script creates it on the first run.")

    # ------------------------------------------------------------ 11. Network
    def check_subnet(self, label: str, link: str, want_region: str, want_pga: bool, ranges: list = ()) -> None:
        r = self.r
        parsed = parse_link(link)
        if not parsed or parsed[1] != "subnet":
            r.fail(f"{label}: '{link}' is not a subnet self-link.", "Expected: projects/<project>/regions/<region>/subnetworks/<name>")
            return
        sp, _, sr, sname = parsed
        if want_region and sr != want_region:
            r.fail(f"{label}: subnet {sname} is in {sr}, not {want_region}.", f"Use a subnet in {want_region}.")
        res = self.gc.run(
            "compute", "networks", "subnets", "describe", sname, "--region", sr, "--project", sp,
            "--format=value(network.basename(),privateIpGoogleAccess,secondaryIpRanges[].rangeName)",
        )
        if res.ok:
            net, pga, rng = (res.out.split("\t") + ["", "", ""])[:3]
            r.ok(f"{label}: subnet {sname} exists in {sr}.")
            if self.net_name and net != self.net_name:
                r.fail(f"{label}: subnet {sname} belongs to network {net}, not {self.net_name}.", "Every subnet in existing_network must be in existing_network.network.")
            if want_pga:
                if pga == "True":
                    r.ok(f"{label}: Private Google Access is on.")
                else:
                    r.fail(
                        f"{label}: Private Google Access is off on {sname}.",
                        "Turn it on:",
                        f"gcloud compute networks subnets update {sname} --region {sr} --project {sp} --enable-private-ip-google-access",
                    )
            present = rng.split(";")
            for name in ranges:
                if name in present:
                    r.ok(f"{label}: secondary range '{name}' is present.")
                else:
                    r.fail(
                        f"{label}: no secondary range named '{name}' on {sname}.",
                        "Add it:",
                        f"gcloud compute networks subnets update {sname} --region {sr} --project {sp} --add-secondary-ranges {name}=<cidr>",
                    )
        elif res.denied:
            r.skip(f"{label}: subnet {sname} exists with Private Google Access and the secondary ranges", f"compute.subnetworks.get on project {sp} (roles/compute.viewer)")
        else:
            r.fail(f"{label}: subnet {sname} was not found in {sr} of project {sp}.", res.first_err_line())

    def check_network(self) -> None:
        r, gc, tv = self.r, self.gc, self.tv
        r.section("Network")
        if tv.is_set("existing_network.network"):
            self.check_existing_network()
        else:
            vpc = f"{self.deployment_name}-vpc"
            r.info(
                f"A new VPC {vpc} is created with {tv.get('vpc_cidr', '10.0.0.0/16')}: subnet {tv.get('private_subnet_1_cidr', '10.0.0.0/22')}, "
                f"pods {tv.get('gke_pods_cidr', '10.0.128.0/17')}, services {tv.get('gke_services_cidr', '10.0.16.0/20')}, "
                f"GPU {tv.get('modelgpu_subnet_cidr', '10.0.48.0/22')}, control plane {tv.get('gke_master_ipv4_cidr', '172.16.0.0/28')}."
            )
            res = gc.project_run("compute", "networks", "describe", vpc, "--format=value(name)")
            if res.ok:
                if self.state_exists:
                    r.info(f"Network {vpc} exists: this project's earlier deployment. The deploy script continues from its state.")
                else:
                    r.warn(f"A network named {vpc} already exists in {self.project_id}, but no state bucket does.", "A project holds one deployment. If this is a leftover, remove it or use another project.")
            elif res.denied:
                r.skip(f"No network named {vpc} exists yet", "compute.networks.get (roles/compute.viewer)")
            else:
                r.ok(f"No network named {vpc} exists yet.")
        if re.fullmatch(r"[a-z]([a-z0-9-]{0,10}[a-z0-9])?", self.deployment_name):
            r.ok(f"deployment_name '{self.deployment_name}' has a valid format (2 to 12 characters).")
        else:
            r.fail(
                f"deployment_name '{self.deployment_name}' is not valid.",
                "Use 2 to 12 characters: lowercase letters, digits and hyphens, starting with a letter and ending with a letter or digit. It prefixes every resource name.",
            )

    def check_existing_network(self) -> None:
        r, gc, tv = self.r, self.gc, self.tv
        r.info("Deploying into an existing VPC (existing_network).")
        net_link = tv.get("existing_network.network", "")
        parsed = parse_link(net_link)
        if not parsed or parsed[1] != "network":
            r.fail(f"existing_network.network '{net_link}' is not a network self-link.", "Expected: projects/<project>/global/networks/<name>")
        else:
            np, _, _, self.net_name = parsed
            res = gc.run("compute", "networks", "describe", self.net_name, "--project", np, "--format=value(name)")
            if res.ok:
                r.ok(f"Network {self.net_name} exists in project {np}.")
                zones = gc.run(
                    "dns", "managed-zones", "list", "--project", np,
                    f"--filter=privateVisibilityConfig.networks.networkUrl~/networks/{self.net_name}$ AND (dnsName=ftm-int.net. OR dnsName=gcp.fundamental.tech.)",
                    "--format=value(name)",
                )
                if zones.ok:
                    names = " ".join(zones.out.split())
                    if not names:
                        r.ok(f"No private zone ftm-int.net or gcp.fundamental.tech is attached to {self.net_name} yet.")
                    elif self.state_exists:
                        r.warn(
                            f"Private DNS zone(s) attached to {self.net_name}: {names}",
                            "They belong to this project's earlier deployment (state bucket exists). That is fine for an upgrade, but a second deployment in the same network is not supported.",
                        )
                    else:
                        r.fail(f"Private DNS zone(s) already attached to {self.net_name}: {names}", "A network carries one deployment. Use another network.")
            elif res.denied:
                r.skip(f"Network {self.net_name} exists", f"compute.networks.get on project {np} (roles/compute.viewer)")
            else:
                r.fail(f"Network {self.net_name} was not found in project {np}.", res.first_err_line())

        if tv.is_set("existing_network.private_subnet"):
            ranges = [tv.get("existing_network.pods_range_name", "pods"), tv.get("existing_network.services_range_name", "services")]
            self.check_subnet("private subnet", tv.get("existing_network.private_subnet", ""), self.region, True, ranges)
        else:
            r.fail("existing_network.private_subnet is not set.", "It carries the GKE nodes and the sealed CPU tiers.")
        if self.gpu_region != self.region:
            if tv.is_set("existing_network.modelgpu_subnet"):
                self.check_subnet("modelgpu subnet", tv.get("existing_network.modelgpu_subnet", ""), self.gpu_region, True)
            else:
                r.fail(
                    f"existing_network.modelgpu_subnet is required when modelgpu.region ({self.gpu_region}) differs from region ({self.region}).",
                    f"Set it to a subnet in {self.gpu_region}, or remove modelgpu.region.",
                )
        elif tv.is_set("existing_network.modelgpu_subnet"):
            self.check_subnet("modelgpu subnet", tv.get("existing_network.modelgpu_subnet", ""), self.gpu_region, True)
        else:
            r.info("The GPU tier shares the private subnet (modelgpu.region not set).")
        if self.region != "us-central1":
            if tv.is_set("existing_network.attestation_psc_subnet"):
                self.check_subnet("attestation PSC subnet", tv.get("existing_network.attestation_psc_subnet", ""), "us-central1", True)
            else:
                r.fail(
                    "existing_network.attestation_psc_subnet is required when region is not us-central1.",
                    f"The attestation broker's service attachment is in us-central1; the consumer endpoint needs a subnet there. Set it to a small subnet of {self.net_name} in us-central1.",
                )
        for k in ("proxy_only_subnet", "psc_nat_subnet"):
            if tv.is_set(f"existing_network.{k}"):
                self.check_subnet(k, tv.get(f"existing_network.{k}", ""), self.region, False)

    # ------------------------------------------------------------ 12. Customer exposure (optional)
    def check_exposure(self) -> None:
        r, gc, tv = self.r, self.gc, self.tv
        r.section("Customer exposure (optional)")
        if not self.exposure:
            r.info("customer_exposure_enabled is off: the platform is reachable only inside the deployment VPC, on the ftm-int.net names.")
            return
        r.info("customer_exposure_enabled is on: the apps are published over Private Service Connect under your domain.")
        if tv.is_set("edge_proxy_only_subnet_cidr") or tv.is_set("existing_network.proxy_only_subnet"):
            r.ok("Proxy-only subnet is configured.")
        else:
            r.fail("edge_proxy_only_subnet_cidr is not set.", "The edge load balancer needs a REGIONAL_MANAGED_PROXY subnet, for example 10.0.40.0/26, or existing_network.proxy_only_subnet.")
        if tv.is_set("edge_psc_nat_subnet_cidr") or tv.is_set("existing_network.psc_nat_subnet"):
            r.ok("PSC NAT subnet is configured.")
        else:
            r.fail("edge_psc_nat_subnet_cidr is not set.", "The PSC service attachment needs a PRIVATE_SERVICE_CONNECT subnet, for example 10.0.40.64/28, or existing_network.psc_nat_subnet.")
        consumers = tv.get_list("allowed_consumer_projects", [])
        if not consumers:
            r.fail("allowed_consumer_projects is empty.", "List the project id(s) that will create the PSC consumer endpoint.")
        for cp in consumers:
            res = gc.run("projects", "describe", cp, "--format=value(projectId)")
            if res.ok:
                r.ok(f"Consumer project {cp} exists.")
            elif res.denied:
                r.skip(f"Consumer project {cp} exists", f"resourcemanager.projects.get on {cp}")
            else:
                r.fail(f"Consumer project {cp} was not found.", "Check allowed_consumer_projects.")
        apps = tv.get("exposed_apps", [])
        apps = apps if isinstance(apps, list) else []
        if not apps:
            r.fail("exposed_apps is empty.", "Copy the exposed_apps block from example.tfvars and set the hosts under your domain.")
        else:
            self.hosts = [str(a.get("host", "")) for a in apps if isinstance(a, dict) and a.get("host")]
            r.ok(f"{len(apps)} app(s) exposed: {' '.join(self.hosts)}")
            for h in self.hosts:
                if not re.fullmatch(r"[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+", h):
                    r.fail(f"Host '{h}' is not a valid hostname.", "Use lowercase, no scheme, no wildcard, no trailing dot.")
        if self.gke_min < 1:
            r.fail(f"gke_min_node_count_per_zone is {self.gke_min}.", "With customer exposure the edge needs a node in every zone: keep it at least 1.")
        if not self.edge_cert:
            r.info("edge_certificate_id not set: the edge serves plain HTTP. Set it for HTTPS.")
            return
        m = re.search(r"/locations/([^/]+)/certificates/", self.edge_cert)
        if not m:
            r.fail("edge_certificate_id has the wrong format.", "Expected: projects/<project>/locations/<region>/certificates/<name>")
            return
        if m.group(1) != self.region:
            r.fail(f"Certificate is in location {m.group(1)}, not {self.region}.", "A regional load balancer needs a certificate in its own region.")
        res = gc.run("certificate-manager", "certificates", "describe", self.edge_cert, "--format=value(sanDnsnames,managed.state,expireTime)")
        if res.ok:
            sans, cstate, cexp = (res.out.split("\t") + ["", "", ""])[:3]
            r.ok(f"Certificate exists ({cstate or 'self-managed'}{', expires ' + cexp if cexp else ''}).")
            if self.hosts:
                san_set = set(sans.split(";"))
                miss = [h for h in self.hosts if h not in san_set and "*." + h.split(".", 1)[-1] not in san_set]
                if miss:
                    r.fail(f"Certificate does not cover: {' '.join(miss)}", f"SANs on the certificate: {sans or 'none'}. It must list each host or a wildcard for its domain.")
                else:
                    r.ok("Certificate covers every exposed host.")
        elif res.denied:
            r.skip(f"Certificate {self.edge_cert} exists and covers the hosts", "certificatemanager.certs.get (roles/certificatemanager.viewer)")
        else:
            r.fail(f"Certificate {self.edge_cert} was not found.", res.first_err_line())

    # ------------------------------------------------------------ 13. Organization policies
    def org_policy(self, constraint: str) -> Result:
        return self.gc.project_run("resource-manager", "org-policies", "describe", f"constraints/{constraint}", "--effective", "--format=json")

    def check_list_policy(self, c: str, ok_msg: str, mode: str, pattern: str, bad_msg: str, hint: str) -> None:
        """mode "denies": FAIL when a denied value matches pattern.
        mode "needs": FAIL when an allowed list exists and no value matches pattern."""
        r = self.r
        res = self.org_policy(c)
        if not res.ok:
            if res.denied:
                self.org_skip = True
            else:
                r.warn(f"Could not read {c}.", res.first_err_line())
            return
        try:
            kind, values = policy_list(res.out)
        except ValueError:
            r.warn(f"Could not read {c}.", "gcloud returned something that is not JSON.")
            return
        if kind in ("none", "ALLOW"):
            r.ok(f"{c}: {ok_msg}")
            return
        if kind == "DENY":
            r.fail(f"{c} denies all values.", hint)
            return
        text = f"{kind}:{' '.join(values)}"
        matched = re.search(pattern, text) is not None
        bad = (kind == "allowed" and mode == "needs" and not matched) or (kind == "denied" and matched)
        if bad:
            r.fail(f"{c}: {bad_msg} ({text}).", hint)
        else:
            r.warn(f"{c} restricts values: {text}.", hint)

    def check_org_policies(self) -> None:
        r = self.r
        r.section("Organization policies")
        res = self.org_policy("compute.requireShieldedVm")
        if res.ok:
            r.ok("compute.requireShieldedVm: every VM of the deployment is a Shielded VM, so this constraint is fine either way.")
        elif res.denied:
            self.org_skip = True
        self.check_list_policy(
            "compute.trustedImageProjects", "images from any project are allowed.",
            "needs", "fundamental-public", "projects/fundamental-public is not in the allowed image projects",
            "The sealed tiers boot Fundamental's hardened image from projects/fundamental-public. Ask your org admin to allow it.",
        )
        self.check_list_policy(
            "compute.disablePrivateServiceConnectCreationForConsumers", "PSC consumer endpoints are allowed.",
            "denies", "SERVICE_PRODUCERS", "endpoints to service producers are disabled",
            "The deployment creates a PSC endpoint to Fundamental's attestation broker. Ask your org admin for an exception on this project.",
        )
        self.check_list_policy(
            "compute.restrictPrivateServiceConnectProducer", "connecting to any PSC producer is allowed.",
            "needs", "fun-marketplace-prod", "Fundamental's project fun-marketplace-prod is not an allowed producer",
            "The attestation endpoint connects to a service attachment in Fundamental's project fun-marketplace-prod. Ask your org admin to allow it.",
        )
        if self.exposure:
            self.check_list_policy(
                "compute.restrictPrivateServiceConnectConsumer", "any consumer may connect to your edge service attachment.",
                "denies", ".", "consumers are restricted",
                "Your consumer project(s) must be allowed to connect to the edge service attachment.",
            )
        self.check_list_policy(
            "iam.allowedPolicyMemberDomains", "principals from any domain may be granted roles.",
            "denies", ".", "no external principal may be granted a role",
            "The deployment binds Fundamental's attestation broker service account (an external principal) to a custom role with one permission, "
            "compute.instances.getShieldedInstanceIdentity. Ask your org admin for an exception on this project, or ask Fundamental.",
        )
        self.check_list_policy(
            "gcp.resourceLocations", "resources may be created in any location.",
            "denies", f"in:(us|global)-locations|{re.escape(self.region)}", "a location the deployment uses is denied",
            f"The deployment creates resources in {self.region}, us-central1 (attestation endpoint), {self.gpu_region} (GPU tier) and the multi-region "
            f"{self.tv.get('storage_location', 'US')} (buckets, key ring). Make sure all are allowed.",
        )
        self.check_list_policy(
            "gcp.restrictNonCmekServices", "services without CMEK are allowed.",
            "denies", "artifactregistry|secretmanager", "a service the deployment uses without CMEK is denied",
            "Buckets, GKE secrets and disks use your own KMS keys; Artifact Registry and Secret Manager do not. Ask your org admin for an exception.",
        )
        self.check_list_policy(
            "compute.vmExternalIpAccess", "irrelevant here: the deployment creates no external IP addresses.",
            "denies", "^$", "",
            "The deployment creates no external IP addresses, so this constraint does not affect it.",
        )
        if self.org_skip:
            r.skip("Organization policy constraints", "orgpolicy.policy.get on the project (roles/orgpolicy.policyViewer)")

    # ------------------------------------------------------------ 14. Not checked by this script
    def check_manual(self) -> None:
        r, tv = self.r, self.tv
        r.section("Confirm yourself")
        number = f" ({self.project_number})" if self.project_number else ""
        r.info(f"Fundamental confirmed your project ID, project number{number} and region: bundle bucket, hardened image and attestation broker access.")
        if not tv.is_set("existing_network.network"):
            r.info(
                f"The VPC ranges ({tv.get('vpc_cidr', '10.0.0.0/16')}, control plane {tv.get('gke_master_ipv4_cidr', '172.16.0.0/28')}) "
                "do not overlap a network you will peer or connect from."
            )
        if self.exposure:
            r.info("You own DNS for the exposed hosts and can create A records after the deployment.")

    # ------------------------------------------------------------ Summary
    def summary(self) -> int:
        r = self.r
        r.section("Summary")
        print(f"  Passed: {r.n_pass}   Failed: {r.n_fail}   Warnings: {r.n_warn}   Not checked: {r.n_skip}")
        if r.n_skip:
            print()
            print("  Checks your account could not run. Ask a project owner to run this script,")
            print("  or verify these another way:")
            for line in r.skipped:
                print(line)
        print()
        if r.n_fail:
            print(f"  {r.c_fail}Fix the FAIL items before you deploy.{r.off}")
            return 1
        if r.n_warn or r.n_skip:
            print(f"  {r.c_warn}No failures. Review the WARN and SKIP items, then deploy.{r.off}")
            return 0
        print(f"  {r.c_pass}All checks passed. You can deploy.{r.off}")
        return 0

    def run(self) -> int:
        self.check_signin()
        self.check_project()
        self.check_apis()
        self.check_deployer()
        self.check_permissions()
        self.check_tools()
        self.check_onboarding()
        self.check_regions()
        self.check_capacity()
        self.check_state()
        self.check_network()
        self.check_exposure()
        self.check_org_policies()
        self.check_manual()
        return self.summary()


# ---------------------------------------------------------------- cli
def parse_args(argv: list) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="preflight.py",
        description="Checks that your Google Cloud project is ready for the Fundamental Platform. The script is read-only.",
        epilog="Examples:\n  python3 preflight.py -p my-project -s fundamental-deployer@my-project.iam.gserviceaccount.com\n"
        "  python3 preflight.py -t terraform/my-deployment.tfvars",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "-p", "--project", metavar="<project-id>", default="",
        help="Project you deploy into (default: project_id from the tfvars file, else the current gcloud project)",
    )
    parser.add_argument(
        "-s", "--service-account", metavar="<account>", default="",
        help="The deployer service account the deployment runs as (default: deployer_service_account from the tfvars file). "
        'Every check from "Deployer service account" on runs as it.',
    )
    parser.add_argument(
        "-t", "--tfvars", metavar="<file>", default="",
        help="Your terraform/<name>.tfvars. Enables exact checks for region, zones, bundle, image, "
        "existing network and customer exposure. Without it the template defaults are checked.",
    )
    return parser.parse_args(argv)


def main(argv: list) -> int:
    args = parse_args(argv)
    tv = Tfvars({})
    if args.tfvars:
        if not os.path.isfile(args.tfvars):
            print(f"tfvars file not found: {args.tfvars}")
            return 2
        try:
            tv = Tfvars.load(args.tfvars)
        except (TfvarsError, OSError, UnicodeDecodeError) as e:
            print(f"Cannot read {args.tfvars}. {e}")
            return 2

    print("Fundamental Platform - GCP prerequisite check (read-only)")
    if tv.loaded:
        print(f"tfvars: {tv.path}")
    else:
        print("No tfvars file given. The checks use the template defaults for region and zones. "
              "Pass -t terraform/<name>.tfvars for exact checks.")

    report = Report()
    exe = shutil.which("gcloud")
    if not exe:
        report.section("gcloud and sign-in")
        report.fail("gcloud is not installed.", "Install the Google Cloud CLI: https://cloud.google.com/sdk/docs/install")
        return 1
    return Preflight(report, Gcloud(exe), tv, args.project, args.service_account).run()


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except KeyboardInterrupt:
        print()
        sys.exit(130)
