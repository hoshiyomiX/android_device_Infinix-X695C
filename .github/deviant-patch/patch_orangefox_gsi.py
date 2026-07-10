#!/usr/bin/env python3
"""
patch_orangefox_gsi.py — Inject Flash GSI wizard into OrangeFox recovery boot.img

This script runs inside the fox_gsi_patch.yml GitHub Actions workflow.
It:
  1. Takes the path to a downloaded OrangeFox-*.img release artifact
  2. Unpacks it via magiskboot
  3. Extracts ramdisk.cpio
  4. Uses magiskboot cpio to:
     a. Add /sbin/gsi_run.sh (from device tree, already in repo)
     b. Extract /twres/pages/advanced.xml
     c. Inject Flash GSI listitem button (with condition var1=utils_show)
     d. Re-pack ramdisk.cpio with modified advanced.xml
     e. Add /twres/pages/flash_gsi.xml (new wizard page)
  5. Updates ui.xml to include flash_gsi.xml in <include> section
  6. Re-packs boot.img via magiskboot repack
  7. Outputs patched-${original_filename}

Usage:
  python3 patch_orangefox_gsi.py <input.img> <output.img> <magiskboot_bin> <patch_files_dir>

  patch_files_dir contains:
    - flash_gsi.xml     (wizard page)
    - gsi_run.sh        (script to inject to /sbin/)
    - advanced.xml.patch (sed-style patch for advanced.xml button injection)
"""

import os
import sys
import re
import shutil
import subprocess
import xml.etree.ElementTree as ET
from pathlib import Path


def run(cmd, check=True, capture=False):
    """Run a command, optionally capturing output."""
    print(f"$ {' '.join(cmd) if isinstance(cmd, list) else cmd}")
    if capture:
        result = subprocess.run(cmd, shell=isinstance(cmd, str),
                                check=check, capture_output=True, text=True)
        if result.stdout:
            print(result.stdout)
        if result.returncode != 0 and result.stderr:
            print(f"STDERR: {result.stderr}", file=sys.stderr)
        return result
    else:
        return subprocess.run(cmd, shell=isinstance(cmd, str), check=check)


def inject_button_into_advanced(advanced_xml_content):
    """
    Inject a 'Flash GSI' listitem button into advanced.xml's <page name="advanced"> listbox.
    Place it after the existing 'flash_image' / 'Mount' listitem, before 'Magisk Manager'.

    The listitem uses OrangeFox's standard pattern:
      <listitem name="Flash GSI Image">
        <condition var1="utils_show" var2="1"/>
        <icon res="bs_adv_se"/>
        <action function="page">flash_gsi_select</action>
      </listitem>

    Regex is whitespace-tolerant (\s*) — matches regardless of whether the theme
    uses tabs or spaces for indentation, and regardless of indent depth.
    """
    button_xml = (
        '\t\t\t\t<listitem name="Flash GSI Image">\n'
        '\t\t\t\t\t<condition var1="utils_show" var2="1"/>\n'
        '\t\t\t\t\t<icon res="bs_adv_se"/>\n'
        '\t\t\t\t\t<action function="page">flash_gsi_select</action>\n'
        '\t\t\t\t</listitem>\n'
    )

    # Insert AFTER the "Mount" listitem, BEFORE "Magisk Manager" listitem.
    # Use whitespace-tolerant regex (\s*) instead of literal \t\t\t\t —
    # this survives indentation changes (2 tabs, 4 tabs, spaces, etc.).
    pattern = r'(\s*<listitem name="\{@mount_hdr\}"[^>]*>[\s\S]*?</listitem>\s*\n)'
    match = re.search(pattern, advanced_xml_content)
    if not match:
        # Fallback: insert before "Magisk Manager" listitem
        pattern = (
            r'(\s*<listitem name="Magisk Manager"'
            r'[^>]*>[\s\S]*?</listitem>\s*\n)'
        )
        match = re.search(pattern, advanced_xml_content)
        if not match:
            raise RuntimeError(
                "Cannot find Mount or Magisk listitem in advanced.xml — "
                "the page structure may have changed. Manual injection required."
            )

    insertion_point = match.end()
    new_content = (
        advanced_xml_content[:insertion_point]
        + button_xml
        + advanced_xml_content[insertion_point:]
    )
    return new_content


def inject_include_into_ui(ui_xml_content):
    """
    Inject <xml name="/twres/pages/flash_gsi.xml"/> into ui.xml's <include> block.
    Insert AFTER the existing advanced.xml include line.
    """
    include_line = '\t\t<xml name="/twres/pages/advanced.xml"/>\n'
    new_include = '\t\t<xml name="/twres/pages/flash_gsi.xml"/>\n'

    if new_include in ui_xml_content:
        print("  [skip] flash_gsi.xml include already present in ui.xml")
        return ui_xml_content

    if include_line not in ui_xml_content:
        raise RuntimeError(
            "Cannot find '<xml name=\"/twres/pages/advanced.xml\"/>' in ui.xml"
        )

    return ui_xml_content.replace(include_line, include_line + new_include)


