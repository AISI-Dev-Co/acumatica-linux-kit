#!/usr/bin/env python3

"""Agent-friendly CLI wrapper for Acuminator.

This tool wraps ``Acuminator.Runner.NetFramework.exe`` and emits a stable JSON
envelope that is easier for automation agents to consume.
"""

from __future__ import annotations

import argparse
import dataclasses
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from collections import Counter
from pathlib import Path
from typing import Any, Iterable


EXIT_STATUS = {
    0: "success",
    1: "requirements-not-met",
    2: "cancelled",
    4: "runtime-error",
}
DEFAULT_CODE_SOURCE_ALIASES = {"repo", "coderepository", "default", "."}

LINE_PREFIX_RE = re.compile(
    r'^(?:\[(?P<severity>[^\]]+)\]\s+)?(?P<diagnostic_id>[^:]+):\s(?P<rest>.+)$'
)
QUOTED_LOCATION_RE = re.compile(r'^(?P<message>.*):\s"(?P<raw_location>.+)"$')
LOCATION_PATTERNS = (
    re.compile(
        r"^(?P<path>.+): \((?P<start_line>\d+),(?P<start_column>\d+)\)-\((?P<end_line>\d+),(?P<end_column>\d+)\)$"
    ),
    re.compile(
        r"^(?P<path>.+)\((?P<start_line>\d+),(?P<start_column>\d+),(?P<end_line>\d+),(?P<end_column>\d+)\)$"
    ),
    re.compile(
        r"^(?P<path>.+)\((?P<start_line>\d+),(?P<start_column>\d+)\)$"
    ),
)
SOLUTION_PROJECT_PATH_RE = re.compile(
    r'^(Project\([^\n]+?=\s+"[^"]+",\s+")(?P<path>[^"]+)("\s*,\s*"\{[A-F0-9\-]+\}")$',
    re.IGNORECASE,
)


@dataclasses.dataclass(frozen=True)
class PreparedCodeSource:
    original_path: Path
    effective_path: Path
    path_rewrites: tuple[tuple[str, str], ...] = ()


def workspace_root() -> Path:
    return Path(__file__).resolve().parents[2]


def acuminator_root() -> Path:
    return Path(__file__).resolve().parent / "Acuminator"


def find_default_code_source(search_from: Path | None = None) -> Path | None:
    start = make_absolute_path(search_from or Path.cwd())

    for candidate_root in (start, *start.parents):
        repo_candidate = candidate_root / "AcumaticaERP" / "App_Data" / "CodeRepository" / "CodeRepository.csproj"
        if repo_candidate.is_file():
            return repo_candidate

        direct_candidate = candidate_root / "App_Data" / "CodeRepository" / "CodeRepository.csproj"
        if direct_candidate.is_file():
            return direct_candidate

    fallback_candidate = workspace_root() / "AcumaticaERP" / "App_Data" / "CodeRepository" / "CodeRepository.csproj"
    if fallback_candidate.is_file():
        return fallback_candidate

    return None


def resolve_code_source(raw_code_source: str | None) -> Path:
    if raw_code_source is None or raw_code_source.lower() in DEFAULT_CODE_SOURCE_ALIASES:
        default_code_source = find_default_code_source()
        if default_code_source:
            return make_absolute_path(default_code_source)

        raise RuntimeError(
            "Could not determine a default code source. Pass a .csproj/.sln path explicitly or run from the Acumatica repo."
        )

    requested = Path(raw_code_source).expanduser()
    absolute_requested = make_absolute_path(requested)

    if absolute_requested.is_dir():
        default_code_source = find_default_code_source(absolute_requested)
        if default_code_source:
            return make_absolute_path(default_code_source)

        raise RuntimeError(f"Could not find CodeRepository.csproj under {absolute_requested}.")

    return absolute_requested


def make_absolute_path(path: Path) -> Path:
    if os.name == "nt":
        return Path(os.path.abspath(os.fspath(path)))

    return path.resolve()


