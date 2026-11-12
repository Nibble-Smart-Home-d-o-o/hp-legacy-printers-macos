# HP Legacy Printers for macOS: HPLIP's open-source print and scan drivers,
# built natively (universal x86_64 + arm64) for USB HP printers that HP no
# longer supports on macOS.
#
#   make            -> hpcups filter, PPDs, scanner backend, hpscan, HP Scan.app
#   make pkg        -> build/hp-legacy-printers-macos.pkg
#   make notarize   -> signed + notarized package (needs Developer ID certs)
#
# Left out: HP's proprietary libImageProcessor blob and plugin-dependent
# printers (ZjStream/ZxStream LaserJets), and the JPEG-based LaserJet
# encapsulators (hbpl1, ljjetready, quickconnect). See tools/make-ppds.py.

HPLIP_VER    := 3.26.6
HPLIP_SHA256 := 5fb2235a9cb6ec07cb4786c4066b151359c301324d54aaabf69ae7eef35606b3
HPLIP        := third_party/hplip-$(HPLIP_VER)
HPLIP_READY  := $(HPLIP)/.patched
HPCUPS     := $(HPLIP)/prnt/hpcups
BUILD      := build
ARCHS      ?= x86_64 arm64
MIN_MACOS  ?= 11.0

# Everything installs under one prefix (no spaces: it ends up in PPDs and C strings).
PREFIX     := /Library/Printers/HPLIP
FILTER     := $(PREFIX)/filter/hpcups

ARCHFLAGS  := $(foreach a,$(ARCHS),-arch $(a)) -mmacosx-version-min=$(MIN_MACOS)
CPPFLAGS   := -I$(HPCUPS) -I$(HPLIP)/prnt -I$(HPLIP)/common -I$(HPLIP)/io/hpmud \
              -DAPDK_LITTLE_ENDIAN -DDISABLE_IMAGEPROCESSOR -DHPCUPS_NO_JPEG \
              -DCUPS_TMP_DIR='"/private/tmp"' -DCONFDIR='"$(PREFIX)/etc/hp"' -DNDEBUG
CFLAGS     := $(ARCHFLAGS) -O2 -w
CXXFLAGS   := $(ARCHFLAGS) -O2 -w -std=gnu++11
LDLIBS     := -lcups -lz

HPCUPS_SRC := HPCupsFilter.cpp dbuscomm.cpp Compressor.cpp Mode2.cpp Mode3.cpp \
              Mode9.cpp Mode10.cpp ModeDeltaPlus.cpp ModeJbig.cpp ErnieFilter.cpp \
              EncapsulatorFactory.cpp Encapsulator.cpp Pcl3.cpp Pcl3Gui.cpp Pcl3Gui2.cpp \
              LJMono.cpp LJColor.cpp LJFastRaster.cpp LJZjStream.cpp LJZxStream.cpp \
              Job.cpp Pipeline.cpp Processor.cpp RasterSender.cpp ColorMatcher.cpp \
              Halftoner.cpp Scaler.cpp dj400ColorMaps.cpp dj600ColorMaps.cpp \
              dj970ColorMaps.cpp dj8xxColorMaps.cpp dj4100ColorMaps.cpp BreakTables.cpp \
              Utils.cpp SystemServices.cpp Lidil.cpp LidilCompress.cpp dj3320ColorMaps.cpp \
              dj3600ColorMaps.cpp RunLenEncoding.cpp
OBJS := $(patsubst %.cpp,$(BUILD)/obj/hpcups/%.o,$(HPCUPS_SRC)) $(BUILD)/obj/common/utils.o

.PHONY: all ppd pkg scan app notarize clean distclean
all: $(BUILD)/hpcups ppd scan

# ---- upstream source: HPLIP tarball, checksum-verified, with patches/ applied --
third_party/dl/hplip-$(HPLIP_VER).tar.gz:
	@mkdir -p $(dir $@)
	curl -fsSL -o $@.part https://downloads.sourceforge.net/project/hplip/hplip/$(HPLIP_VER)/hplip-$(HPLIP_VER).tar.gz
	echo "$(HPLIP_SHA256)  $@.part" | shasum -a 256 -c
	mv $@.part $@

