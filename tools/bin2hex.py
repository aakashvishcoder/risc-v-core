#!/usr/bin/env python3
"""Convert a flat little-endian binary into a $readmemh file of 32-bit words."""
import sys

def main():
    src, dst = sys.argv[1], sys.argv[2]
    data = open(src, "rb").read()
    data += b"\x00" * (-len(data) % 4)
    with open(dst, "w") as f:
        for i in range(0, len(data), 4):
            f.write(f"{int.from_bytes(data[i:i+4], 'little'):08x}\n")

if __name__ == "__main__":
    main()
