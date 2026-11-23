#!/usr/bin/env python3
"""manual-bundle.py — the manual a doz build carries (`doz docs`), made from docs/manual at this commit.

    python3 Scripts/manual-bundle.py --out DIR --version X.Y.Z [--manual docs/manual] [--check]
    python3 Scripts/manual-bundle.py --stamp-skill FILE --version X.Y.Z

--out writes DIR (replaced whole: built beside it, then renamed over it) with:

    NN-name.md, README.md   every page of docs/manual, its links rewritten to work inside DIR: a link to another page
                            (`NN-name.md`, `name.md`, https://dozable.com/docs/name[.md]) stays or becomes `NN-name.md`;
                            a link out of the manual (`../…`) and an image (`images/…`, not carried) become the
                            repository's file at this version's tag
    llms.txt                the index: a title, one line per page with a RELATIVE link and the page's first sentence
    llms-full.txt           every page in reading order, each starting with its relative name
    VERSION                 the version, one line

--check then fails unless every llms.txt link is relative and resolves inside DIR, as does every page's relative link
(`make docs-drift-check` runs it).

--stamp-skill writes this version into a shipped skill's `https://dozable.com/v/…/` URLs (in place; run again with
another version, it is rewritten again). Used by `make cli`, `make install-cli` and Scripts/release.sh.

Standard library only. The output is the same for the same pages and version (sorted, no dates).
"""
import argparse
import os
import re
import shutil
import sys

SITE = "https://dozable.com"
PAGE_RE = re.compile(r"^(\d\d)-([a-z0-9-]+)\.md$")
LINK_RE = re.compile(r"(!?)\[([^\]]*)\]\(([^)\s]+)\)")


def repository(root):
    """Distribution.repository (Sources/DozableHost/Updates.swift): the ONE place the repository's name lives."""
    try:
        text = open(os.path.join(root, "Sources/DozableHost/Updates.swift"), encoding="utf-8").read()
        m = re.search(r'static let repository = "([^"]+)"', text)
        if m:
            return m.group(1)
    except OSError:
        pass
    return "dozable/dozable"


def pages_of(manual):
    names = sorted(n for n in os.listdir(manual) if PAGE_RE.match(n))
    if not names:
        sys.exit(f"x manual-bundle: no NN-name.md pages in {manual}")
    return names


def rewrite(text, page_names, repo_blob):
    """Links that resolve inside the bundle: pages by their file name, everything else to the repository at the tag."""
    by_slug = {PAGE_RE.match(n).group(2): n for n in page_names}
    files = set(page_names) | {"README.md", "llms.txt", "llms-full.txt"}

    def target_for(url):
        path, frag = (url.split("#", 1) + [""])[:2]
        frag = "#" + frag if frag else ""
        if path == "" or path.startswith(("mailto:", "http://", "https://")) and not path.startswith(SITE + "/docs/"):
            return None
        if path.startswith(SITE + "/docs/"):
            slug = path[len(SITE + "/docs/"):]
            slug = slug[:-3] if slug.endswith(".md") else slug
            slug = slug.rstrip("/")
            if slug in ("", "index"):
                return "README.md" + frag
            return (by_slug[slug] + frag) if slug in by_slug else None
        if path in files:
            return None
        if path.endswith(".md") and path[:-3] in by_slug:
            return by_slug[path[:-3]] + frag
        # Out of the manual folder, or an image (not carried): the repository's file at this version's tag.
        resolved = os.path.normpath(os.path.join("docs/manual", path))
        if resolved.startswith(".."):
            return None
        return f"{repo_blob}/{resolved}{frag}"

    def sub(m):
        new = target_for(m.group(3))
        return m.group(0) if new is None else f"{m.group(1)}[{m.group(2)}]({new})"

    out, fenced = [], False
    for line in text.split("\n"):
        if line.lstrip().startswith("```"):
            fenced = not fenced
        out.append(line if fenced else LINK_RE.sub(sub, line))
    return "\n".join(out)


def plain(s):
    s = re.sub(r"!?\[([^\]]*)\]\([^)]*\)", r"\1", s)
    s = s.replace("**", "").replace("`", "").replace("*", "")
    return re.sub(r"\s+", " ", s).strip()


def title_and_summary(text):
    title, para, seen_title = None, [], False
    fenced = False
    for line in text.split("\n"):
        t = line.strip()
        if t.startswith("```"):
            fenced = not fenced
            if para:
                break
            continue
        if fenced:
            continue
        if title is None and t.startswith("# "):
            title, seen_title = plain(t[2:]), True
            continue
        if not seen_title:
            continue
        if not t:
            if para:
                break
            continue
        if t.startswith(("#", "|", "<", "!", ">", "- ", "* ")) or re.match(r"^\d+\. ", t):
            if para:
                break
            continue
        para.append(t)
    text = plain(" ".join(para))
    m = re.match(r"^(.+?[.!?])(\s|$)", text)
    return title or "", (m.group(1) if m else text)


