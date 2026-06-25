TWEAK_NAME = NDock
OUT        = $(TWEAK_NAME).dylib
ARCHS      = -arch arm64 -arch arm64e
CFLAGS     = -fobjc-arc -Wall -O2 $(ARCHS) -mmacosx-version-min=12.0

all: build

build:
	clang -dynamiclib -framework Cocoa -o $(OUT) Tweak.m $(CFLAGS)
	codesign -f -s - $(OUT)
	@echo "Built $(OUT)"

clean:
	rm -f $(OUT)

.PHONY: all build clean
