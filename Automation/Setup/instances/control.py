"""One-shot lifecycle for registered Acumatica instances in the shared VM."""

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import time
from urllib.error import URLError
from urllib.request import ProxyHandler, Request, build_opener

from catalog import Profile, available_builds, identifier, load_catalog, new_profile, select_build, verify_packages
from guest import Guest


class Instances:
    def __init__(self, guest: Guest, profiles: dict[str, Profile]):
        self.guest = guest
        self.profiles = profiles

    def running(self) -> bool:
        result = subprocess.run(["docker", "inspect", os.environ.get("VM_CONTAINER", "acumatica-windows"),
                                 "--format", "{{.State.Running}}"], text=True, capture_output=True, check=True)
        return result.stdout.strip() == "true"

    def core(self) -> None:
        self.guest.command("acumatica-up.sh", "--core-only")

    def status(self, profiles: list[Profile]) -> list[dict]:
        return self.guest.call("status", profiles=[p.wire() for p in profiles])

    def stop(self, profile: Profile) -> None:
        # The shared n8n runtime belongs exclusively to the canonical instance.
        # Never retarget its credentials or workflows during a swap.
        if profile.id == "default":
            self.guest.command("n8n-down.sh")
        self.guest.call("stop", profile=profile.wire())
        print(f"Stopped {profile.id}", flush=True)

    def ready(self, profile: Profile, port: int = 38121) -> None:
        self.guest.command("vm-web-expose.sh", str(port), capture=True)
        try:
            self.guest.call("start", profile=profile.wire())
            wait_for_login(profile, port)
        except (Exception, KeyboardInterrupt) as error:
            # A failed RPC response does not prove the guest failed to start.
            try:
                self.stop(profile)
            except Exception as cleanup:
                raise RuntimeError(f"{error}; target cleanup also failed: {cleanup}") from error
            raise
        print(profile.url(port), flush=True)

    def activate(self, selected: list[Profile], exclusive: bool) -> None:
        self.core()
        others = []
        if exclusive:
            selected_ids = {p.id for p in selected}
            others = [self.profiles[s["id"]] for s in self.status(list(self.profiles.values()))
                      if s["id"] not in selected_ids and s["state"] not in ("Stopped", "not-provisioned")]
        for profile in selected:
            self.ready(profile)
        for profile in others:
            self.stop(profile)
        if exclusive and "default" not in {p.id for p in selected} and not any(p.id == "default" for p in others):
            self.guest.command("n8n-down.sh")
        if any(p.id == "default" for p in selected):
            self.guest.command("n8n-up.sh")
        print("Active selection: " + ", ".join(p.id for p in selected), flush=True)


def wait_for_login(profile: Profile, port: int) -> None:
    timeout = int(os.environ.get("ACUMATICA_READY_TIMEOUT_SECONDS", "420"))
    if not 1 <= timeout <= 1800:
        raise ValueError("ACUMATICA_READY_TIMEOUT_SECONDS must be between 1 and 1800")
    deadline = time.monotonic() + timeout
    opener = build_opener(ProxyHandler({}))
    login_path = f"/{profile.application}/Frames/Login.aspx"
    if profile.id == "default":
        login_path = os.environ.get("ACUMATICA_LOGIN_PATH", login_path)
        if not login_path.startswith("/AcumaticaERP/"):
            raise ValueError("canonical login probe must stay within /AcumaticaERP/")
    paths = (f"/{profile.application}/Frames/BrowserWarning.aspx", login_path)
    last_error = "not yet reachable"
    started = time.monotonic()
    print(f"Warming {profile.id}", flush=True)
    while time.monotonic() < deadline:
        try:
            for path in paths:
                request = Request(f"http://127.0.0.1:{port}{path}", headers={
                    "Host": f"{profile.host}:{port}",
                    "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36"})
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError("readiness deadline reached")
                with opener.open(request, timeout=min(10, remaining)) as response:
                    body = response.read(2 * 1024 * 1024)
                    if response.status != 200 or (path == login_path and b"Acumatica - Login" not in body):
                        raise OSError("unexpected Acumatica login response")
            print(f"Ready {profile.id} in {time.monotonic() - started:.1f}s", flush=True)
            return
        except (URLError, OSError, TimeoutError) as error:
            last_error = str(error)
            time.sleep(min(2, max(0, deadline - time.monotonic())))
    raise RuntimeError(f"{profile.id} did not become ready in {timeout}s: {last_error}")


