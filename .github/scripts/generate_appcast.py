#!/usr/bin/env python3
"""
Generate appcast.xml from GitHub Releases
Automatically fetches release information and converts markdown to HTML
"""

import json
import os
import sys
import re
from datetime import datetime
from typing import Dict, List, Optional
import urllib.request
import urllib.error
from xml.etree import ElementTree as ET
from xml.dom import minidom

def fetch_github_releases(repo: str, token: Optional[str] = None) -> List[Dict]:
    """Fetch releases from GitHub API"""
    url = f"https://api.github.com/repos/{repo}/releases"
    headers = {
        'Accept': 'application/vnd.github.v3+json',
        'User-Agent': 'XKey-Appcast-Generator'
    }
    
    if token:
        headers['Authorization'] = f'token {token}'
    
    req = urllib.request.Request(url, headers=headers)
    
    try:
        with urllib.request.urlopen(req) as response:
            return json.loads(response.read().decode())
    except urllib.error.HTTPError as e:
        print(f"Error fetching releases: {e}", file=sys.stderr)
        sys.exit(1)

def markdown_to_html(markdown: str) -> str:
    """Convert markdown to HTML (simple implementation)"""
    html = markdown
    
    # Headers
    html = re.sub(r'^### (.*?)$', r'<h3>\1</h3>', html, flags=re.MULTILINE)
    html = re.sub(r'^## (.*?)$', r'<h2>\1</h2>', html, flags=re.MULTILINE)
    html = re.sub(r'^# (.*?)$', r'<h1>\1</h1>', html, flags=re.MULTILINE)
    
    # Bold and italic
    html = re.sub(r'\*\*\*(.+?)\*\*\*', r'<strong><em>\1</em></strong>', html)
    html = re.sub(r'\*\*(.+?)\*\*', r'<strong>\1</strong>', html)
    html = re.sub(r'\*(.+?)\*', r'<em>\1</em>', html)
    html = re.sub(r'__(.+?)__', r'<strong>\1</strong>', html)
    html = re.sub(r'_(.+?)_', r'<em>\1</em>', html)
    
    # Links
    html = re.sub(r'\[(.+?)\]\((.+?)\)', r'<a href="\2">\1</a>', html)
    
    # Code blocks
    html = re.sub(r'```[\w]*\n(.*?)\n```', r'<pre><code>\1</code></pre>', html, flags=re.DOTALL)
    html = re.sub(r'`(.+?)`', r'<code>\1</code>', html)
    
    # Lists
    lines = html.split('\n')
    in_ul = False
    in_ol = False
    result = []
    
    for line in lines:
        # Unordered list
        if re.match(r'^[\*\-\+] ', line):
            if not in_ul:
                result.append('<ul>')
                in_ul = True
            result.append(f'<li>{line[2:].strip()}</li>')
        # Ordered list
        elif re.match(r'^\d+\. ', line):
            if not in_ol:
                result.append('<ol>')
                in_ol = True
            cleaned_line = re.sub(r'^\d+\. ', '', line).strip()
            result.append(f'<li>{cleaned_line}</li>')
        else:
            if in_ul:
                result.append('</ul>')
                in_ul = False
            if in_ol:
                result.append('</ol>')
                in_ol = False
            if line.strip():
                result.append(f'<p>{line}</p>')
    
    if in_ul:
        result.append('</ul>')
    if in_ol:
        result.append('</ol>')
    
    return '\n'.join(result)

def find_dmg_asset(assets: List[Dict]) -> Optional[Dict]:
    """Find the main DMG file in release assets"""
    # Look for XKey.dmg first
    for asset in assets:
        if asset['name'] == 'XKey.dmg':
            return asset
    
    # Fallback to any .dmg file
    for asset in assets:
        if asset['name'].endswith('.dmg') and 'IM' not in asset['name']:
            return asset
    
    return None

