TWEAK_NAME = NDock
OUT        = $(TWEAK_NAME).dylib
ARCHS      = -arch arm64 -arch arm64e
CFLAGS     = -fobjc-arc -Wall -O2 $(ARCHS) -mmacosx-version-min=12.0

# Tắt DYLD_INSERT_LIBRARIES trong recipe
UNINJECT   = env -i HOME="$$HOME" USER="$$USER" PATH="/usr/bin:/bin:/usr/sbin:/sbin"

all: build

bootstrap:
	$(UNINJECT) ./bootstrap/build-stub.sh

build: NDock.dylib

NDock.dylib: Tweak.m WindowMargin.m NDConfig.m
	$(UNINJECT) clang -dynamiclib -framework Cocoa -o $(OUT) Tweak.m WindowMargin.m NDConfig.m $(CFLAGS)
	$(UNINJECT) codesign -f -s - $(OUT)
	@echo "Built $(OUT)"

# clean: giữ NDock.dylib để tránh crash khi DYLD_INSERT_LIBRARIES trỏ vào đây
clean:
	$(UNINJECT) rm -rf dist

clean-all: clean
	$(UNINJECT) rm -f $(OUT)

package:
	$(UNINJECT) ./package.sh

app:
	$(UNINJECT) ./build-app.sh

install:
	$(UNINJECT) ./ndock install

.PHONY: all build clean clean-all package app bootstrap install