def parser() -> argparse.ArgumentParser:
    cli = argparse.ArgumentParser(description=__doc__)
    actions = cli.add_subparsers(dest="action", required=True)
    actions.add_parser("builds", help="available release/UI presets and their pinned builds")
    actions.add_parser("list", help="registered profiles without starting the VM")
    actions.add_parser("status", help="verify live identities, pool state, packages and worker RAM")
    for action in ("use", "up", "stop"):
        sub = actions.add_parser(action)
        sub.add_argument("ids", nargs="+" if action != "use" else 1)
    sub = actions.add_parser("ready", help="probe an already-running VM; used by acumatica-ready.sh")
    sub.add_argument("id", nargs="?", default="default")
    sub.add_argument("--port", type=int, default=38121)
    sub = actions.add_parser("create", help="register and provision a fresh empty instance")
    sub.add_argument("id", type=identifier)
    choice = sub.add_mutually_exclusive_group()
    choice.add_argument("--release", choices=[b.release for b in available_builds()], help="release/UI preset (default: 26r1)")
    choice.add_argument("--build", choices=[b.build for b in available_builds()], help="exact supported build instead of a release preset")
    for action in ("provision", "publish"):
        actions.add_parser(action).add_argument("id")
    sub = actions.add_parser("checkpoint")
    sub.add_argument("id")
    sub.add_argument("name", type=identifier)
    sub = actions.add_parser("reset", help="destructive restore of this instance's own checkpoint")
    sub.add_argument("id")
    sub.add_argument("--checkpoint", required=True, type=identifier)
    sub.add_argument("--confirm", required=True, help="repeat the target instance ID")
    return cli


def main() -> None:
    args = parser().parse_args()
    if args.action == "builds":
        for build in available_builds():
            print(f"{build.release:8} {build.build}  {build.ui} UI")
        return
    setup = Path(__file__).resolve().parents[1]
    directory = setup / "instances" / "profiles"
    profiles = load_catalog(directory)
    runtime = Path(os.environ.get("ACUMATICA_RUNTIME_DIR", Path.home() / ".config/acumatica-runtime"))
    guest = Guest(setup, runtime)
    manager = Instances(guest, profiles)
    if args.action == "list":
        for p in profiles.values():
            print(f"{p.id:24} {p.build}  {p.url()}" + ("  [protected]" if p.protected else ""))
        return
    if args.action == "status":
        if not manager.running():
            print("Windows VM stopped. Profiles retained; use 'list' for their URLs.")
            return
        print(json.dumps(manager.status(list(profiles.values())), indent=2))
        return
    if args.action == "create":
        if args.id in profiles:
            raise ValueError(f"profile already registered: {args.id}; use provision only if no resources were created")
        build = select_build(release=args.release, build=args.build)
        profile = new_profile(args.id, build.build)
        print(f"Creating {profile.id}: {build.release} {build.build}, {build.ui} UI", flush=True)
        with (directory / f"{args.id}.json").open("x") as stream:
            json.dump(profile.wire(), stream, indent=2)
            stream.write("\n")
        profiles[args.id] = profile
    ids = getattr(args, "ids", None) or [args.id]
    if len(set(ids)) != len(ids):
        raise ValueError("duplicate instance selection")
    unknown = set(ids) - profiles.keys()
    if unknown:
        raise ValueError("unknown instance: " + ", ".join(sorted(unknown)))
    selected = [profiles[x] for x in ids]
    profile = selected[0]
    if args.action in ("use", "up"):
        manager.activate(selected, exclusive=args.action == "use")
        return
    if args.action == "ready":
        if not 1 <= args.port <= 65535:
            raise ValueError("invalid port")
        manager.ready(profile, args.port)
        return
    if args.action == "stop":
        if not manager.running():
            if "default" in ids:
                guest.command("n8n-down.sh")
            print("Windows VM already stopped")
            return
        for p in selected:
            manager.stop(p)
        return
    if profile.protected:
        raise ValueError("default is protected; create a named instance for publication and restore")
    if args.action == "reset" and args.confirm != profile.id:
        raise ValueError("--confirm must match the instance being overwritten")
    packages = verify_packages(profile, setup.parents[1]) if args.action == "publish" else []
    manager.core()
    if args.action in ("create", "provision"):
        result = guest.call("provision", admin=True, profile=profile.wire())
    elif args.action == "publish":
        result = guest.call("publish", profile=profile.wire(), packages=packages)
    elif args.action == "checkpoint":
        was_started = manager.status([profile])[0]["state"] == "Started"
        result = guest.call("checkpoint", admin=True, profile=profile.wire(), name=args.name)
        print(json.dumps(result, indent=2))
        if was_started:
            manager.ready(profile)
        return
    else:
        result = guest.call("reset", admin=True, profile=profile.wire(), name=args.checkpoint)
    print(json.dumps(result, indent=2))
    manager.ready(profile)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, RuntimeError, subprocess.SubprocessError, KeyError) as error:
        print(f"error: {error}", file=sys.stderr)
        sys.exit(1)