$(HPLIP_READY): third_party/dl/hplip-$(HPLIP_VER).tar.gz $(wildcard patches/*.patch)
	rm -rf $(HPLIP)
	tar xzf $< -C third_party
	for p in patches/*.patch; do patch -s -p1 -d $(HPLIP) < $$p || exit 1; done
	touch $@

$(BUILD)/obj/hpcups/%.o: $(HPCUPS)/%.cpp
	@mkdir -p $(dir $@)
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) -c $< -o $@

$(BUILD)/obj/common/%.o: $(HPLIP)/common/%.c
	@mkdir -p $(dir $@)
	$(CC) $(CPPFLAGS) $(CFLAGS) -c $< -o $@

$(BUILD)/hpcups: $(OBJS)
	$(CXX) $(ARCHFLAGS) -o $@ $^ $(LDLIBS)

PPD_OUT := $(BUILD)/ppd/HPLIP
SUPPORTED_LIST := $(BUILD)/supported-printers.txt
ppd: $(PPD_OUT)/.stamp

# Rewrites every PPD we can drive (filter path, "(macOS)" tag, pcl3gui2 color
# fix). See tools/make-ppds.py for the rules.
$(PPD_OUT)/.stamp: tools/make-ppds.py Makefile $(HPLIP_READY)
	python3 -I tools/make-ppds.py $(HPLIP)/ppd/hpcups $(PPD_OUT) $(FILTER) $(SUPPORTED_LIST)
	gzcat $(PPD_OUT)/hp-deskjet_2130_series.ppd.gz | grep -q 'cupsColorSpace 1/cupsBitsPerColor 8/cupsRowStep 0'
	touch $@

# ---- scanner: SANE "hpaio" backend + hpmud USB I/O + hpip image pipeline -----
# Built as one self-contained bundle (libusb linked statically) so it can be
# dlopen()ed by our own frontend without installing sane-backends.
# libusb is built from its release tarball as a universal static library
# (Homebrew only ships single-arch bottles). The checksum matches Homebrew's formula.
LIBUSB_VER    := 1.0.30
LIBUSB_SHA256 := fea36f34f9156400209595e300840767ab1a385ede1dc7ee893015aea9c6dbaf
LIBUSB_PREFIX := $(abspath $(BUILD))/deps
LIBUSB_A      := $(LIBUSB_PREFIX)/lib/libusb-1.0.a
SCAN_CONFDIR  ?= $(PREFIX)/etc/hp
SCAN_CPPFLAGS := -I$(HPLIP)/scan/sane -I$(HPLIP)/io/hpmud -I$(HPLIP)/ip -I$(HPLIP)/common \
                 -I$(HPLIP)/protocol -I$(LIBUSB_PREFIX)/include/libusb-1.0 \
                 -DCONFDIR='"$(SCAN_CONFDIR)"' -DMUDNAME='"hpmud"' -DHPLIP_NO_CFPLUGIN -D_GNU_SOURCE -DNDEBUG
SCAN_ARCHFLAGS := $(ARCHFLAGS)
SCAN_CFLAGS   := $(SCAN_ARCHFLAGS) -O2 -w -std=gnu89 -fvisibility=default \
                 -Wno-error=implicit-function-declaration -Wno-error=return-mismatch \
                 -Wno-error=int-conversion -Wno-error=incompatible-pointer-types

HPAIO_SRC := scan/sane/hpaio.c scan/sane/mfpdtf.c scan/sane/pml.c scan/sane/scl.c scan/sane/io.c \
             scan/sane/common.c scan/sane/sanei_init_debug.c scan/sane/marvell.c scan/sane/soapht.c \
             scan/sane/soap.c scan/sane/xml.c scan/sane/ledm.c scan/sane/bb_ledm.c scan/sane/http.c \
             scan/sane/sclpml.c scan/sane/escl.c scan/sane/orblite.c
HPMUD_SRC := io/hpmud/hpmud.c io/hpmud/mlc.c io/hpmud/model.c io/hpmud/pml.c io/hpmud/dot4.c \
             io/hpmud/jd.c io/hpmud/pp.c io/hpmud/musb.c
HPIP_SRC  := $(addprefix ip/,xconvolve.c xfax.c xgrayout.c xjpg_dct.c xjpg_fix.c xpad.c xrotate.c \
             xskel.c xtiff.c ipmain.c xchgbpp.c xcrop.c xgamma.c xjpg_dec.c xjpg_huf.c xpcx.c \
             xsaturation.c xtable.c xtonemap.c xbi2gray.c xcolrspc.c xfakemono.c xgray2bi.c \
             xinvert.c xjpg_enc.c xmatrix.c xpnm.c xscale.c xthumb.c xyxtract.c)
SCAN_SRC  := $(HPAIO_SRC) $(HPMUD_SRC) $(HPIP_SRC) protocol/hp_ipp.c common/utils.c
SCAN_OBJS := $(patsubst %.c,$(BUILD)/obj/scan/%.o,$(SCAN_SRC))

# The HPLIP sources only exist after the download+patch step; tell make they come
# from it, otherwise a fresh clone finds "no rule" for the objects.
HPLIP_SOURCES := $(addprefix $(HPCUPS)/,$(HPCUPS_SRC)) $(HPLIP)/common/utils.c \
                 $(addprefix $(HPLIP)/,$(SCAN_SRC)) $(HPLIP)/scan/sane/sane.h
$(HPLIP_SOURCES): | $(HPLIP_READY) ;

# Upstream links these as separate .so files; in one bundle their overlapping
# globals collide (hp_ipp.h defines http/auth_cancel_req in every includer, and
# hpmud has its own sysdump()), so give the library copies private names.
$(patsubst %.c,$(BUILD)/obj/scan/%.o,$(HPMUD_SRC)): SCAN_EXTRA := -Dsysdump=hpmud_sysdump
$(BUILD)/obj/scan/protocol/hp_ipp.o: SCAN_EXTRA := -Dhttp=hpipp_http -Dauth_cancel_req=hpipp_auth_cancel_req

$(BUILD)/obj/scan/%.o: $(HPLIP)/%.c
	@mkdir -p $(dir $@)
	$(CC) $(SCAN_CPPFLAGS) $(SCAN_CFLAGS) $(SCAN_EXTRA) -c $< -o $@

third_party/dl/libusb-$(LIBUSB_VER).tar.bz2:
	@mkdir -p $(dir $@)
	curl -fsSL -o $@.part https://github.com/libusb/libusb/releases/download/v$(LIBUSB_VER)/libusb-$(LIBUSB_VER).tar.bz2
	echo "$(LIBUSB_SHA256)  $@.part" | shasum -a 256 -c
	mv $@.part $@

$(LIBUSB_A): third_party/dl/libusb-$(LIBUSB_VER).tar.bz2
	rm -rf third_party/libusb-$(LIBUSB_VER) $(BUILD)/libusb && mkdir -p $(BUILD)/libusb
	tar xjf $< -C third_party
	cd $(BUILD)/libusb && $(abspath third_party/libusb-$(LIBUSB_VER))/configure \
	  --disable-shared --enable-static --disable-dependency-tracking --prefix=$(LIBUSB_PREFIX) \
	  CFLAGS="$(ARCHFLAGS) -O2" LDFLAGS="$(ARCHFLAGS)" >configure.log
	$(MAKE) -C $(BUILD)/libusb install >/dev/null

$(SCAN_OBJS): | $(LIBUSB_A)

$(BUILD)/libsane-hpaio.so: $(SCAN_OBJS) $(LIBUSB_A)
	$(CC) $(SCAN_ARCHFLAGS) -bundle -o $@ $^ \
	  -lcups -framework CoreFoundation -framework IOKit -framework Security -lobjc

# Universal, like the backend it dlopen()s.
$(BUILD)/hpscan: src/hpscan.c | $(HPLIP_READY)
	$(CC) $(SCAN_ARCHFLAGS) -O2 -Wall -I$(HPLIP)/scan/sane \
	  -DDEFAULT_BACKEND='"$(PREFIX)/lib/libsane-hpaio.so"' -o $@ $< \
	  -framework CoreFoundation -framework CoreGraphics -framework ImageIO

APP := $(BUILD)/HP Scan.app
$(BUILD)/app/HPScan: src/HPScanApp.swift
	@mkdir -p $(BUILD)/app
	swiftc -parse-as-library -O -target x86_64-apple-macos13.0 $< -o $(BUILD)/app/HPScan-x86_64
	swiftc -parse-as-library -O -target arm64-apple-macos13.0 $< -o $(BUILD)/app/HPScan-arm64
	lipo -create $(BUILD)/app/HPScan-x86_64 $(BUILD)/app/HPScan-arm64 -output $@

app: $(BUILD)/app/HPScan packaging/app/Info.plist
	rm -rf "$(APP)" && mkdir -p "$(APP)/Contents/MacOS"
	cp packaging/app/Info.plist "$(APP)/Contents/Info.plist"
	cp $(BUILD)/app/HPScan "$(APP)/Contents/MacOS/HP Scan"
	codesign --force --sign "$(or $(APP_IDENTITY),-)" "$(APP)"

scan: $(BUILD)/libsane-hpaio.so $(BUILD)/hpscan app

# ---- installer -------------------------------------------------------------
PKG_NAME    := hp-legacy-printers-macos
PKG_ID      := local.hplip.legacy-printers
PKG_VERSION ?= $(HPLIP_VER).4
PKG         := $(BUILD)/$(PKG_NAME).pkg
PKG_ROOT    := $(BUILD)/pkgroot
PPD_DIR     := Library/Printers/PPDs/Contents/Resources/HPLIP
# Signing for distribution. Both identities are auto-detected from the login
# keychain; leave them empty (no certs) to get an unsigned package with ad-hoc
# signed binaries, which is fine for local installs.
#   DEVELOPER_ID       "Developer ID Application: Name (TEAMID)" - signs binaries
#   INSTALLER_IDENTITY "Developer ID Installer: Name (TEAMID)"   - signs the .pkg
#   NOTARY_PROFILE     keychain profile created with `xcrun notarytool store-credentials`
find_identity = $(shell security find-identity -v $(2) 2>/dev/null | sed -n 's/.*"\($(1):[^"]*\)".*/\1/p' | head -1)
DEVELOPER_ID       ?= $(call find_identity,Developer ID Application,-p codesigning)
INSTALLER_IDENTITY ?= $(call find_identity,Developer ID Installer,)
NOTARY_PROFILE     ?= hplip-notary
SIGN_BIN = codesign --force --options runtime --timestamp --sign "$(DEVELOPER_ID)"

pkg: $(PKG)

$(PKG): all packaging/scripts/preinstall packaging/scripts/postinstall packaging/hplip.conf packaging/diagnose.sh packaging/uninstall.sh
	rm -rf $(PKG_ROOT) && mkdir -p $(PKG_ROOT)$(PREFIX)/filter $(PKG_ROOT)$(PREFIX)/bin \
	  $(PKG_ROOT)$(PREFIX)/lib $(PKG_ROOT)$(PREFIX)/etc/hp $(PKG_ROOT)$(PREFIX)/share/hplip/data/models \
	  $(PKG_ROOT)/$(PPD_DIR) $(PKG_ROOT)/Applications $(PKG_ROOT)/private/etc/paths.d
	install -m 755 $(BUILD)/hpcups $(PKG_ROOT)$(FILTER)
	install -m 644 $(PPD_OUT)/*.ppd.gz $(PKG_ROOT)/$(PPD_DIR)/
	install -m 644 $(SUPPORTED_LIST) $(PKG_ROOT)$(PREFIX)/
	install -m 755 $(BUILD)/libsane-hpaio.so $(PKG_ROOT)$(PREFIX)/lib/
	install -m 755 $(BUILD)/hpscan $(PKG_ROOT)$(PREFIX)/bin/
	install -m 644 packaging/hplip.conf $(PKG_ROOT)$(PREFIX)/etc/hp/
	install -m 644 $(HPLIP)/data/models/models.dat $(PKG_ROOT)$(PREFIX)/share/hplip/data/models/
	install -m 755 packaging/uninstall.sh $(PKG_ROOT)$(PREFIX)/uninstall.sh
	install -m 755 packaging/diagnose.sh $(PKG_ROOT)$(PREFIX)/diagnose.sh
	echo $(PREFIX)/bin > $(PKG_ROOT)/private/etc/paths.d/HPLIP
	ditto "$(APP)" "$(PKG_ROOT)/Applications/HP Scan.app"
	xattr -cr $(PKG_ROOT)
ifneq ($(DEVELOPER_ID),)
	@echo "Signing binaries with: $(DEVELOPER_ID)"
	$(SIGN_BIN) $(PKG_ROOT)$(FILTER) $(PKG_ROOT)$(PREFIX)/bin/hpscan $(PKG_ROOT)$(PREFIX)/lib/libsane-hpaio.so
	$(SIGN_BIN) "$(PKG_ROOT)/Applications/HP Scan.app"
else
	@echo "No Developer ID Application identity found: ad-hoc signing (fine for your own Macs)."
	codesign --force --sign - $(PKG_ROOT)$(FILTER) $(PKG_ROOT)$(PREFIX)/bin/hpscan $(PKG_ROOT)$(PREFIX)/lib/libsane-hpaio.so
endif
	COPYFILE_DISABLE=1 pkgbuild --root $(PKG_ROOT) --component-plist packaging/components.plist --scripts packaging/scripts --identifier $(PKG_ID) \
	  --version $(PKG_VERSION) --install-location / --ownership recommended \
	  $(if $(INSTALLER_IDENTITY),--sign "$(INSTALLER_IDENTITY)") $(BUILD)/staging.pkg
	mv -f $(BUILD)/staging.pkg $@
	@$(if $(INSTALLER_IDENTITY),pkgutil --check-signature $@ | head -3,echo "Package is unsigned (no Developer ID Installer identity found).")

# Submit to Apple's notary service and staple the ticket so the package
# installs cleanly on other Macs, even offline.
notarize: pkg
	@test -n "$(INSTALLER_IDENTITY)" || { echo "notarize needs a Developer ID Installer certificate"; exit 1; }
	@test -n "$(DEVELOPER_ID)" || { echo "notarize needs a Developer ID Application certificate"; exit 1; }
	xcrun notarytool submit $(PKG) --keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple $(PKG)
	spctl --assess --type install -vv $(PKG)

clean:
	rm -rf $(BUILD)

distclean: clean
	rm -rf third_party
