"""Validated instance identities and reproducible customization sets."""

from dataclasses import asdict, dataclass
import hashlib
import json
from pathlib import Path, PureWindowsPath
import re
import xml.etree.ElementTree as ET
from zipfile import ZipFile


@dataclass(frozen=True)
class Build:
    release: str
    build: str
    ui: str


def available_builds() -> list[Build]:
    records = json.loads(Path(__file__).with_name("builds.json").read_text())
    builds = [Build(**record) for record in records]
    if not builds or len({b.release for b in builds}) != len(builds) or len({b.build for b in builds}) != len(builds):
        raise ValueError("build presets must have unique releases and exact builds")
    for item in builds:
        if item.release not in ("25r1", "26r1") or item.ui not in ("classic", "modern") or not re.fullmatch(
                item.release[:2] + r"\.1\d{2}\.\d{4}", item.build):
            raise ValueError("unsupported release, UI preset or build in builds.json")
    return builds


def select_build(*, release: str | None = None, build: str | None = None) -> Build:
    if release and build:
        raise ValueError("choose either a release preset or an exact build")
    if not release and not build:
        release = "26r1"
    for item in available_builds():
        if (release and item.release == release) or (build and item.build == build):
            return item
    raise ValueError(f"unsupported build/preset: {build or release}; use the builds command")


def identifier(value: str) -> str:
    if not isinstance(value, str) or not re.fullmatch(r"[a-z][a-z0-9-]{0,23}", value):
        raise ValueError("instance/checkpoint ID must be a lowercase slug of 1 to 24 characters")
    return value


@dataclass(frozen=True)
class Package:
    name: str
    path: str
    sha256: str
    level: int
    dependsOn: list[str]


@dataclass(frozen=True)
class Profile:
    id: str
    application: str
    pool: str
    path: str
    database: str
    build: str
    installerRoot: str
    protected: bool
    packages: list[Package]

    @property
    def host(self) -> str:
        return "127.0.0.1" if self.id == "default" else f"{self.id}.localhost"

    def url(self, port: int = 38121) -> str:
        return f"http://{self.host}:{port}/{self.application}"

    def wire(self) -> dict:
        return asdict(self)


def new_profile(instance_id: str, build: str) -> Profile:
    identifier(instance_id)
    if not isinstance(build, str) or not re.fullmatch(r"\d{2}\.\d{3}\.\d{4}", build):
        raise ValueError("build must be exact, e.g. 26.101.0225")
    select_build(build=build)
    if instance_id == "default":
        raise ValueError("default is reserved for the existing canonical instance")
    name = f"Acu_{instance_id}"
    return Profile(instance_id, name, name, f"D:\\AcumaticaInstances\\{instance_id}",
                   name, build, f"C:\\AcumaticaBuilds\\{build}\\Acumatica ERP", False, [])


def parse_profile(raw: dict) -> Profile:
    if not isinstance(raw, dict) or set(raw) != set(Profile.__dataclass_fields__):
        raise ValueError("profile has missing or unknown fields")
    identifier(raw["id"])
    if type(raw["protected"]) is not bool or not isinstance(raw["packages"], list):
        raise ValueError("protected must be boolean and packages must be an array")
    expected = new_profile(raw["id"], raw["build"]) if raw["id"] != "default" else Profile(
        "default", "AcumaticaERP", "AcumaticaERPAppPool", "C:\\AcumaticaERP",
        "AcumaticaDB", raw["build"], f"C:\\AcumaticaBuilds\\{raw['build']}\\Acumatica ERP", True, [])
    if not isinstance(raw["build"], str) or not re.fullmatch(r"\d{2}\.\d{3}\.\d{4}", raw["build"]):
        raise ValueError("profile build must be exact")
    select_build(build=raw["build"])
    for key, value in expected.wire().items():
        if key != "packages" and raw[key] != value:
            raise ValueError(f"{raw['id']}: {key} must be {value!r}; identities cannot be retargeted")
    packages = []
    for item in raw["packages"]:
        if not isinstance(item, dict) or set(item) != set(Package.__dataclass_fields__):
            raise ValueError("package must contain name, path, sha256, level, dependsOn")
        if not isinstance(item["name"], str) or not re.fullmatch(r"[A-Za-z][A-Za-z0-9_]{0,99}", item["name"]):
            raise ValueError("invalid customization name")
        if not isinstance(item["path"], str) or "\\" in item["path"]:
            raise ValueError("package path must be repository-relative with forward slashes")
        path = Path(item["path"])
        if path.is_absolute() or ".." in path.parts or ":" in item["path"] or path.suffix.lower() != ".zip":
            raise ValueError("package must be a repository-relative ZIP")
        if not isinstance(item["sha256"], str) or not re.fullmatch(r"[a-f0-9]{64}", item["sha256"]):
            raise ValueError("package needs a pinned lowercase SHA256")
        if type(item["level"]) is not int or not 0 <= item["level"] <= 2_147_483_647:
            raise ValueError("package level must be a nonnegative integer")
        if not isinstance(item["dependsOn"], list) or any(not isinstance(x, str) for x in item["dependsOn"]):
            raise ValueError("dependsOn must be an array of project names")
        packages.append(Package(**item))
    profile = Profile(**{**raw, "packages": packages})
    ordered_packages(profile)
    if profile.protected and packages:
        raise ValueError("default is inventory-only; develop and publish in a named instance")
    return profile