def find_runner(explicit_runner: str | None) -> Path | None:
    candidates: list[Path] = []

    if explicit_runner:
        candidates.append(Path(explicit_runner).expanduser())

    env_runner = os.environ.get("ACUMINATOR_RUNNER")
    if env_runner:
        candidates.append(Path(env_runner).expanduser())

    root = acuminator_root()
    candidates.extend(
        [
            root / "src/Acuminator/Acuminator.Runner.NetFramework/bin/Debug/Acuminator.Runner.NetFramework.exe",
            root / "src/Acuminator/Acuminator.Runner.NetFramework/bin/Release/Acuminator.Runner.NetFramework.exe",
            root / "src/Acuminator/Acuminator.Runner.NetFramework/bin/Debug/net48/Acuminator.Runner.NetFramework.exe",
            root / "src/Acuminator/Acuminator.Runner.NetFramework/bin/Release/net48/Acuminator.Runner.NetFramework.exe",
        ]
    )

    which_runner = shutil.which("Acuminator.Runner.NetFramework.exe")
    if which_runner:
        candidates.append(Path(which_runner))

    for candidate in candidates:
        resolved = make_absolute_path(candidate)
        if resolved.is_file():
            return resolved

    return None


def find_msbuild_path(explicit_msbuild_path: str | None) -> Path | None:
    candidates: list[Path] = []

    if explicit_msbuild_path:
        candidates.append(Path(explicit_msbuild_path).expanduser())

    env_msbuild = os.environ.get("ACUMINATOR_MSBUILD_PATH")
    if env_msbuild:
        candidates.append(Path(env_msbuild).expanduser())

    if os.name != "nt":
        for command_name in ("msbuild", "xbuild"):
            discovered = shutil.which(command_name)
            if discovered:
                candidates.append(Path(discovered))

    for candidate in candidates:
        resolved = make_absolute_path(candidate)
        if resolved.is_file():
            return resolved

    return None


def build_process_command(runner: Path, runner_args: list[str], launcher: str | None) -> list[str]:
    if launcher:
        return [launcher, str(runner), *runner_args]

    if os.name != "nt" and runner.suffix.lower() == ".exe":
        mono = shutil.which("mono")
        if mono:
            return [mono, str(runner), *runner_args]

    return [str(runner), *runner_args]


def iter_msbuild_probe_dirs(msbuild_path: Path | None) -> Iterable[Path]:
    if not msbuild_path:
        return

    yield msbuild_path.parent

    try:
        content = msbuild_path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        content = None

    if content:
        for match in re.finditer(r"(/[^\"'\s]*?/MSBuild\.dll)", content):
            yield Path(match.group(1)).parent

    for candidate in (
        Path("/usr/lib/mono/msbuild/Current/bin"),
        Path("/usr/lib/mono/msbuild/15.0/bin"),
    ):
        if candidate.is_dir():
            yield candidate


def build_process_env(runner: Path, msbuild_path: Path | None) -> dict[str, str]:
    env = os.environ.copy()

    if os.name == "nt":
        return env

    probe_paths: list[str] = [str(runner.parent)]

    if msbuild_path:
        probe_paths.extend(str(path) for path in iter_msbuild_probe_dirs(msbuild_path))

    existing_mono_path = env.get("MONO_PATH")
    if existing_mono_path:
        probe_paths.append(existing_mono_path)

    env["MONO_PATH"] = os.pathsep.join(dict.fromkeys(path for path in probe_paths if path))
    return env


def iter_report_lines(report_group: dict[str, Any] | None) -> Iterable[str]:
    if not report_group:
        return

    for line in report_group.get("lines") or []:
        if isinstance(line, str) and line:
            yield line

    for child in report_group.get("childrenGroups") or []:
        if isinstance(child, dict):
            yield from iter_report_lines(child)


def parse_location(raw_location: str | None) -> dict[str, Any]:
    parsed: dict[str, Any] = {
        "rawLocation": raw_location,
        "path": None,
        "startLine": None,
        "startColumn": None,
        "endLine": None,
        "endColumn": None,
    }

    if not raw_location:
        return parsed

    for pattern in LOCATION_PATTERNS:
        match = pattern.match(raw_location)
        if not match:
            continue

        parsed["path"] = match.group("path")
        parsed["startLine"] = int(match.group("start_line"))
        parsed["startColumn"] = int(match.group("start_column"))

        end_line = match.groupdict().get("end_line")
        end_column = match.groupdict().get("end_column")
        parsed["endLine"] = int(end_line) if end_line else parsed["startLine"]
        parsed["endColumn"] = int(end_column) if end_column else parsed["startColumn"]
        return parsed

    parsed["path"] = raw_location
    return parsed