def main():
    if len(sys.argv) != 5:
        print(__doc__)
        sys.exit(1)

    input_img = sys.argv[1]
    output_img = sys.argv[2]
    magiskboot = sys.argv[3]
    # Resolve patch_files_dir to ABSOLUTE path now, before any os.chdir() calls.
    # Otherwise relative paths break after we cd into /tmp/ofox_gsi_patch/extracted/.
    patch_files_dir = Path(sys.argv[4]).resolve()
    # Also resolve input/output/magiskboot to absolute paths for the same reason.
    input_img = str(Path(input_img).resolve())
    output_img = str(Path(output_img).resolve())
    magiskboot = str(Path(magiskboot).resolve())

    print(f"=== OrangeFox GSI Patch ===")
    print(f"  Input:       {input_img}")
    print(f"  Output:      {output_img}")
    print(f"  magiskboot:  {magiskboot}")
    print(f"  Patch dir:   {patch_files_dir}")
    print()

    # Validate inputs
    if not os.path.isfile(input_img):
        print(f"ERROR: input image not found: {input_img}", file=sys.stderr)
        sys.exit(1)
    if not os.path.isfile(magiskboot):
        print(f"ERROR: magiskboot binary not found: {magiskboot}", file=sys.stderr)
        sys.exit(1)

    flash_gsi_xml = patch_files_dir / "flash_gsi.xml"
    gsi_run_sh = patch_files_dir / "gsi_run.sh"
    if not flash_gsi_xml.is_file():
        print(f"ERROR: flash_gsi.xml not found in {patch_files_dir}", file=sys.stderr)
        sys.exit(1)
    if not gsi_run_sh.is_file():
        print(f"ERROR: gsi_run.sh not found in {patch_files_dir}", file=sys.stderr)
        sys.exit(1)

    # Setup work dir
    workdir = Path("/tmp/ofox_gsi_patch")
    if workdir.exists():
        shutil.rmtree(workdir)
    workdir.mkdir(parents=True)

    # Step 1: copy input image
    print("\n[1/7] Copying input image...")
    boot_img = workdir / "boot.img"
    shutil.copy(input_img, boot_img)

    # Step 2: unpack boot.img via magiskboot
    print("\n[2/7] Unpacking boot.img via magiskboot...")
    os.chdir(workdir)
    run([magiskboot, "unpack", "boot.img"], check=False)  # magiskboot may return non-zero for warnings
    # Verify ramdisk.cpio exists
    ramdisk = workdir / "ramdisk.cpio"
    if not ramdisk.is_file():
        print(f"ERROR: ramdisk.cpio not found after unpack", file=sys.stderr)
        sys.exit(1)

    # Step 3: extract advanced.xml from ramdisk
    print("\n[3/7] Extracting /twres/pages/advanced.xml from ramdisk.cpio...")
    extract_dir = workdir / "extracted"
    extract_dir.mkdir()
    os.chdir(extract_dir)
    run([magiskboot, "cpio", str(ramdisk), "extract"], check=False)

    advanced_xml_path = extract_dir / "twres" / "pages" / "advanced.xml"
    ui_xml_path = extract_dir / "twres" / "ui.xml"
    if not advanced_xml_path.is_file():
        print(f"ERROR: /twres/pages/advanced.xml not found in ramdisk", file=sys.stderr)
        sys.exit(1)
    if not ui_xml_path.is_file():
        print(f"ERROR: /twres/ui.xml not found in ramdisk", file=sys.stderr)
        sys.exit(1)

    print(f"  Found: {advanced_xml_path}")
    print(f"  Found: {ui_xml_path}")

    # Step 4: inject Flash GSI button into advanced.xml
    print("\n[4/7] Injecting Flash GSI button into advanced.xml...")
    advanced_content = advanced_xml_path.read_text(encoding='utf-8')
    new_advanced = inject_button_into_advanced(advanced_content)
    advanced_xml_path.write_text(new_advanced, encoding='utf-8')
    print(f"  Patched: {advanced_xml_path}")

    # Step 5: copy flash_gsi.xml into ramdisk's twres/pages/
    print("\n[5/7] Adding flash_gsi.xml to /twres/pages/...")
    pages_dir = extract_dir / "twres" / "pages"
    pages_dir.mkdir(parents=True, exist_ok=True)
    shutil.copy(flash_gsi_xml, pages_dir / "flash_gsi.xml")
    print(f"  Added: {pages_dir / 'flash_gsi.xml'}")

    # Step 6: inject <xml include> into ui.xml
    print("\n[6/7] Injecting flash_gsi.xml include into ui.xml...")
    ui_content = ui_xml_path.read_text(encoding='utf-8')
    new_ui = inject_include_into_ui(ui_content)
    ui_xml_path.write_text(new_ui, encoding='utf-8')
    print(f"  Patched: {ui_xml_path}")

    # Step 7: re-pack ramdisk.cpio with modified files + add gsi_run.sh to /sbin/
    print("\n[7/7] Re-packing ramdisk.cpio and boot.img...")
    os.chdir(extract_dir)
    # Add gsi_run.sh to /sbin/
    sbin_dir = extract_dir / "sbin"
    sbin_dir.mkdir(parents=True, exist_ok=True)
    shutil.copy(gsi_run_sh, sbin_dir / "gsi_run.sh")
    os.chmod(sbin_dir / "gsi_run.sh", 0o755)

    # CRITICAL: magiskboot cpio command syntax requires the operation to be
    # passed as a SINGLE QUOTED STRING, not as separate argv elements.
    # Reference: Magisk's own boot_patch.sh:
    #   ./magiskboot cpio $RAMDISK "add 0750 init magiskinit"
    #
    # Format: "add <mode> <local_file> <dest_in_cpio>"
    # - mode: octal permission (e.g. 0644, 0755)
    # - local_file: path on disk (relative to CWD or absolute)
    # - dest_in_cpio: path inside cpio archive (NO leading /)
    #
    # We must cd into extract_dir so the local_file paths are relative
    # and match what magiskboot expects.
    os.chdir(extract_dir)

    # Copy custom accent.xml (crimson red theme) into extracted themes dir
    accent_src = patch_files_dir / "accent.xml"
    if accent_src.is_file():
        themes_dir = extract_dir / "twres" / "themes"
        themes_dir.mkdir(parents=True, exist_ok=True)
        shutil.copy(accent_src, themes_dir / "accent.xml")
        print(f"  Added: {themes_dir / 'accent.xml'} (crimson red override)")
    else:
        print(f"  NOTE: accent.xml not found in patch_files — skipping theme override")

    files_to_add = [
        ("twres/pages/advanced.xml", "0644"),
        ("twres/pages/flash_gsi.xml", "0644"),
        ("twres/ui.xml", "0644"),
        ("twres/themes/accent.xml", "0644"),
        ("sbin/gsi_run.sh", "0755"),
    ]
    for dest_in_cpio, mode in files_to_add:
        src_local = dest_in_cpio  # same path (we're in extract_dir)
        if not (extract_dir / src_local).is_file():
            print(f"  WARNING: source file not found: {src_local}", file=sys.stderr)
            continue
        # magiskboot cpio add syntax: "add MODE ENTRY INFILE"
        # where ENTRY = dest path in cpio (NO leading /), INFILE = local source file
        # Reference: magiskboot cpio help + Magisk boot_patch.sh
        cmd_str = f"add {mode} {dest_in_cpio} {src_local}"
        run([magiskboot, "cpio", str(ramdisk), cmd_str], check=False)
        print(f"  Added/updated: {dest_in_cpio}")

    # Re-pack boot.img
    os.chdir(workdir)
    run([magiskboot, "repack", "boot.img", str(output_img)])
    print(f"\n=== Patched image written to: {output_img} ===")

    # L2 fix: verify XML well-formedness post-injection (catches regex corruption)
    print("\n[Post-check] Verifying XML well-formedness of injected files...")
    for xml_file in ["twres/pages/advanced.xml", "twres/pages/flash_gsi.xml", "twres/ui.xml", "twres/themes/accent.xml"]:
        xml_path = extract_dir / xml_file
        if not xml_path.is_file():
            print(f"  WARNING: {xml_file} not found for validation", file=sys.stderr)
            continue
        try:
            ET.parse(str(xml_path))
            print(f"  ✓ {xml_file}: well-formed")
        except ET.ParseError as e:
            print(f"  ✗ {xml_file}: XML PARSE ERROR — {e}", file=sys.stderr)
            print(f"    The regex injection may have corrupted the XML structure.", file=sys.stderr)
            print(f"    Aborting — patched image is invalid.", file=sys.stderr)
            sys.exit(1)

    # Verify output exists and has reasonable size
    if not os.path.isfile(output_img):
        print(f"ERROR: output image not created", file=sys.stderr)
        sys.exit(1)
    out_size = os.path.getsize(output_img)
    in_size = os.path.getsize(input_img)
    print(f"\nSize comparison:")
    print(f"  Input:  {in_size:>10} bytes ({in_size/1024/1024:.2f} MB)")
    print(f"  Output: {out_size:>10} bytes ({out_size/1024/1024:.2f} MB)")
    print(f"  Delta:  {out_size - in_size:>+10} bytes")
    if out_size > 32 * 1024 * 1024:
        print(f"  WARNING: output exceeds 32MB partition limit!", file=sys.stderr)


if __name__ == "__main__":
    main()
