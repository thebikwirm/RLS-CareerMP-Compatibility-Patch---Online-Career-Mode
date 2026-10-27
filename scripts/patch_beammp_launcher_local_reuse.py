"""Patch a locally cloned BeamMP-Launcher to reuse identical local ZIPs before downloading.

Targets upstream src/Network/Resources.cpp, NewSyncResources SHA-256 path.
Dry-run by default. --apply writes a .bak original then patches launcher SOURCE.
Requires building a separate test launcher; does not patch a running executable.
Set BEAMMP_REUSE_LOCAL_MODS=1 when launching to opt in.
"""
from __future__ import annotations
import argparse
from pathlib import Path
import shutil

MARKER = "// CareerMP040 optional local ZIP reuse before download"
ANCHOR = '        if (fs::exists(PathToSaveTo) && Utils::GetSha256HashReallyFastFile(PathToSaveTo) == ModInfoIter->Hash) {'
HELPER_ANCHOR = 'void NewSyncResources(SOCKET Sock, const std::string& Mods, const std::vector<ModInfo> ModInfos) {'
HELPER = r'''// CareerMP040 optional local ZIP reuse before download
// Cache only immutable path candidates by byte size; hash is checked before use.
static std::unordered_multimap<uintmax_t, fs::path> CareerMP040LocalZips() {
    std::unordered_multimap<uintmax_t, fs::path> result;
    const auto root = fs::path(GetGamePath()) / "mods";
    std::error_code ec;
    if (!fs::is_directory(root, ec)) return result;
    fs::recursive_directory_iterator iter(root, fs::directory_options::skip_permission_denied, ec), end;
    while (iter != end) {
        if (ec) { ec.clear(); iter.increment(ec); continue; }
        const auto path = iter->path();
        const auto rel = path.lexically_relative(root);
        bool excluded = false;
        for (const auto& part : rel) {
            auto s = part.string();
            std::transform(s.begin(), s.end(), s.begin(), [](unsigned char c) { return (char)std::tolower(c); });
            if (s == "multiplayer" || s == "unpacked") { excluded = true; break; }
        }
        if (excluded && iter->is_directory(ec)) iter.disable_recursion_pending();
        if (!excluded && iter->is_regular_file(ec) && !iter->is_symlink(ec) && path.extension() == ".zip") {
            const auto size = fs::file_size(path, ec);
            if (!ec) result.emplace(size, path);
        }
        ec.clear();
        iter.increment(ec);
    }
    return result;
}

'''
CALL = r'''        // CareerMP040: cache an exact local match so BeamMP's existing
        // verified-cache staging, multiplayer naming and WaitForConfirm stay intact.
        // Never trust filename, and never bypass protected server resources.
        if (careerMP040ReuseLocal && !ModInfoIter->Protected &&
            (!fs::exists(PathToSaveTo) ||
             Utils::GetSha256HashReallyFastFile(PathToSaveTo) != ModInfoIter->Hash)) {
            const auto candidates = careerMP040LocalZipsBySize.equal_range(ModInfoIter->FileSize);
            for (auto it = candidates.first; it != candidates.second; ++it) {
                const auto& candidate = it->second;
                std::error_code ec;
                if (!fs::is_regular_file(candidate, ec) || fs::file_size(candidate, ec) != ModInfoIter->FileSize)
                    continue;
                if (Utils::GetSha256HashReallyFastFile(candidate) != ModInfoIter->Hash)
                    continue;
                auto temporary = PathToSaveTo;
                temporary += ".localreuse.tmp";
                fs::copy_file(candidate, temporary, fs::copy_options::overwrite_existing, ec);
                if (ec || Utils::GetSha256HashReallyFastFile(temporary) != ModInfoIter->Hash) {
                    fs::remove(temporary, ec);
                    warn("[CareerMP040] local ZIP changed during copy; using standard download");
                    continue;
                }
                // Remove stale invalid cache only after replacement is verified.
                fs::rename(temporary, PathToSaveTo, ec);
                if (ec) {
                    // Windows rename cannot replace the existing destination.
                    fs::remove(PathToSaveTo, ec);
                    ec.clear();
                    fs::rename(temporary, PathToSaveTo, ec);
                }
                if (ec) {
                    warn("[CareerMP040] unable to stage local ZIP; using standard download");
                    fs::remove(temporary, ec);
                } else {
                    info("[CareerMP040] reused verified local ZIP: " + ModInfoIter->FileName);
                    break;
                }
            }
        }
'''
# Include needed standard headers. Guard upstream layout changes.
def transform(source: str) -> str:
    if MARKER in source:
        raise RuntimeError("Already patched")
    if source.count(HELPER_ANCHOR) != 1 or source.count(ANCHOR) != 1:
        raise RuntimeError("Unknown launcher Resources.cpp layout; refusing patch")
    source = source.replace('#include <atomic>', '#include <atomic>\n#include <algorithm>\n#include <cctype>\n#include <cstdlib>\n#include <unordered_map>', 1)
    source = source.replace(HELPER_ANCHOR, HELPER + HELPER_ANCHOR, 1)
    anchor = '    info("Syncing...");'
    if source.count(anchor) != 2:
        raise RuntimeError("Expected two sync paths; refusing patch")
    at = source.index(anchor, source.index(HELPER_ANCHOR))
    source = source[:at] + source[at:].replace(anchor, anchor + r'''
    const char* localReuseSetting = std::getenv("BEAMMP_REUSE_LOCAL_MODS");
    const bool careerMP040ReuseLocal = localReuseSetting && std::string(localReuseSetting) == "1";
    const auto careerMP040LocalZipsBySize = careerMP040ReuseLocal
        ? CareerMP040LocalZips() : std::unordered_multimap<uintmax_t, fs::path>{};
    if (careerMP040ReuseLocal)
        info("[CareerMP040] local ZIP reuse enabled; candidates=" + std::to_string(careerMP040LocalZipsBySize.size()));
''', 1)
    source = source.replace(ANCHOR, CALL + ANCHOR, 1)
    return source

def main() -> None:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("launcher", type=Path, help="Path to local BeamMP-Launcher repo root")
    p.add_argument("--apply", action="store_true")
    args = p.parse_args()
    path = args.launcher / "src" / "Network" / "Resources.cpp"
    if not path.is_file():
        p.error(f"Missing launcher source: {path}")
    source = path.read_text(encoding="utf-8")
    patched = transform(source)
    print(f"Patch checks passed: {path}")
    if not args.apply:
        print("DRY RUN; add --apply to write backed-up source")
        return
    backup = path.with_suffix(".cpp.bak")
    if backup.exists():
        p.error(f"Backup exists; refusing overwrite: {backup}")
    shutil.copy2(path, backup)
    path.write_text(patched, encoding="utf-8")
    print(f"Patched: {path}; original: {backup}")
    print("Compile BeamMP-Launcher and set BEAMMP_REUSE_LOCAL_MODS=1 to test.")
    print("This avoids duplicate DOWNLOADS, not duplicated activation of local mods.")
if __name__ == "__main__":
    main()
