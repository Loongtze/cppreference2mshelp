#!/usr/bin/env python3
import re
import sys
from pathlib import Path
from urllib.parse import urlparse

ROOT_DIR = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(".")
TARGET_EXTENSIONS = {'.html', '.css', '.js'}

UPLOAD_BROKEN = "https://upload.cppreference.com/mwiki/images/"
UPLOAD_CORRECT = "https://upload.cppreference.com/images/"
UPLOAD_LOCAL_DIR = "upload.cppreference.com/images/"

FONT_NAMES = (
    "DejaVuSans.ttf",
    "DejaVuSans-Bold.ttf",
    "DejaVuSansMono.ttf",
    "DejaVuSansMono-Bold.ttf",
    "DejaVuSansMonoCondensed60.ttf",
    "DejaVuSansMonoCondensed75.ttf",
)
STATIC_CPPREFERENCE_URLS = {
    *(f"https://zh.cppreference.com/{name}" for name in FONT_NAMES),
    "https://zh.cppreference.com/favicon.ico",
}


def local_prefix(root, file_path):
    rel_path = file_path.relative_to(root)
    depth = len(rel_path.parts) - 1
    return "../" * depth if depth > 0 else "./"


def clean_url(url):
    return url.rstrip('"\'),;')


def local_path_for_url(url):
    parsed = urlparse(url)
    return parsed.netloc + parsed.path


def rewrite_upload_urls(content, root, file_path, urls_to_download):
    local_path = local_prefix(root, file_path) + UPLOAD_LOCAL_DIR
    fixed_content = content.replace(UPLOAD_BROKEN, UPLOAD_CORRECT)
    matches = re.findall(
        r'https://upload\.cppreference\.com/images/[^"\'<>\s)]+',
        fixed_content)
    urls_to_download.update(clean_url(url) for url in matches)

    new_content = content.replace(UPLOAD_BROKEN, local_path)
    new_content = new_content.replace(UPLOAD_CORRECT, local_path)
    return new_content


def rewrite_vendor_urls(content, root, file_path, urls_to_download):
    prefix = local_prefix(root, file_path)

    def replace(match):
        url = clean_url(match.group(0))
        if "static.cloudflareinsights.com" in url:
            return url
        urls_to_download.add(url)
        return prefix + local_path_for_url(url)

    content = re.sub(
        r'https://cdn\.jsdelivr\.net/[^"\'<>\s)]+',
        replace, content)

    for url in STATIC_CPPREFERENCE_URLS:
        if url in content:
            urls_to_download.add(url)
            content = content.replace(url, prefix + local_path_for_url(url))

    return content


def main():
    root = ROOT_DIR.resolve()
    all_files = [
        f for f in root.rglob('*')
        if f.suffix.lower() in TARGET_EXTENSIONS and f.is_file()
    ]

    urls_to_download = set(STATIC_CPPREFERENCE_URLS)
    files_modified = 0

    print(f"Scanning {len(all_files)} files...")

    for file_path in all_files:
        try:
            content = file_path.read_text(encoding='utf-8', errors='ignore')
        except OSError as exc:
            print(f"Skipping {file_path}: {exc}")
            continue

        new_content = rewrite_upload_urls(
            content, root, file_path, urls_to_download)
        new_content = rewrite_vendor_urls(
            new_content, root, file_path, urls_to_download)

        if new_content != content:
            file_path.write_text(new_content, encoding='utf-8')
            files_modified += 1

    print(f"Modified {files_modified} files with local relative paths.")

    if urls_to_download:
        url_file = root / "urls_to_download.txt"
        url_file.write_text(
            "\n".join(sorted(urls_to_download)) + "\n", encoding='utf-8')
        print(f"\nWrote {len(urls_to_download)} asset URLs to {url_file}")
        print("\nRun this command to download missing assets:")
        print(f"  wget --force-directories --trust-server-names -i {url_file}")
    else:
        print("No missing asset URLs found.")


if __name__ == "__main__":
    main()