def load_catalog(directory: Path) -> dict[str, Profile]:
    profiles = {}
    identities: dict[tuple[str, str], str] = {}
    for path in sorted(directory.glob("*.json")):
        profile = parse_profile(json.loads(path.read_text()))
        if path.stem != profile.id or profile.id in profiles:
            raise ValueError(f"profile filename/ID mismatch or duplicate: {path}")
        for field in ("application", "pool", "path", "database"):
            value = str(getattr(profile, field)).casefold().rstrip("\\")
            key = field, value
            if key in identities:
                raise ValueError(f"{field} shared by {profile.id} and {identities[key]}")
            identities[key] = profile.id
        profiles[profile.id] = profile
    if "default" not in profiles:
        raise ValueError("canonical default profile is missing")
    return profiles


def ordered_packages(profile: Profile) -> list[Package]:
    packages = {p.name: p for p in profile.packages}
    if len({p.name.casefold() for p in profile.packages}) != len(profile.packages):
        raise ValueError("duplicate customization name")
    ordered: list[Package] = []
    active: set[str] = set()
    done: set[str] = set()

    def visit(name: str) -> None:
        if name not in packages:
            raise ValueError(f"missing prerequisite {name}")
        if name in active:
            raise ValueError(f"dependency cycle at {name}")
        if name in done:
            return
        active.add(name)
        for dependency in packages[name].dependsOn:
            visit(dependency)
        active.remove(name)
        done.add(name)
        ordered.append(packages[name])

    for name in packages:
        visit(name)
    return ordered


def verify_packages(profile: Profile, repo: Path) -> list[dict]:
    result = []
    for package in ordered_packages(profile):
        path = (repo / package.path).resolve(strict=True)
        if not path.is_relative_to(repo.resolve()):
            raise ValueError(f"package escapes the shared repository: {package.path}")
        with path.open("rb") as stream:
            digest = hashlib.file_digest(stream, "sha256").hexdigest()
        if digest != package.sha256:
            raise ValueError(f"package changed: {package.path}; rebuild and update its pinned SHA256")
        with ZipFile(path) as archive:
            info = archive.getinfo("project.xml")
            if info.file_size > 32 * 1024 * 1024:
                raise ValueError("project.xml exceeds 32 MiB")
            root = ET.fromstring(archive.read(info))
            if root.tag != "Customization":
                raise ValueError(f"not an Acumatica customization: {path}")
            if int(root.get("level") or "0") != package.level:
                raise ValueError(f"{package.name}: profile level differs from the package's embedded level")
            for member in archive.namelist():
                target = PureWindowsPath(member)
                if target.is_absolute() or target.drive or ".." in target.parts or ":" in member:
                    raise ValueError(f"unsafe ZIP member: {member}")
        result.append({**asdict(package), "guestPath": "C:\\Acumatica-ERP\\" + package.path.replace("/", "\\")})
    return result
