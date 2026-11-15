# Windows test programs, cross-compiled with mingw-w64 (brew install mingw-w64).
CC64 ?= x86_64-w64-mingw32-gcc
CC32 ?= i686-w64-mingw32-gcc
CFLAGS ?= -O2 -Wall -Wno-unused-variable
OUT ?= build

PROBES64 = $(OUT)/d3d11_probe.exe $(OUT)/d3d12_probe.exe $(OUT)/d3d9_probe.exe $(OUT)/vulkan_probe.exe $(OUT)/system_probes.exe $(OUT)/present_probe.exe
PROBES32 = $(OUT)/d3d11_probe32.exe $(OUT)/d3d9_probe32.exe $(OUT)/present_probe32.exe

all: $(PROBES64) $(PROBES32)

$(OUT):
	mkdir -p $(OUT)

$(OUT)/d3d11_probe.exe: d3d11_probe.c probe.h | $(OUT)
	$(CC64) -O2 -o $@ $< -ld3d11 -ldxgi -ldxguid
$(OUT)/d3d11_probe32.exe: d3d11_probe.c probe.h | $(OUT)
	$(CC32) -O2 -o $@ $< -ld3d11 -ldxgi -ldxguid
$(OUT)/d3d12_probe.exe: d3d12_probe.c probe.h | $(OUT)
	$(CC64) -O2 -o $@ $< -ldxguid
$(OUT)/d3d9_probe.exe: d3d9_probe.c probe.h | $(OUT)
	$(CC64) -O2 -o $@ $< -ld3d9
$(OUT)/d3d9_probe32.exe: d3d9_probe.c probe.h | $(OUT)
	$(CC32) -O2 -o $@ $< -ld3d9
$(OUT)/vulkan_probe.exe: vulkan_probe.c probe.h | $(OUT)
	$(CC64) -O2 -o $@ $<
$(OUT)/system_probes.exe: system_probes.c probe.h | $(OUT)
	$(CC64) -O2 -o $@ $< -lwinhttp -lxinput -lole32 -lmfplat -lmfreadwrite -lmfuuid -luuid

$(OUT)/present_probe.exe: present_probe.c probe.h | $(OUT)
	$(CC64) -O2 -o $@ $< -ld3d11 -ldxgi -ldxguid -ld3d9 -lm
$(OUT)/present_probe32.exe: present_probe.c probe.h | $(OUT)
	$(CC32) -O2 -o $@ $< -ld3d11 -ldxgi -ldxguid -ld3d9 -lm

clean:
	rm -rf $(OUT)

.PHONY: all clean
