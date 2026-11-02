#!/usr/bin/env python3
"""Package and verify a signed app without opening Finder or unrelated volumes."""

import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import stat
import subprocess
import sys
import tempfile
import time


HDIUTIL = "/usr/bin/hdiutil"
CODESIGN = "/usr/bin/codesign"
XATTR = "/usr/bin/xattr"
SIGNING_DETRITUS = ("com.apple.FinderInfo", "com.apple.ResourceFork")
# Copy layout assets only; never copy the previous app, Applications or system folders.
LAYOUT_ASSETS = (
    ".DS_Store", ".background", ".VolumeIcon.icns", ".VolumeIcon",
    ".disk_label", ".disk_label_2x",
)


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def run(arguments):
    result = subprocess.run([str(arg) for arg in arguments], capture_output=True)
    if result.returncode:
        message = (result.stderr + result.stdout).decode("utf-8", errors="replace").strip()
        raise RuntimeError(f"{Path(arguments[0]).name} failed ({result.returncode}): {message}")
    return result


def manifest(root, names=None):
    """Hash every regular file and link target; preserve empty dirs and file modes."""
    result = {}

    def visit(path):
        info = path.lstat()
        relative = path.relative_to(root).as_posix()
        if stat.S_ISLNK(info.st_mode):
            target = os.readlink(path)
            result[relative] = {
                "type": "symlink", "target": target,
                "sha256": hashlib.sha256(os.fsencode(target)).hexdigest(),
            }
        elif stat.S_ISREG(info.st_mode):
            result[relative] = {
                "type": "file", "bytes": info.st_size, "sha256": sha256(path),
                "mode": stat.S_IMODE(info.st_mode),
            }
        elif stat.S_ISDIR(info.st_mode):
            result[relative] = {"type": "directory", "mode": stat.S_IMODE(info.st_mode)}
            for child in sorted(path.iterdir()):
                visit(child)
        else:
            raise RuntimeError(f"Unsupported special file: {path}")

    for child in (sorted(root.iterdir()) if names is None else [root / name for name in names]):
        visit(child)
    return result


def require_same(expected, actual, label):
    if expected != actual:
        different = sorted(name for name in set(expected) | set(actual)
                           if expected.get(name) != actual.get(name))
        raise RuntimeError(f"{label} differs: {', '.join(different[:12])}")


def signature(path):
    result = run([CODESIGN, "--verify", "--deep", "--strict", "--verbose=2", path])
    return {"result": "PASS", "details": (result.stdout + result.stderr).decode(
        "utf-8", errors="replace").strip()}


def clean_staged_metadata(app):
    """Remove only signing-incompatible metadata from our private generated copy."""
    for attribute in SIGNING_DETRITUS:
        # xattr -d returns nonzero for missing attributes, including on descendants.
        # Strict codesign below remains the authority if removal actually failed.
        subprocess.run([XATTR, "-dr", attribute, str(app)], capture_output=True)
    return {"scope": "isolated staged app only", "attributes": list(SIGNING_DETRITUS),
            "source_app_modified": False}


def detach(mountpoint):
    """Only detach the unique mountpoint this process created, never /Volumes globs."""
    last = None
    for attempt in range(3):
        command = [HDIUTIL, "detach", mountpoint]
        if attempt == 2:
            command.append("-force")
        try:
            run(command)
            return
        except RuntimeError as error:
            last = error
            if not os.path.ismount(mountpoint):
                return
            time.sleep(0.5)
    raise RuntimeError(f"Could not detach own mountpoint {mountpoint}: {last}")


@contextmanager
def mounted(image, mountpoint):
    mountpoint.mkdir()
    attached = False
    try:
        result = run([HDIUTIL, "attach", "-readonly", "-nobrowse", "-noautoopen",
                      "-mountpoint", mountpoint, "-plist", image])
        entities = plistlib.loads(result.stdout).get("system-entities", [])
        attached = any(entry.get("mount-point") == str(mountpoint) for entry in entities)
        if not attached or not os.path.ismount(mountpoint):
            raise RuntimeError(f"Image did not mount at the requested private path: {mountpoint}")
        yield mountpoint
    finally:
        # Also covers an interrupted/failed attach that nevertheless mounted the image.
        if attached or os.path.ismount(mountpoint):
            detach(mountpoint)


def copy_layout(old_dmg, stage, mountpoint):
    if not old_dmg.exists():
        return [], {}
    with mounted(old_dmg, mountpoint) as old_root:
        layout_file = old_root / ".DS_Store"
        if not layout_file.is_file() or layout_file.is_symlink():
            # A previous package (or a stripped image) may lack the Finder layout.
            # Packaging must still succeed; fall back to the default icon layout.
            print("Warning: existing DMG has no .DS_Store; keeping default icon layout", file=sys.stderr)
            return [], {}
        names = [name for name in LAYOUT_ASSETS
                 if (old_root / name).exists() or (old_root / name).is_symlink()]
        before = manifest(old_root, names)
        for name in names:
            source, destination = old_root / name, stage / name
            if source.is_symlink():
                destination.symlink_to(os.readlink(source))
            elif source.is_dir():
                shutil.copytree(source, destination, symlinks=True)
            else:
                shutil.copy2(source, destination)
        require_same(before, manifest(stage, names), "Copied Finder layout")
    return names, before