def bundle(manual, out, version, root):
    repo_blob = f"https://github.com/{repository(root)}/blob/v{version}"
    names = pages_of(manual)
    tmp = out.rstrip("/") + ".new"
    shutil.rmtree(tmp, ignore_errors=True)
    os.makedirs(tmp)
    rewritten = {}
    for n in names + (["README.md"] if os.path.exists(os.path.join(manual, "README.md")) else []):
        with open(os.path.join(manual, n), encoding="utf-8") as f:
            rewritten[n] = rewrite(f.read(), names, repo_blob)
        with open(os.path.join(tmp, n), "w", encoding="utf-8") as f:
            f.write(rewritten[n])

    lines = [
        f"# Dozable {version} — the manual",
        "",
        "> Fast, resumable, secure Linux sandboxes for AI coding agents on your Mac — your API keys never go inside.",
        "",
        f"The user manual of doz {version}, carried inside it: every page as Markdown, in this folder. "
        "`doz docs PAGE` prints one (a name or a number), `doz docs --path` prints this folder. "
        f"The same manual online, for this version only: {SITE}/v/{version}/llms.txt",
        "",
        "## Docs",
        "",
    ]
    for n in names:
        title, summary = title_and_summary(rewritten[n])
        lines.append(f"- [{title}]({n}): {summary}" if summary else f"- [{title}]({n})")
    if "README.md" in rewritten:
        lines.append("- [The manual — contents](README.md): every chapter, and when to read it.")
    lines += ["", "## Optional", "", "- [The whole manual in one file](llms-full.txt): every page above, in reading order.", ""]
    with open(os.path.join(tmp, "llms.txt"), "w", encoding="utf-8") as f:
        f.write("\n".join(lines))

    full = [
        f"# Dozable {version} — the whole manual",
        "",
        f"Every page of the manual of doz {version}, in reading order. Each part starts with its file name in this folder.",
        "",
    ]
    for n in names:
        full += ["---", "", f"File: {n}", "", rewritten[n].rstrip("\n"), ""]
    with open(os.path.join(tmp, "llms-full.txt"), "w", encoding="utf-8") as f:
        f.write("\n".join(full) + "\n")
    with open(os.path.join(tmp, "VERSION"), "w", encoding="utf-8") as f:
        f.write(version + "\n")

    old = out.rstrip("/") + ".old"
    shutil.rmtree(old, ignore_errors=True)
    if os.path.exists(out):
        os.rename(out, old)
    os.rename(tmp, out)
    shutil.rmtree(old, ignore_errors=True)
    print(f"manual-bundle: {len(names)} pages, llms.txt, llms-full.txt, VERSION {version} → {out}")


def check(out):
    """Every link of llms.txt is relative and resolves inside `out`; so does every relative link of every page."""
    bad = []
    llms = open(os.path.join(out, "llms.txt"), encoding="utf-8").read()
    links = re.findall(r"\]\(([^)\s]+)\)", llms)
    if not links:
        bad.append("llms.txt has no links")
    for l in links:
        if l.startswith(("http://", "https://", "/")) or not os.path.isfile(os.path.join(out, l.split("#")[0])):
            bad.append(f"llms.txt: {l}")
    for n in sorted(os.listdir(out)):
        if not n.endswith(".md"):
            continue
        fenced = False
        for line in open(os.path.join(out, n), encoding="utf-8").read().split("\n"):
            if line.lstrip().startswith("```"):
                fenced = not fenced
            if fenced:
                continue
            for m in LINK_RE.finditer(line):
                t = m.group(3).split("#")[0]
                if t and not t.startswith(("http://", "https://", "mailto:")) and not os.path.isfile(os.path.join(out, t)):
                    bad.append(f"{n}: {m.group(3)}")
    if bad:
        sys.exit("x manual-bundle: links that do not resolve inside the bundle:\n  " + "\n  ".join(bad))
    print(f"ok manual-bundle: {len(links)} llms.txt links and every page's relative links resolve inside {out}")


def stamp_skill(path, version):
    text = open(path, encoding="utf-8").read()
    new = re.sub(r"https://dozable\.com/v/[^/\s`)]+/", f"{SITE}/v/{version}/", text)
    if new != text:
        tmp = path + ".new"
        with open(tmp, "w", encoding="utf-8") as f:
            f.write(new)
        os.replace(tmp, path)


def main():
    ap = argparse.ArgumentParser(description="The manual a doz build carries.")
    ap.add_argument("--manual", default="docs/manual")
    ap.add_argument("--out")
    ap.add_argument("--stamp-skill")
    ap.add_argument("--check", action="store_true", help="after --out: every link resolves inside the bundle")
    ap.add_argument("--version", required=True)
    a = ap.parse_args()
    if not re.match(r"^\d+\.\d+\.\d+([-+][0-9A-Za-z.-]+)?$", a.version):
        sys.exit(f"x manual-bundle: --version must be semver, not {a.version!r}")
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    if a.stamp_skill:
        stamp_skill(a.stamp_skill, a.version)
    if a.out:
        bundle(a.manual, a.out, a.version, root)
        if a.check:
            check(a.out)
    if not a.out and not a.stamp_skill:
        ap.error("--out DIR or --stamp-skill FILE")


if __name__ == "__main__":
    main()
