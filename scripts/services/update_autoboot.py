#!/usr/bin/env python3
"""Patch autoboot.txt boot_partition values after a successful OTA commit.

autoboot.txt is the bootloader's only record of which slot to boot, so it must never be left
half-written: a power loss during a plain truncate-and-write would leave the unit with no valid
slot selection. Write a temp file next to it, fsync, rename over the original, fsync the directory,
then read it back and verify. vfat renames aren't journaled, but the window where the directory
entry is in flux is tiny compared to a truncate-then-write of the file's contents.
"""

import os
import re
import sys


def patch(content: str, new_default: str, new_tryboot: str) -> str:
  content = re.sub(
      r'(\[all\][^\[]*?boot_partition=)\d+',
      lambda m: m.group(1) + new_default,
      content, flags=re.DOTALL
  )
  content = re.sub(
      r'(\[tryboot\][^\[]*?boot_partition=)\d+',
      lambda m: m.group(1) + new_tryboot,
      content, flags=re.DOTALL
  )
  return content


def selection(content: str) -> tuple:
  """ (default, tryboot) boot_partition values, or None for a missing one """
  def get(section):
    m = re.search(rf'\[{section}\][^\[]*?boot_partition=(\d+)', content, flags=re.DOTALL)
    return m.group(1) if m else None
  return get('all'), get('tryboot')


def main():
  path, new_default, new_tryboot = sys.argv[1], sys.argv[2], sys.argv[3]
  with open(path, encoding='utf-8') as f:
    content = patch(f.read(), new_default, new_tryboot)
  if selection(content) != (new_default, new_tryboot):
    sys.exit(f'{path}: could not find both boot_partition entries to patch - leaving it untouched')

  tmp = f'{path}.tmp'
  with open(tmp, 'w', encoding='utf-8') as f:
    f.write(content)
    f.flush()
    os.fsync(f.fileno())
  os.replace(tmp, path)
  dir_fd = os.open(os.path.dirname(os.path.abspath(path)), os.O_RDONLY)
  try:
    os.fsync(dir_fd)
  finally:
    os.close(dir_fd)

  with open(path, encoding='utf-8') as f:
    if selection(f.read()) != (new_default, new_tryboot):
      sys.exit(f'{path}: verification after write failed')


if __name__ == '__main__':
  main()