def find_signature_asset(assets: List[Dict]) -> Optional[Dict]:
    """Find the EdDSA signature file in release assets"""
    for asset in assets:
        if asset['name'] == 'signature.txt':
            return asset
    return None

def fetch_signature(signature_asset: Dict, token: Optional[str] = None) -> Optional[str]:
    """Fetch the EdDSA signature content from the asset"""
    if not signature_asset:
        return None
    
    url = signature_asset['browser_download_url']
    headers = {
        'User-Agent': 'XKey-Appcast-Generator'
    }
    
    if token:
        headers['Authorization'] = f'token {token}'
    
    req = urllib.request.Request(url, headers=headers)
    
    try:
        with urllib.request.urlopen(req) as response:
            content = response.read().decode().strip()
            # The signature file may contain just the signature or be in format:
            # sparkle:edSignature="..." length="..."
            # Extract just the signature
            if 'sparkle:edSignature=' in content:
                import re
                match = re.search(r'sparkle:edSignature="([^"]+)"', content)
                if match:
                    return match.group(1)
            return content
    except urllib.error.HTTPError as e:
        print(f"Warning: Could not fetch signature: {e}", file=sys.stderr)
        return None

def find_version_json_asset(assets: List[Dict]) -> Optional[Dict]:
    """Find the version.json file in release assets"""
    for asset in assets:
        if asset['name'] == 'version.json':
            return asset
    return None

def fetch_version_info(version_asset: Dict, token: Optional[str] = None) -> Optional[Dict]:
    """Fetch version info from version.json asset"""
    if not version_asset:
        return None
    
    url = version_asset['browser_download_url']
    headers = {
        'User-Agent': 'XKey-Appcast-Generator'
    }
    
    if token:
        headers['Authorization'] = f'token {token}'
    
    req = urllib.request.Request(url, headers=headers)
    
    try:
        with urllib.request.urlopen(req) as response:
            content = response.read().decode().strip()
            return json.loads(content)
    except (urllib.error.HTTPError, json.JSONDecodeError) as e:
        print(f"Warning: Could not fetch version.json: {e}", file=sys.stderr)
        return None

def format_rfc822_date(iso_date: str) -> str:
    """Convert ISO 8601 date to RFC 822 format"""
    dt = datetime.fromisoformat(iso_date.replace('Z', '+00:00'))
    return dt.strftime('%a, %d %b %Y %H:%M:%S %z')

