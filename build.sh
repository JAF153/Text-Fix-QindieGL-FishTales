#!/usr/bin/env bash
# Usage: ./build.sh /path/to/original/QindieGL/opengl32.dll
# Produces ./opengl32.dll (the proxy). Needs a 32-bit mingw-w64 toolchain.
#
# Install layout afterwards (game folder):
#   FishTales.exe
#   opengl32.dll            <- the proxy built here
#   qindiegl/opengl32.dll   <- the ORIGINAL QindieGL DLL, same name, untouched
set -euo pipefail

QDLL="${1:?usage: $0 /path/to/original/QindieGL/opengl32.dll}"
CC="${CC:-i686-w64-mingw32-gcc}"
OBJDUMP="${OBJDUMP:-i686-w64-mingw32-objdump}"
command -v "$CC" >/dev/null || { echo "missing $CC (install 32-bit mingw-w64)"; exit 1; }
command -v "$OBJDUMP" >/dev/null || OBJDUMP=objdump

# Functions implemented in gl_list_proxy.c (must NOT get pass-through stubs).
OVERRIDE=" glGenLists glNewList glEndList glCallList glCallLists glListBase \
glDeleteLists glIsList glBegin glEnd glTexCoord2f glVertex2f glVertex3i glTranslated "

echo "Reading exports from $QDLL ..."
"$OBJDUMP" -p "$QDLL" \
  | sed -n '/\[Ordinal\/Name Pointer\] Table/,/^$/p' \
  | grep -E '^[[:space:]]+\[ *[0-9]+\] ' \
  | awk '{print $NF}' \
  | sort -u > exports.txt

[ -s exports.txt ] || { echo "No exports found in $QDLL"; exit 1; }

# Pass-through names = exports minus overrides
: > passthru.txt
while read -r name; do
  case "$OVERRIDE" in *" $name "*) ;; *) echo "$name" >> passthru.txt ;; esac
done < exports.txt
count=$(wc -l < passthru.txt)
echo "Found $(wc -l < exports.txt) exports, $count pass-through."

# stubs.c: name table, pointer table, and one "jmp *ptr" stub per export.
{
  echo '#include <windows.h>'
  echo "const int gl_count = $count;"
  echo 'const char *gl_names[] = {'
  while read -r n; do echo "  \"$n\","; done < passthru.txt
  echo '};'
  echo "void *gl_ptrs[$count];"
  echo '__asm__('
  echo '  ".text\n"'
  i=0
  while read -r n; do
    echo "  \".globl _stub_$n\\n_stub_$n:\\n\\tjmp *_gl_ptrs+$((i*4))\\n\""
    i=$((i+1))
  done < passthru.txt
  echo ');'
} > stubs.c

# opengl32.def: export each pass-through name, pointing at its stub.
{
  echo "LIBRARY opengl32"
  echo "EXPORTS"
  while read -r n; do echo "$n = stub_$n"; done < passthru.txt
} > opengl32.def

$CC -O2 -shared -s -o opengl32.dll gl_list_proxy.c stubs.c opengl32.def \
    -Wl,--kill-at -static-libgcc

echo
echo "Built opengl32.dll. Now install:"
echo "  1) copy opengl32.dll into the game folder (next to the exe)"
echo "  2) put the ORIGINAL QindieGL opengl32.dll in <game folder>/qindiegl/"
