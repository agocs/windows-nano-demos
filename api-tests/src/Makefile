# Cross-compiles apiprobe.exe with MinGW-w64 (Ubuntu: gcc-mingw-w64-x86-64).
# The result may import only kernel32.dll and msvcrt.dll; CI checks that.
CC      = x86_64-w64-mingw32-gcc
WINDRES = x86_64-w64-mingw32-windres
CFLAGS  = -O2 -municode -std=gnu11 -Wall -Wextra -Wno-unused-parameter -Wno-cast-function-type \
          -Wno-missing-field-initializers -Wno-unused-function
LDFLAGS = -municode -static-libgcc -s
OUT     = ../bin/apiprobe.exe

SRCS = apiprobe.c probes_kernel32.c probes_advapi32.c probes_crypto.c probes_user32.c \
       probes_shell.c probes_com.c probes_net.c probes_diag.c probes_crt.c
OBJS = $(SRCS:.c=.o) apiprobe.res.o

all: $(OUT)

$(OUT): $(OBJS)
	mkdir -p ../bin
	$(CC) $(LDFLAGS) -o $@ $(OBJS)

%.o: %.c probes.h
	$(CC) $(CFLAGS) -c -o $@ $<

apiprobe.res.o: apiprobe.rc apiprobe.manifest
	$(WINDRES) -O coff -o $@ apiprobe.rc

clean:
	rm -f $(OBJS) $(OUT)

.PHONY: all clean