def parse_diagnostic_line(line: str, project_name: str) -> dict[str, Any]:
    line_match = LINE_PREFIX_RE.match(line)
    if not line_match:
        return {
            "projectName": project_name,
            "severity": None,
            "diagnosticId": None,
            "message": line,
            "rawLine": line,
            "rawLocation": None,
            "path": None,
            "startLine": None,
            "startColumn": None,
            "endLine": None,
            "endColumn": None,
        }

    rest = line_match.group("rest")
    quoted_location_match = QUOTED_LOCATION_RE.match(rest)
    message = quoted_location_match.group("message") if quoted_location_match else rest
    raw_location = quoted_location_match.group("raw_location") if quoted_location_match else None
    parsed_location = parse_location(raw_location)

    return {
        "projectName": project_name,
        "severity": line_match.group("severity"),
        "diagnosticId": line_match.group("diagnostic_id"),
        "message": message,
        "rawLine": line,
        **parsed_location,
    }


def flatten_diagnostics(report: dict[str, Any]) -> list[dict[str, Any]]:
    diagnostics: list[dict[str, Any]] = []

    for project_report in report.get("projectReports") or []:
        project_name = project_report.get("projectName")
        report_details = project_report.get("reportDetails")
        for line in iter_report_lines(report_details):
            diagnostics.append(parse_diagnostic_line(line, project_name))

    return diagnostics


def build_summary(report: dict[str, Any], diagnostics: list[dict[str, Any]]) -> dict[str, Any]:
    severity_counts = Counter(diagnostic.get("severity") or "Unknown" for diagnostic in diagnostics)
    distinct_ids = sorted(
        {
            diagnostic["diagnosticId"]
            for diagnostic in diagnostics
            if diagnostic.get("diagnosticId")
        }
    )

    return {
        "codeSourceName": report.get("codeSourceName"),
        "projectCount": len(report.get("projectReports") or []),
        "totalDiagnostics": report.get("totalDiagnosticsCount", len(diagnostics)),
        "distinctDiagnosticIds": distinct_ids,
        "countsBySeverity": dict(sorted(severity_counts.items())),
    }


def describe_payload() -> dict[str, Any]:
    return {
        "tool": "acuminator-agent",
        "schemaVersion": 1,
        "commands": {
            "describe": {
                "description": "Describe this wrapper and its JSON contract.",
            },
            "analyze": {
                "description": "Run Acuminator and emit an agent-friendly JSON envelope.",
                "requiredArguments": [],
                "defaultCodeSource": "If omitted, or if set to repo/coderepository/default/., the wrapper searches upward for AcumaticaERP/App_Data/CodeRepository/CodeRepository.csproj.",
                "defaultRunnerBehavior": {
                    "format": "json",
                    "nonInteractive": True,
                    "absolutePaths": True,
                    "verbosity": "Error",
                },
            },
        },
        "runnerDiscovery": [
            "--runner",
            "ACUMINATOR_RUNNER",
            "repo-local build output",
            "PATH",
        ],
        "msbuildDiscovery": [
            "--msbuild-path",
            "ACUMINATOR_MSBUILD_PATH",
            "PATH (msbuild/xbuild on non-Windows)",
        ],
        "exitCodes": EXIT_STATUS,
        "analyzeOutput": {
            "status": "One of success, requirements-not-met, cancelled, runtime-error, or unknown.",
            "summary": "High-level counts for projects and diagnostics.",
            "diagnostics": "Flat diagnostic list with message, severity, id, projectName, and best-effort file location parsing.",
            "runner": "Runner path, invocation, and optional captured stdout/stderr.",
        },
    }


def emit_json(payload: dict[str, Any]) -> None:
    json.dump(payload, sys.stdout, indent=2)
    sys.stdout.write("\n")