def generate_appcast_xml(repo: str, token: Optional[str] = None) -> str:
    """Generate complete appcast.xml from GitHub releases"""
    releases = fetch_github_releases(repo, token)
    
    repo_owner = repo.split('/')[0]
    repo_name = repo.split('/')[1]
    
    # Start building XML manually to properly handle CDATA
    xml_lines = [
        '<?xml version="1.0" encoding="utf-8"?>',
        '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">',
        '  <channel>',
        '    <title>XKey Updates</title>',
        f'    <link>https://{repo_owner}.github.io/{repo_name}/appcast.xml</link>',
        '    <description>XKey - Vietnamese Input Method for macOS</description>',
        '    <language>vi</language>',
    ]
    
    # Process releases (only the latest one)
    items_added = 0
    for release in releases:
        # Skip drafts and pre-releases
        if release.get('draft') or release.get('prerelease'):
            continue
        
        # Find DMG asset
        dmg_asset = find_dmg_asset(release.get('assets', []))
        if not dmg_asset:
            print(f"Warning: No DMG found for release {release['tag_name']}", file=sys.stderr)
            continue
        
        # Find and fetch EdDSA signature
        signature_asset = find_signature_asset(release.get('assets', []))
        ed_signature = fetch_signature(signature_asset, token)
        
        if not ed_signature:
            print(f"Error: No EdDSA signature found for release {release['tag_name']}", file=sys.stderr)
            print(f"       Refusing to generate an appcast that Sparkle cannot validate.", file=sys.stderr)
            sys.exit(1)

        if not re.fullmatch(r'[A-Za-z0-9+/=]{80,}', ed_signature):
            print(f"Error: Invalid EdDSA signature format for release {release['tag_name']}", file=sys.stderr)
            print(f"       Value: {ed_signature}", file=sys.stderr)
            sys.exit(1)
        
        # Find and fetch version info from version.json
        version_asset = find_version_json_asset(release.get('assets', []))
        version_info = fetch_version_info(version_asset, token)
        
        # Extract version and build number
        if version_info:
            short_version = version_info.get('version', '')
            build_number = version_info.get('build', '')
            print(f"Found version.json: version={short_version}, build={build_number}", file=sys.stderr)
        else:
            # Fallback: extract from tag (old format: v1.2.14 or new format: v1.2.14-20251225.1)
            tag = release['tag_name'].lstrip('v')
            if '-' in tag:
                parts = tag.split('-', 1)
                short_version = parts[0]
                build_number = parts[1]
            else:
                short_version = tag
                build_number = tag  # Use version as build number for backward compatibility
            print(f"No version.json, extracted from tag: version={short_version}, build={build_number}", file=sys.stderr)
        
        # Convert release notes markdown to HTML
        release_notes = release.get('body', '')
        release_notes_html = markdown_to_html(release_notes) if release_notes else ''
        
        # Add link to full release notes
        release_url = release['html_url']
        if release_notes_html:
            release_notes_html += f'\n<p><a href="{release_url}">Xem chi tiết trên GitHub</a></p>'
        
        # Parse and format published date
        pub_date = release.get('published_at', release.get('created_at'))
        formatted_date = format_rfc822_date(pub_date)
        
        # Build enclosure attributes
        # sparkle:version is the build number (for update comparison)
        # sparkle:shortVersionString is the display version
        enclosure_attrs = [
            f'url="{dmg_asset["browser_download_url"]}"',
            f'sparkle:version="{build_number}"',
            f'sparkle:shortVersionString="{short_version}"',
            f'length="{dmg_asset["size"]}"',
            'type="application/octet-stream"',
        ]
        
        # Add EdDSA signature if available
        if ed_signature:
            enclosure_attrs.append(f'sparkle:edSignature="{ed_signature}"')
        
        enclosure_str = ' '.join(enclosure_attrs)
        
        # Add item
        xml_lines.extend([
            '    <item>',
            f'      <title>Version {short_version} (Build {build_number})</title>',
            f'      <link>{release_url}</link>',
            f'      <sparkle:version>{build_number}</sparkle:version>',
            f'      <sparkle:shortVersionString>{short_version}</sparkle:shortVersionString>',
            f'      <description><![CDATA[',
            f'        {release_notes_html}',
            f'      ]]></description>',
            f'      <pubDate>{formatted_date}</pubDate>',
            f'      <sparkle:minimumSystemVersion>12.0</sparkle:minimumSystemVersion>',
            f'      <enclosure {enclosure_str} />',
            '    </item>',
        ])
        
        items_added += 1
        # Only include the latest release
        break
    
    if items_added == 0:
        print("Warning: No valid releases found", file=sys.stderr)
    
    # Close XML
    xml_lines.extend([
        '  </channel>',
        '</rss>',
    ])
    
    return '\n'.join(xml_lines)

def main():
    # Get repository from environment or argument
    repo = os.getenv('GITHUB_REPOSITORY', 'xmannv/xkey')
    token = os.getenv('GITHUB_TOKEN')
    
    # Generate appcast XML
    appcast_xml = generate_appcast_xml(repo, token)
    
    # Write to file
    output_path = os.getenv('OUTPUT_PATH', 'appcast.xml')
    with open(output_path, 'w', encoding='utf-8') as f:
        f.write(appcast_xml)
    
    print(f"✅ Generated appcast.xml")
    print(f"📝 Output: {output_path}")

if __name__ == '__main__':
    main()
