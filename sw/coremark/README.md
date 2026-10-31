# CoreMark

EEMBC CoreMark, imported unmodified from
https://github.com/eembc/coremark (commit 1f483d5), under the license in
`LICENSE.md`. The benchmark sources (`core_*.c`, `coremark.h`) are untouched.

The port to this core lives in `core_portme.c`, `core_portme.h`, and the UART
hook in `ee_printf.c` (started from the upstream `barebones/` templates).
