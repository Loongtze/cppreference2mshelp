#!/usr/bin/env python3
import re
import sys
from pathlib import Path

# Configure target directories and URLs
ROOT_DIR = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(".")
TARGET_EXTENSIONS = {'.html', '.css', '.js'}

BROKEN_URL = "https://upload.cppreference.com/mwiki/images/"
CORRECT_URL = "https://upload.cppreference.com/images/"
LOCAL_DIR = "upload.cppreference.com/images/"

def main():
    root = ROOT_DIR.resolve()
    
    # Find all relevant files
    all_files = [f for f in root.rglob('*') if f.suffix.lower() in TARGET_EXTENSIONS and f.is_file()]
    
    urls_to_download = set()
    files_modified = 0
    
    print(f"Scanning {len(all_files)} files...")
    
    for file_path in all_files:
        try:
            content = file_path.read_text(encoding='utf-8', errors='ignore')
        except Exception as e:
            print(f"Skipping {file_path}: {e}")
            continue
            
        # Skip files that don't contain the target domains
        if BROKEN_URL not in content and CORRECT_URL not in content:
            continue
            
        # Calculate relative path depth back to the root directory
        # e.g., if file is /root/dir1/dir2/file.html, depth is 2
        rel_path = file_path.relative_to(root)
        depth = len(rel_path.parts) - 1
        prefix = "../" * depth if depth > 0 else "./"
        local_path = prefix + LOCAL_DIR
        
        # Extract all unique image URLs that need to be downloaded
        # Temporarily fix broken URLs so we can extract the correct paths
        temp_content = content.replace(BROKEN_URL, CORRECT_URL)
        matches = re.findall(r'https://upload\.cppreference\.com/images/[^"\'<>\s)]+', temp_content)
        urls_to_download.update(matches)
        
        # Replace absolute URLs with local relative paths
        new_content = content.replace(BROKEN_URL, local_path)
        new_content = new_content.replace(CORRECT_URL, local_path)
        
        if new_content != content:
            file_path.write_text(new_content, encoding='utf-8')
            files_modified += 1

    print(f"Modified {files_modified} files with local relative paths.")
    
    # Output the missing URLs for wget to download
    if urls_to_download:
        url_file = root / "urls_to_download.txt"
        url_file.write_text("\n".join(sorted(urls_to_download)), encoding='utf-8')
        print(f"\nWrote {len(urls_to_download)} image URLs to {url_file}")
        print("\nRun this command to download the missing images:")
        print(f"  wget --force-directories -i {url_file}")
    else:
        print("No missing image URLs found.")

if __name__ == "__main__":
    main()