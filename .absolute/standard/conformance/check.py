#!/usr/bin/env python3
"""Check a repository against the Absolute engineering standard.

The standard (../STANDARD.md) states obligations; a repository states how it
meets them in `.absolute/policy.yml`. This program compares the two, and
compares both against what is actually in the repository.

It fails a repository whose policy is missing, invalid, weaker than the security
baseline, or contradicted by the repository itself. It is deliberately
tool-agnostic: the only things it assumes are a filesystem and, where they
exist, GitHub Actions workflow files.

    python3 conformance/check.py --repo /path/to/repo

Exit status is 0 when every check passes, 1 otherwise.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import pathlib
import re
import sys

try:
    import yaml
except ImportError:  # pragma: no cover - the workflow installs it
    sys.exit("conformance check needs PyYAML: pip install pyyaml")

POLICY_PATH = ".absolute/policy.yml"
BASE_IMAGES_PATH = "security/base-images.yml"

REQUIRED_TOP_LEVEL = ("project", "standard_version", "audience", "contract", "tiers", "security")

# Clause 2.1: a contributor gets a signal in under a minute, nothing merges on
# the fast tier alone, and expensive work is scheduled.
REQUIRED_TIER_GATES = {"push", "merge", "release"}

# A pinned GitHub Action reference: 40 hex characters, never a tag.
SHA_PIN = re.compile(r"@[0-9a-f]{40}\s*(#.*)?$")

# `FROM image[:tag][@sha256:...] [AS stage]`
FROM_LINE = re.compile(r"^\s*FROM\s+(?P<ref>\S+)(?:\s+[Aa][Ss]\s+(?P<stage>\S+))?", re.MULTILINE)
DIGEST_PIN = re.compile(r"@sha256:[0-9a-f]{64}$")

# High-signal only. A noisy secret scanner gets muted, and a muted control is
# not a control (clause 1.3).
SECRET_PATTERNS = (
    (re.compile(r"-----BEGIN (RSA|OPENSSH|DSA|EC|PGP) PRIVATE KEY-----"), "private key block"),
    (re.compile(r"\bghp_[A-Za-z0-9]{36}\b"), "GitHub personal access token"),
    (re.compile(r"\bgithub_pat_[A-Za-z0-9_]{22,}\b"), "GitHub fine-grained token"),
    (re.compile(r"\bAKIA[0-9A-Z]{16}\b"), "AWS access key id"),
    (re.compile(r"\bxox[abprs]-[A-Za-z0-9-]{10,}\b"), "Slack token"),
)

SKIP_DIRS = {".git", "node_modules", ".venv", "venv", "build", "dist", ".dart_tool"}

# A scanner with no escape hatch is a scanner that gets switched off. This one
# is explicit, greppable and reviewed in the PR that adds it.
ALLOW_SECRET_MARKER = "absolute-conformance:allow-secret"


class Result:
    """Collects findings so every problem is reported, not just the first."""

    def __init__(self) -> None:
        self.failures: list[tuple[str, str]] = []
        self.passes: list[str] = []

    def ok(self, clause: str) -> None:
        self.passes.append(clause)

    def fail(self, clause: str, detail: str) -> None:
        self.failures.append((clause, detail))

    def check(self, clause: str, condition: bool, detail: str) -> bool:
        if condition:
            self.ok(clause)
        else:
            self.fail(clause, detail)
        return condition


def load_yaml(path: pathlib.Path) -> object:
    with path.open(encoding="utf-8") as handle:
        return yaml.safe_load(handle)


def iter_files(repo: pathlib.Path):
    for path in repo.rglob("*"):
        if not path.is_file():
            continue
        if any(part in SKIP_DIRS for part in path.relative_to(repo).parts):
            continue
        yield path


# ---------------------------------------------------------------------------
# Policy shape
# ---------------------------------------------------------------------------
def check_policy_shape(policy: dict, standard_version: str, result: Result) -> None:
    for key in REQUIRED_TOP_LEVEL:
        result.check("7.1", key in policy, f"policy is missing `{key}`")

    declared = str(policy.get("standard_version", ""))
    result.check(
        "7.3",
        declared == standard_version,
        f"policy pins standard {declared or '(none)'}, this standard is {standard_version}",
    )

    audience = policy.get("audience")
    result.check(
        "4.1",
        isinstance(audience, str) and len(audience.strip()) > 10,
        "policy must name the least experienced person who will use this, in a sentence",
    )

    contract = policy.get("contract")
    result.check(
        "1.5",
        isinstance(contract, list) and len(contract) > 0,
        "policy must list what outside code depends on (`contract`)",
    )


def check_tiers(policy: dict, repo: pathlib.Path, result: Result) -> None:
    tiers = policy.get("tiers")
    if not isinstance(tiers, dict) or not tiers:
        result.fail("2.1", "policy must define test tiers under `tiers`")
        return

    gates_seen: set[str] = set()
    for name, tier in tiers.items():
        if not isinstance(tier, dict):
            result.fail("2.1", f"tier `{name}` must be a mapping with `gates` and `command`")
            continue

        gate = tier.get("gates")
        command = tier.get("command")
        if gate:
            gates_seen.add(str(gate))
        result.check("2.1", bool(gate), f"tier `{name}` must say what it gates")
        result.check(
            "2.2",
            isinstance(command, str) and command.strip() != "",
            f"tier `{name}` must give the one command that runs it locally",
        )

    missing = REQUIRED_TIER_GATES - gates_seen
    result.check(
        "2.1",
        not missing,
        f"no tier gates {', '.join(sorted(missing))} (a tier's `gates` must be one of "
        f"{', '.join(sorted(REQUIRED_TIER_GATES))})",
    )

    coverage = policy.get("coverage_floor")
    if coverage is not None:
        result.check(
            "2.4",
            isinstance(coverage, (int, float)) and 0 <= coverage <= 100,
            "`coverage_floor` must be a percentage",
        )


# ---------------------------------------------------------------------------
# Security layers
# ---------------------------------------------------------------------------
def normalise_requirement(value: object) -> dict:
    """Accept the shorthand `requirement: path/to/evidence`."""
    if isinstance(value, str):
        return {"status": "met", "verified_by": value}
    if isinstance(value, dict):
        return value
    return {}


def check_evidence(repo: pathlib.Path, entry: dict, clause: str, subject: str, result: Result) -> None:
    """Evidence is a path in this repository, or a link to the control that
    enforces it elsewhere.

    Some controls genuinely do not live in the repository they protect: branch
    protection, secret scanning and required checks are org-level settings
    applied from the governance repository. Naming a file that does not enforce
    them would be worse than linking the thing that does, so a URL is accepted
    and must say, in `reason`, which control it points at.
    """
    evidence = entry.get("verified_by")
    if not evidence:
        result.fail(clause, f"{subject} claims `met` with no `verified_by`; a control with no evidence is a claim")
        return

    evidence = str(evidence)
    if evidence.startswith("https://"):
        if not str(entry.get("reason", "")).strip():
            result.fail(
                clause,
                f"{subject} points outside the repository, so it must say in `reason` which "
                "control enforces it",
            )
        else:
            result.ok(f"{clause}.{subject}")
        return

    if not (repo / evidence).exists():
        result.fail(clause, f"{subject} points at `{evidence}`, which does not exist")
    else:
        result.ok(f"{clause}.{subject}")


def exception_ids(policy: dict) -> set[str]:
    return {
        str(item.get("id"))
        for item in policy.get("exceptions") or []
        if isinstance(item, dict) and item.get("id")
    }


def check_security_layers(policy: dict, baseline: dict, repo: pathlib.Path, result: Result) -> None:
    security = policy.get("security")
    if not isinstance(security, dict):
        result.fail("6", "policy must have a `security` section")
        return

    layers = security.get("layers")
    if not isinstance(layers, dict):
        result.fail("6", "policy must declare `security.layers`")
        return

    conditional = set(baseline.get("conditionally_applicable") or [])
    known_exceptions = exception_ids(policy)

    for layer_id, layer_spec in baseline["layers"].items():
        declared = layers.get(layer_id)
        if not isinstance(declared, dict):
            result.fail(
                f"6/{layer_id}",
                f"layer {layer_id} ({layer_spec['name']}) is not declared; a project may add to a "
                "layer but never drop one",
            )
            continue

        requirements = declared.get("requirements") or {}
        if not isinstance(requirements, dict):
            result.fail(f"6/{layer_id}", f"{layer_id}.requirements must be a mapping")
            continue

        for requirement in layer_spec["requires"]:
            entry = normalise_requirement(requirements.get(requirement))
            status = entry.get("status")

            if status is None:
                result.fail(
                    f"6/{layer_id}",
                    f"{layer_id}.{requirement} is not addressed (state `met`, or "
                    "`not_applicable` with a reason where the baseline allows it)",
                )
                continue

            if status == "met":
                check_evidence(repo, entry, f"6/{layer_id}", f"{layer_id}.{requirement}", result)
                continue

            if status == "not_applicable":
                if requirement not in conditional:
                    result.fail(
                        f"6/{layer_id}",
                        f"{layer_id}.{requirement} is unconditional in the baseline and cannot be "
                        "marked not_applicable",
                    )
                elif not str(entry.get("reason", "")).strip():
                    result.fail(
                        f"6/{layer_id}",
                        f"{layer_id}.{requirement} is not_applicable without a reason",
                    )
                else:
                    result.ok(f"6/{layer_id}.{requirement}")
                continue

            if status == "exception":
                # An unmet MUST is not waived, it is tracked and it expires.
                # check_exceptions() fails the run once the date passes.
                name = str(entry.get("exception", ""))
                if not name:
                    result.fail(
                        f"6/{layer_id}",
                        f"{layer_id}.{requirement} is an exception with no `exception:` id",
                    )
                elif name not in known_exceptions:
                    result.fail(
                        f"6/{layer_id}",
                        f"{layer_id}.{requirement} cites exception `{name}`, which is not in "
                        "`exceptions`",
                    )
                else:
                    result.ok(f"6/{layer_id}.{requirement}")
                continue

            result.fail(
                f"6/{layer_id}",
                f"{layer_id}.{requirement} has unknown status `{status}`; the baseline is a floor, "
                "so `met`, `not_applicable` and a tracked `exception` are the only answers",
            )

        # Local controls, which may only add.
        for control in declared.get("controls") or []:
            if not isinstance(control, dict):
                result.fail(f"6/{layer_id}", "each local control must be a mapping")
                continue
            control_id = control.get("id", "(unnamed)")
            check_evidence(repo, control, f"6/{layer_id}", f"local control `{control_id}`", result)


def check_no_waivers(policy: dict, result: Result) -> None:
    """Clause 6: nothing in the baseline may be weakened locally."""
    serialised = yaml.safe_dump(policy)
    for forbidden in ("waives:", "waived:", "baseline_override", "status: waived"):
        result.check(
            "6",
            forbidden not in serialised,
            f"policy contains `{forbidden}`; the baseline cannot be waived, only added to",
        )


def check_exceptions(policy: dict, today: dt.date, result: Result) -> None:
    for exception in policy.get("exceptions") or []:
        if not isinstance(exception, dict):
            result.fail("7.4", "each exception must be a mapping")
            continue
        name = exception.get("id", "(unnamed)")
        if not str(exception.get("reason", "")).strip():
            result.fail("7.4", f"exception `{name}` has no reason")
        expires = exception.get("expires")
        if expires is None:
            result.fail(
                "7.4",
                f"exception `{name}` has no `expires`; an exception that never ends is a waiver",
            )
            continue
        if isinstance(expires, dt.datetime):
            expires = expires.date()
        if not isinstance(expires, dt.date):
            try:
                expires = dt.date.fromisoformat(str(expires))
            except ValueError:
                result.fail("7.4", f"exception `{name}` has an unreadable expiry `{expires}`")
                continue
        if expires < today:
            result.fail("7.4", f"exception `{name}` expired on {expires.isoformat()}")
        else:
            result.ok(f"7.4/{name}")


def check_base_images(policy: dict, standard: pathlib.Path, repo: pathlib.Path, result: Result) -> None:
    """Clause 6, L3: images start from the approved library, pinned by digest.

    Hardening belongs to the platform, not to each project's memory. A project
    declares which library entry it builds on; the check confirms the entry
    exists, is approved rather than a candidate, and that the build file that
    uses it pins every external base by digest. Choosing a non-hardened entry
    where a hardened one is approved for the same workload class is allowed, and
    must carry the functionality reason that made it necessary.
    """
    build = policy.get("build")
    if not isinstance(build, dict):
        return  # The project builds no image; L3 records that as not_applicable.

    declared = build.get("base_images")
    if not declared:
        return

    catalog = load_yaml(standard / BASE_IMAGES_PATH) or {}
    images = catalog.get("images") or {}

    approved_hardened = {
        entry_id
        for entry_id, entry in images.items()
        if entry.get("hardened") and entry.get("status") == "approved"
    }

    for item in declared:
        if not isinstance(item, dict):
            result.fail("6/L3", "each `build.base_images` entry must be a mapping")
            continue

        entry_id = str(item.get("catalog_id", ""))
        entry = images.get(entry_id)
        if entry is None:
            result.fail(
                "6/L3",
                f"base image `{entry_id or '(none)'}` is not in the approved library "
                f"({BASE_IMAGES_PATH}); add it there first, with a passing suite behind it",
            )
            continue

        status = entry.get("status")
        if status != "approved":
            result.fail(
                "6/L3",
                f"base image `{entry_id}` is `{status}` in the library, not approved; a project "
                "may not ship on it until a real suite has passed on it",
            )
            continue

        used_in = str(item.get("used_in", ""))
        if not used_in:
            result.fail("6/L3", f"base image `{entry_id}` does not say where it is `used_in`")
            continue

        build_file = repo / used_in
        if not build_file.exists():
            result.fail("6/L3", f"base image `{entry_id}` points at `{used_in}`, which does not exist")
            continue

        classes = set(entry.get("workload_classes") or [])
        alternatives = {
            other
            for other in approved_hardened
            if other != entry_id and classes & set(images[other].get("workload_classes") or [])
        }
        if not entry.get("hardened") and alternatives and not str(item.get("reason", "")).strip():
            result.fail(
                "6/L3",
                f"base image `{entry_id}` is not hardened and {', '.join(sorted(alternatives))} is "
                "approved for the same workload; say in `reason` which functionality the hardened "
                "base breaks",
            )
            continue

        stages: set[str] = set()
        for match in FROM_LINE.finditer(build_file.read_text(encoding="utf-8")):
            reference = match.group("ref")
            stage = match.group("stage")
            if reference not in stages and not reference.startswith("$"):
                if not DIGEST_PIN.search(reference):
                    result.fail("3.1", f"{used_in}: `FROM {reference}` is not pinned by digest")
            if stage:
                stages.add(stage)

        result.ok(f"6/L3.base:{entry_id}")


# ---------------------------------------------------------------------------
# What is actually in the repository
# ---------------------------------------------------------------------------
def check_workflows(repo: pathlib.Path, result: Result) -> None:
    workflow_dir = repo / ".github" / "workflows"
    if not workflow_dir.is_dir():
        return  # Clause-neutral: not every project runs on GitHub Actions.

    for workflow in sorted(workflow_dir.glob("*.y*ml")):
        rel = workflow.relative_to(repo)
        text = workflow.read_text(encoding="utf-8")

        for number, line in enumerate(text.splitlines(), start=1):
            stripped = line.strip()
            if not stripped.startswith("- uses:") and not stripped.startswith("uses:"):
                continue
            reference = stripped.split("uses:", 1)[1].strip()
            if reference.startswith("./") or reference.startswith("."):
                continue
            if not SHA_PIN.search(reference):
                result.fail(
                    "3.1",
                    f"{rel}:{number} uses `{reference}`, which is not pinned to a commit SHA",
                )

        try:
            parsed = yaml.safe_load(text)
        except yaml.YAMLError as error:
            result.fail("2.7", f"{rel} is not valid YAML: {error}")
            continue

        if isinstance(parsed, dict):
            result.check(
                "6.4",
                "permissions" in parsed,
                f"{rel} has no top-level `permissions:`; tokens start narrow and widen per job",
            )


def check_secrets(repo: pathlib.Path, result: Result) -> None:
    for path in iter_files(repo):
        try:
            text = path.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue
        for number, line in enumerate(text.splitlines(), start=1):
            if ALLOW_SECRET_MARKER in line:
                continue  # Deliberate: a test fixture or documented example.
            for pattern, label in SECRET_PATTERNS:
                if pattern.search(line):
                    result.fail(
                        "6.1",
                        f"{path.relative_to(repo)}:{number} contains a {label}",
                    )


def check_required_files(repo: pathlib.Path, policy: dict, result: Result) -> None:
    layers = (policy.get("security") or {}).get("layers") or {}

    def status_of(layer: str, requirement: str) -> str:
        entry = normalise_requirement(((layers.get(layer) or {}).get("requirements") or {}).get(requirement))
        return str(entry.get("status", ""))

    if status_of("L7", "security_policy_published") == "met":
        result.check(
            "6/L7",
            (repo / "SECURITY.md").exists() or (repo / ".github" / "SECURITY.md").exists(),
            "SECURITY.md is missing, but the policy claims a published security policy",
        )

    if status_of("L1", "licence_declared") == "met":
        result.check(
            "6/L1",
            any((repo / name).exists() for name in ("LICENSE", "LICENSE.md", "LICENCE", "COPYING")),
            "no LICENSE file, but the policy claims a declared licence",
        )


# ---------------------------------------------------------------------------
def run(repo: pathlib.Path, standard: pathlib.Path, today: dt.date) -> Result:
    result = Result()

    baseline = load_yaml(standard / "security" / "baseline.policy.yml")
    standard_version = (standard / "VERSION").read_text(encoding="utf-8").strip()

    policy_file = repo / POLICY_PATH
    if not policy_file.exists():
        result.fail("7.1", f"{POLICY_PATH} is missing; every repository declares a local policy")
        return result

    try:
        policy = load_yaml(policy_file)
    except yaml.YAMLError as error:
        result.fail("7.1", f"{POLICY_PATH} is not valid YAML: {error}")
        return result

    if not isinstance(policy, dict):
        result.fail("7.1", f"{POLICY_PATH} must be a mapping")
        return result

    check_policy_shape(policy, standard_version, result)
    check_tiers(policy, repo, result)
    check_security_layers(policy, baseline, repo, result)
    check_no_waivers(policy, result)
    check_exceptions(policy, today, result)
    check_base_images(policy, standard, repo, result)
    check_workflows(repo, result)
    check_secrets(repo, result)
    check_required_files(repo, policy, result)
    return result


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default=".", help="repository to check (default: .)")
    parser.add_argument(
        "--standard",
        default=str(pathlib.Path(__file__).resolve().parent.parent),
        help="checkout of the standard (default: alongside this script)",
    )
    parser.add_argument("--format", choices=("text", "json"), default="text")
    args = parser.parse_args(argv)

    repo = pathlib.Path(args.repo).resolve()
    result = run(repo, pathlib.Path(args.standard).resolve(), dt.date.today())

    if args.format == "json":
        print(json.dumps({
            "repo": str(repo),
            "passed": len(result.passes),
            "failures": [{"clause": c, "detail": d} for c, d in result.failures],
        }, indent=2))
    else:
        for clause, detail in result.failures:
            print(f"FAIL  [{clause}] {detail}")
        if result.failures:
            print(f"\n{len(result.failures)} failure(s), {len(result.passes)} check(s) passed")
        else:
            print(f"conformant: {len(result.passes)} check(s) passed")

    return 1 if result.failures else 0


if __name__ == "__main__":
    sys.exit(main())