def is_acumatica_code_repository_project(code_source: Path) -> bool:
    if code_source.name.lower() != "coderepository.csproj":
        return False

    normalized_parts = {part.lower() for part in code_source.parts}
    return "app_data" in normalized_parts and "coderepository" in normalized_parts


def find_ancestor_named(path: Path, expected_name: str) -> Path | None:
    expected_name_lower = expected_name.lower()

    for candidate in (path, *path.parents):
        if candidate.name.lower() == expected_name_lower:
            return candidate

    return None


def create_symlink(link_path: Path, target_path: Path) -> None:
    if link_path.exists() or link_path.is_symlink():
        return

    os.symlink(os.fspath(target_path), os.fspath(link_path), target_is_directory=target_path.is_dir())


def write_shadow_props(shadow_root: Path, packages_path: Path) -> None:
    props_path = shadow_root / "Directory.Build.props"
    props_path.write_text(
        "\n".join(
            [
                "<Project>",
                "  <PropertyGroup>",
                "    <NuGetAudit>false</NuGetAudit>",
                f"    <RestorePackagesPath>{packages_path}</RestorePackagesPath>",
                "  </PropertyGroup>",
                "</Project>",
                "",
            ]
        ),
        encoding="utf-8",
    )


def restore_shadow_project(project_path: Path) -> None:
    dotnet = shutil.which("dotnet")
    if not dotnet:
        raise RuntimeError("Could not find dotnet required to restore the Acumatica shadow project.")

    completed = subprocess.run(
        [dotnet, "restore", str(project_path), "--verbosity", "quiet"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )

    if completed.returncode == 0:
        return

    details = completed.stderr.strip() or completed.stdout.strip() or "dotnet restore failed."
    raise RuntimeError(f"Failed to restore the Acumatica shadow project: {details}")


def prepare_solution_for_non_windows(code_source: Path, workspace_dir: Path) -> PreparedCodeSource:
    shadow_solution_path = workspace_dir / code_source.name
    rewritten_lines: list[str] = []

    for line in code_source.read_text(encoding="utf-8").splitlines():
        match = SOLUTION_PROJECT_PATH_RE.match(line)
        if not match:
            rewritten_lines.append(line)
            continue

        project_path = Path(match.group("path").replace("\\", "/"))
        if not project_path.is_absolute():
            project_path = (code_source.parent / project_path).resolve()
        normalized_path = project_path.as_posix()
        rewritten_lines.append(f"{match.group(1)}{normalized_path}{match.group(3)}")

    shadow_solution_path.write_text("\n".join(rewritten_lines) + "\n", encoding="utf-8")
    return PreparedCodeSource(original_path=code_source, effective_path=shadow_solution_path)


def prepare_acumatica_code_repository_project(code_source: Path, workspace_dir: Path) -> PreparedCodeSource:
    app_root = find_ancestor_named(code_source.parent, "AcumaticaERP")
    if app_root is None:
        raise RuntimeError(f"Could not find the AcumaticaERP root for {code_source}.")

    real_bin_dir = app_root / "Bin"
    if not real_bin_dir.is_dir():
        raise RuntimeError(f"Could not find the Acumatica Bin directory at {real_bin_dir}.")

    shadow_root = workspace_dir / "acumatica-shadow"
    shadow_project_dir = shadow_root / "App_Data" / "CodeRepository"
    shadow_site_bin_dir = shadow_root / "App_Data" / "Site" / "Bin"
    shadow_packages_dir = shadow_root / ".nuget" / "packages"
    shadow_project_path = shadow_project_dir / code_source.name

    shadow_project_dir.mkdir(parents=True, exist_ok=True)
    shadow_site_bin_dir.parent.mkdir(parents=True, exist_ok=True)
    shadow_packages_dir.mkdir(parents=True, exist_ok=True)

    write_shadow_props(shadow_root, shadow_packages_dir)
    create_symlink(shadow_site_bin_dir, real_bin_dir)
    shutil.copy2(code_source, shadow_project_path)

    for child in sorted(code_source.parent.iterdir(), key=lambda item: item.name.lower()):
        if child.name == code_source.name or child.name.lower() in {"bin", "obj"}:
            continue

        create_symlink(shadow_project_dir / child.name, child)

    restore_shadow_project(shadow_project_path)

    rewrites = (
        (str(shadow_project_dir), str(code_source.parent)),
        (str(shadow_site_bin_dir), str(real_bin_dir)),
    )
    return PreparedCodeSource(original_path=code_source, effective_path=shadow_project_path, path_rewrites=rewrites)


def prepare_code_source_for_runner(code_source: Path, workspace_dir: Path) -> PreparedCodeSource:
    if is_acumatica_code_repository_project(code_source):
        return prepare_acumatica_code_repository_project(code_source, workspace_dir)

    if os.name != "nt" and code_source.suffix.lower() == ".sln":
        return prepare_solution_for_non_windows(code_source, workspace_dir)

    return PreparedCodeSource(original_path=code_source, effective_path=code_source)


def rewrite_string_paths(text: str, path_rewrites: tuple[tuple[str, str], ...]) -> str:
    rewritten = text

    for old_prefix, new_prefix in path_rewrites:
        rewritten = rewritten.replace(old_prefix, new_prefix)

    return rewritten


def rewrite_paths(value: Any, path_rewrites: tuple[tuple[str, str], ...]) -> Any:
    if not path_rewrites:
        return value

    if isinstance(value, str):
        return rewrite_string_paths(value, path_rewrites)

    if isinstance(value, list):
        return [rewrite_paths(item, path_rewrites) for item in value]

    if isinstance(value, dict):
        return {key: rewrite_paths(item, path_rewrites) for key, item in value.items()}

    return value


def build_failure_guidance(code_source: Path, output_text: str, msbuild_path: Path | None) -> dict[str, Any] | None:
    normalized_output = output_text.lower()
    next_actions: list[str] = []
    summary: str | None = None
    suggested_command: list[str] | None = None

    default_code_source = find_default_code_source(code_source.parent if code_source.is_dir() else code_source.parent)

    if "could not find acuminator.runner.netframework.exe" in normalized_output:
        summary = "The wrapper could not find the Acuminator runner executable."
        next_actions.append("Build Acuminator.Runner.NetFramework.csproj or set ACUMINATOR_RUNNER.")

    elif "no project in the provided" in normalized_output and "references the acumatica framework" in normalized_output:
        summary = "The target loaded, but it is not an Acumatica code source for Acuminator analysis."
        next_actions.append("Analyze a customization project or CodeRepository.csproj instead of the Acuminator solution itself.")
        if default_code_source:
            suggested_command = [
                "python",
                "development/acuminator-vm/acuminator_agent.py",
                "analyze",
                str(default_code_source),
                "--include-runner-output",
            ]

    elif "microsoft.vssdk.targets" in normalized_output or "community.visualstudio.toolkit" in normalized_output:
        summary = "The target solution includes Visual Studio extension projects that are not portable to this environment."
        next_actions.append("Do not analyze the whole Acuminator solution when the real goal is Acumatica source analysis.")
        next_actions.append("Point the wrapper at CodeRepository.csproj or a specific Acumatica customization project.")

    elif ".netframework,version=v4.8" in normalized_output and "were not found" in normalized_output:
        summary = ".NET Framework 4.8 reference assemblies are missing for at least one loaded project."
        if os.name == "nt":
            next_actions.append("Install the .NET Framework 4.8 targeting pack on Windows.")
        else:
            next_actions.append("Avoid loading non-Acumatica solution projects on Linux, or fall back to the Windows VM for that target.")

    elif "could not load file or assembly 'microsoft.build.framework" in normalized_output:
        summary = "Mono could not resolve the MSBuild runtime assemblies needed by Roslyn."
        next_actions.append("Install mono-msbuild and use the wrapper's auto-discovered msbuild path or set ACUMINATOR_MSBUILD_PATH.")
        if msbuild_path:
            next_actions.append(f"Current msbuild path: {msbuild_path}")

    elif "failed to restore the acumatica shadow project" in normalized_output:
        summary = "The wrapper could not restore the temporary shadow project for CodeRepository.csproj."
        next_actions.append("Inspect NuGet restore errors in runner output and verify dotnet restore works on the host.")

    elif "project file not found" in normalized_output:
        summary = "One or more solution project paths could not be resolved in this environment."
        next_actions.append("Prefer analyzing a .csproj directly instead of a broad .sln when working cross-platform.")

    if not summary:
        return None

    return {
        "summary": summary,
        "nextActions": next_actions,
        "suggestedCommand": suggested_command,
    }


def analyze(args: argparse.Namespace) -> int:
    runner = find_runner(args.runner)
    msbuild_path = find_msbuild_path(args.msbuild_path)

    try:
        code_source = resolve_code_source(args.code_source)
    except Exception as exc:
        emit_json(
            {
                "tool": "acuminator-agent",
                "schemaVersion": 1,
                "status": "runtime-error",
                "exitCode": 4,
                "error": {
                    "message": str(exc),
                },
                "guidance": {
                    "summary": "The wrapper could not determine which code source to analyze.",
                    "nextActions": [
                        "Run from the Acumatica repo root to use the default CodeRepository target, or pass a .csproj/.sln path explicitly.",
                    ],
                },
            }
        )
        return 4

    if not runner:
        emit_json(
            {
                "tool": "acuminator-agent",
                "schemaVersion": 1,
                "status": "runtime-error",
                "exitCode": 4,
                "error": {
                    "message": "Could not find Acuminator.Runner.NetFramework.exe. Pass --runner or set ACUMINATOR_RUNNER.",
                },
                "guidance": {
                    "summary": "The Acuminator runner has not been located yet.",
                    "nextActions": [
                        "Build Acuminator.Runner.NetFramework.csproj.",
                        "Set ACUMINATOR_RUNNER or pass --runner if the executable lives outside the default build output.",
                    ],
                },
                "codeSource": str(code_source),
            }
        )
        return 4

    runner_args = [
        str(code_source),
        "--non-interactive",
        "--output-absolute-paths-for-errors",
        "--format",
        "json",
        "--verbosity",
        args.verbosity,
    ]

    if msbuild_path:
        runner_args.extend(["--msBuild-path", str(msbuild_path)])
    if args.disable_suppression:
        runner_args.append("--disable-suppression")
    if args.isv_mode:
        runner_args.append("--isv-mode")
    if args.enable_px1007:
        runner_args.append("--enable-PX1007")
    if args.disable_px1099:
        runner_args.append("--disable-PX1099")
    if args.enable_info_diagnostics:
        runner_args.append("--enable-info-diagnostics")
    if args.banned_apis_path:
        runner_args.extend(["--banned-APIs-path", args.banned_apis_path])
    if args.allowed_apis_path:
        runner_args.extend(["--allowed-APIs-path", args.allowed_apis_path])
    if args.work_mode:
        runner_args.extend(["--work-mode", args.work_mode])

    with tempfile.TemporaryDirectory(prefix="acuminator-agent-") as temp_dir:
        temp_path = Path(temp_dir)

        try:
            prepared_code_source = prepare_code_source_for_runner(code_source, temp_path)
        except Exception as exc:
            emit_json(
                {
                    "tool": "acuminator-agent",
                    "schemaVersion": 1,
                    "status": "runtime-error",
                    "exitCode": 4,
                    "error": {
                        "message": f"Failed to prepare the code source for analysis: {exc}",
                    },
                    "guidance": {
                        "summary": "The wrapper could not prepare the target for Acuminator.",
                        "nextActions": [
                            "Inspect the error message for missing AcumaticaERP/Bin, restore failures, or invalid target paths.",
                        ],
                    },
                    "codeSource": str(code_source),
                }
            )
            return 4

        report_path = temp_path / "report.json"
        runner_args[0] = str(prepared_code_source.effective_path)
        runner_args.extend(["--file", str(report_path)])
        process_command = build_process_command(runner, runner_args, args.launcher)
        process_env = build_process_env(runner, msbuild_path)
        completed = subprocess.run(
            process_command,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=process_env,
            check=False,
        )

        report: dict[str, Any] = {}
        if report_path.is_file() and report_path.stat().st_size > 0:
            report = json.loads(report_path.read_text(encoding="utf-8"))

    report = rewrite_paths(report, prepared_code_source.path_rewrites)
    diagnostics = flatten_diagnostics(report)
    payload: dict[str, Any] = {
        "tool": "acuminator-agent",
        "schemaVersion": 1,
        "status": EXIT_STATUS.get(completed.returncode, "unknown"),
        "exitCode": completed.returncode,
        "codeSource": str(prepared_code_source.original_path),
        "summary": build_summary(report, diagnostics),
        "diagnostics": diagnostics,
        "runner": {
            "path": str(runner),
            "command": process_command,
        },
    }

    if msbuild_path:
        payload["runner"]["msbuildPath"] = str(msbuild_path)

    mono_path = process_env.get("MONO_PATH") if 'process_env' in locals() else None
    if mono_path and os.name != "nt":
        payload["runner"]["monoPath"] = mono_path

    if prepared_code_source.effective_path != prepared_code_source.original_path:
        payload["runner"]["effectiveCodeSource"] = str(prepared_code_source.effective_path)

    if args.include_runner_output:
        payload["runner"]["stdout"] = rewrite_string_paths(completed.stdout, prepared_code_source.path_rewrites)
        payload["runner"]["stderr"] = rewrite_string_paths(completed.stderr, prepared_code_source.path_rewrites)

    if args.include_raw_report:
        payload["rawReport"] = report

    if completed.returncode not in EXIT_STATUS and not report:
        payload["error"] = {
            "message": "Runner returned an unknown exit code and no JSON report was produced.",
        }

    guidance = build_failure_guidance(
        prepared_code_source.original_path,
        f"{completed.stdout}\n{completed.stderr}",
        msbuild_path,
    )
    if guidance and completed.returncode != 0:
        payload["guidance"] = guidance

    emit_json(payload)
    return completed.returncode


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Agent-friendly CLI wrapper for Acuminator.")
    subparsers = parser.add_subparsers(dest="command", required=True)

    describe_parser = subparsers.add_parser("describe", help="Describe the CLI contract.")
    describe_parser.set_defaults(func=lambda _args: (emit_json(describe_payload()) or 0))

    analyze_parser = subparsers.add_parser("analyze", help="Analyze a solution or project with Acuminator.")
    analyze_parser.add_argument(
        "code_source",
        nargs="?",
        help="Optional path to a .csproj or .sln file. Defaults to CodeRepository.csproj when run from the Acumatica repo. Aliases: repo, coderepository, default, .",
    )
    analyze_parser.add_argument("--runner", help="Path to Acuminator.Runner.NetFramework.exe.")
    analyze_parser.add_argument("--launcher", help="Optional launcher command, for example 'mono'.")
    analyze_parser.add_argument("--msbuild-path", help="Optional explicit MSBuild path.")
    analyze_parser.add_argument("--verbosity", default="Error", help="Runner verbosity. Default: Error.")
    analyze_parser.add_argument("--disable-suppression", action="store_true", help="Pass through --disable-suppression.")
    analyze_parser.add_argument("--isv-mode", action="store_true", help="Pass through --isv-mode.")
    analyze_parser.add_argument("--enable-px1007", action="store_true", help="Pass through --enable-PX1007.")
    analyze_parser.add_argument("--disable-px1099", action="store_true", help="Pass through --disable-PX1099.")
    analyze_parser.add_argument("--enable-info-diagnostics", action="store_true", help="Pass through --enable-info-diagnostics.")
    analyze_parser.add_argument("--banned-apis-path", help="Pass through --banned-APIs-path.")
    analyze_parser.add_argument("--allowed-apis-path", help="Pass through --allowed-APIs-path.")
    analyze_parser.add_argument(
        "--work-mode",
        choices=["report-errors", "generate-suppressions", "report-and-generate"],
        help="Pass through --work-mode.",
    )
    analyze_parser.add_argument("--include-raw-report", action="store_true", help="Include the raw Acuminator JSON report in the output.")
    analyze_parser.add_argument("--include-runner-output", action="store_true", help="Include captured runner stdout/stderr in the output.")
    analyze_parser.set_defaults(func=analyze)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