def absolute_output(path):
    path = Path(path).expanduser().absolute()
    return path.parent.resolve() / path.name


def is_inside(path, directory):
    try:
        path.relative_to(directory)
        return True
    except ValueError:
        return False


def save_backup(source, destination, expected_sha):
    """Install a complete backup atomically without overwriting an older backup."""
    destination.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=".roxy-backup-", dir=destination.parent)
    os.close(descriptor)
    temporary = Path(temporary)
    try:
        shutil.copy2(source, temporary)
        if sha256(temporary) != expected_sha:
            raise RuntimeError("Original DMG changed while making the backup")
        os.link(temporary, destination)
    finally:
        temporary.unlink(missing_ok=True)


def prepare_report(report, destination):
    if destination is None:
        return None
    destination.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=".roxy-report-", dir=destination.parent)
    temporary = Path(temporary)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(report, stream, ensure_ascii=False, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
    except BaseException:
        temporary.unlink(missing_ok=True)
        raise
    return temporary


def prepare_file_copy(source, directory, prefix, expected_sha):
    """Copy a complete checked file onto the destination filesystem before replace."""
    descriptor, temporary = tempfile.mkstemp(prefix=prefix, dir=directory)
    os.close(descriptor)
    temporary = Path(temporary)
    try:
        shutil.copy2(source, temporary)
        with temporary.open("rb") as stream:
            os.fsync(stream.fileno())
        if sha256(temporary) != expected_sha:
            raise RuntimeError(f"File changed while preparing {source.name}")
        return temporary
    except BaseException:
        temporary.unlink(missing_ok=True)
        raise


def package(app, output, report_path=None, backup_path=None):
    app = Path(app).expanduser().resolve(strict=True)
    output = absolute_output(output)
    report_path = absolute_output(report_path) if report_path else None
    backup_path = absolute_output(backup_path) if backup_path else None
    if not app.is_dir() or app.suffix != ".app":
        raise ValueError(f"App bundle required: {app}")
    if output.suffix.lower() != ".dmg":
        raise ValueError("Output must end in .dmg")
    destinations = [path for path in (output, report_path, backup_path) if path is not None]
    if len(set(destinations)) != len(destinations):
        raise ValueError("DMG, report and backup paths must be distinct")
    if any(is_inside(path, app) or path.is_symlink() for path in destinations):
        raise ValueError("Outputs must be outside the app bundle and must not be symbolic links")
    if output.exists() and not output.is_file():
        raise ValueError(f"Output is not a regular file: {output}")
    if backup_path and backup_path.exists():
        raise ValueError(f"Refusing to overwrite an existing backup: {backup_path}")
    if report_path and report_path.exists() and not report_path.is_file():
        raise ValueError(f"Report is not a regular file: {report_path}")
    output.parent.mkdir(parents=True, exist_ok=True)
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    executable = info["CFBundleExecutable"]
    if not isinstance(executable, str) or not executable or Path(executable).name != executable:
        raise ValueError("CFBundleExecutable must name a file inside Contents/MacOS")
    executable_path = app / "Contents/MacOS" / executable
    source_manifest = manifest(app)
    executable_sha = sha256(executable_path)
    original_sha = sha256(output) if output.exists() else None
    # iCloud can reattach FinderInfo in the repository even after it was removed.
    # Stage and mount on the local temporary volume, outside file-provider scope.
    work = Path(tempfile.mkdtemp(prefix="roxy-dmg-", dir="/private/tmp"))
    report_temporary = None
    image_temporary = None
    guard = None
    committed = False
    try:
        stage = work / "stage"
        stage.mkdir()
        layout_names, layout_manifest = copy_layout(output, stage, work / "mount-old")
        staged_app = stage / app.name
        shutil.copytree(app, staged_app, symlinks=True)
        metadata_cleanup = clean_staged_metadata(staged_app)
        require_same(source_manifest, manifest(staged_app), "Staged app")
        source_signature = signature(staged_app)
        source_signature["verified_from"] = "isolated staged copy with source-identical files, modes and links"
        (stage / "Applications").symlink_to("/Applications")
        image = work / "Roxy-new.dmg"
        run([HDIUTIL, "create", "-volname", "Roxy", "-srcfolder", stage,
             "-format", "UDZO", "-fs", "HFS+", "-imagekey", "zlib-level=9", image])
        run([HDIUTIL, "verify", image])
        with mounted(image, work / "mount-new") as volume:
            packaged_manifest = manifest(volume / app.name)
            require_same(source_manifest, packaged_manifest, "Mounted app")
            applications = volume / "Applications"
            if not applications.is_symlink() or os.readlink(applications) != "/Applications":
                raise RuntimeError("Packaged Applications link is incorrect")
            require_same(layout_manifest, manifest(volume, layout_names), "Mounted Finder layout")
            packaged_signature = signature(volume / app.name)
            if sha256(volume / app.name / "Contents/MacOS" / executable) != executable_sha:
                raise RuntimeError("Packaged executable SHA-256 differs from the source app")
        # Both images are detached before the output can be replaced.
        require_same(source_manifest, manifest(app), "Source app changed during packaging")
        current_original_sha = sha256(output) if output.exists() else None
        if current_original_sha != original_sha:
            raise RuntimeError("Existing DMG changed during packaging; refusing to replace it")
        image_sha = sha256(image)
        image_temporary = prepare_file_copy(image, output.parent, ".roxy-image-", image_sha)
        if backup_path and original_sha:
            save_backup(output, backup_path, original_sha)
        report = {
            "result": "PASS",
            "created_at_utc": datetime.now(timezone.utc).isoformat(),
            "source_app": str(app),
            "source_executable": {"path": str(executable_path), "sha256": executable_sha},
            "dmg": {"path": str(output), "sha256": image_sha, "bytes": image.stat().st_size},
            "previous_dmg_sha256": original_sha,
            "backup": str(backup_path) if backup_path and original_sha else None,
            "verification": {
                "hdiutil_verify": "PASS", "all_files_and_symlinks_identical": True,
                "source_unchanged": True, "applications_link": "/Applications",
                "file_count": sum(entry["type"] == "file" for entry in source_manifest.values()),
                "symlink_count": sum(entry["type"] == "symlink" for entry in source_manifest.values()),
                "source_signature": source_signature, "packaged_signature": packaged_signature,
                "metadata_cleanup": metadata_cleanup,
            },
            "layout": {
                "preserved": ".DS_Store" in layout_names,
                "assets": layout_names, "manifest": layout_manifest,
                "source": str(output) if original_sha else None,
            },
            "app_manifest": source_manifest,
        }
        report_temporary = prepare_report(report, report_path)
        # The image and rollback copy must share the output filesystem so replace
        # remains atomic when /private/tmp and the project live on different volumes.
        if original_sha:
            guard = prepare_file_copy(output, output.parent, ".roxy-previous-", original_sha)
        os.replace(image_temporary, output)
        image_temporary = None
        try:
            if report_temporary:
                os.replace(report_temporary, report_path)
                report_temporary = None
        except BaseException:
            if original_sha:
                os.replace(guard, output)
                guard = None
            else:
                output.unlink()
            raise
        committed = True
        return report
    finally:
        if report_temporary:
            report_temporary.unlink(missing_ok=True)
        if image_temporary:
            image_temporary.unlink(missing_ok=True)
        if guard:
            guard.unlink(missing_ok=True)
        # Never recurse into a volume if an interrupted detach left it mounted.
        remaining = [work / name for name in ("mount-old", "mount-new")
                     if os.path.ismount(work / name)]
        for mountpoint in list(remaining):
            try:
                detach(mountpoint)
                remaining.remove(mountpoint)
            except RuntimeError as error:
                print(f"Cleanup warning: {error}", file=sys.stderr)
        if remaining:
            print(f"Private work directory retained for mount cleanup: {work}", file=sys.stderr)
        else:
            try:
                shutil.rmtree(work)
            except OSError as error:
                # A cleanup warning must not turn a committed, verified image into a failed release.
                print(f"Cleanup warning ({'completed' if committed else 'failed'} package): {error}", file=sys.stderr)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path, help="Signed app bundle to package")
    parser.add_argument("output", type=Path, help="DMG replaced only after all checks pass")
    parser.add_argument("--report", type=Path, help="Write the complete SHA-256 verification report")
    parser.add_argument("--backup", type=Path, help="Preserve the previous DMG at this new path")
    arguments = parser.parse_args()
    try:
        report = package(arguments.app, arguments.output, arguments.report, arguments.backup)
    except (OSError, RuntimeError, ValueError, KeyError, plistlib.InvalidFileException) as error:
        print(f"DMG packaging failed: {error}", file=sys.stderr)
        return 1
    print(f"Verified DMG: {report['dmg']['path']}")
    print(f"SHA-256: {report['dmg']['sha256']} ({report['dmg']['bytes']} bytes)")
    print("App files, symbolic links and code signature match the source bundle.")
    if arguments.report:
        print(f"Verification report: {absolute_output(arguments.report)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
