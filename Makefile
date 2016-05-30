include config.mk

# get main- and subtarget name from TARGET
MAINTARGET=$(word 1, $(subst _, ,$(TARGET)))
SUBTARGET=$(word 2, $(subst _, ,$(TARGET)))

# set dir and file names
FW_DIR=$(shell pwd)
LEDE_DIR=$(FW_DIR)/lede
TARGET_CONFIG=$(FW_DIR)/configs/$(TARGET).config
IB_BUILD_DIR=$(FW_DIR)/imagebuilder_tmp
FW_TARGET_DIR=$(FW_DIR)/firmwares/$(TARGET)
UMASK=umask 022

# if any of the following files have been changed: clean up lede dir
DEPS=$(TARGET_CONFIG) feeds.conf patches $(wildcard patches/*)

# profiles to be built (router models)
PROFILES=$(shell cat $(FW_DIR)/profiles/$(TARGET).profiles)

default: firmwares

# clone lede
$(LEDE_DIR):
	git clone $(LEDE_SRC) $(LEDE_DIR)

# clean up lede working copy
lede-clean: stamp-clean-lede-cleaned .stamp-lede-cleaned
.stamp-lede-cleaned: config.mk | $(LEDE_DIR)
	cd $(LEDE_DIR); \
	  ./scripts/feeds clean && \
	  git clean -dff && git fetch && git reset --hard HEAD && \
	  rm -rf bin .config feeds.conf build_dir/target-*
	touch $@

# update lede and checkout specified commit
lede-update: stamp-clean-lede-updated .stamp-lede-updated
.stamp-lede-updated: .stamp-lede-cleaned
	cd $(LEDE_DIR); git checkout --detach $(LEDE_COMMIT)
	touch $@

# patches require updated lede working copy
$(LEDE_DIR)/patches: | .stamp-lede-updated
	ln -s $(FW_DIR)/patches $(LEDE_DIR)

# feeds
$(LEDE_DIR)/feeds.conf: .stamp-lede-updated
	cp $(FW_DIR)/feeds.conf $(LEDE_DIR)/feeds.conf

# update feeds
feeds-update: stamp-clean-feeds-updated .stamp-feeds-updated
.stamp-feeds-updated: $(LEDE_DIR)/feeds.conf
	+cd $(LEDE_DIR); \
	  ./scripts/feeds uninstall -a && \
	  ./scripts/feeds update && \
	  ./scripts/feeds install -a
	touch $@

# prepare patch
pre-patch: stamp-clean-pre-patch .stamp-pre-patch
.stamp-pre-patch: .stamp-feeds-updated $(wildcard $(FW_DIR)/patches/*) | $(LEDE_DIR)/patches
	touch $@

# patch lede working copy
patch: stamp-clean-patched .stamp-patched
.stamp-patched: .stamp-pre-patch
	cd $(LEDE_DIR); quilt push -a
	touch $@

# lede config
$(LEDE_DIR)/.config: .stamp-feeds-updated $(TARGET_CONFIG)
	cp $(TARGET_CONFIG) $(LEDE_DIR)/.config
	$(UMASK); \
	  $(MAKE) -C lede defconfig

# prepare lede working copy
prepare: stamp-clean-prepared .stamp-prepared
.stamp-prepared: .stamp-patched $(LEDE_DIR)/.config
	touch $@

# compile
compile: stamp-clean-compiled .stamp-compiled
.stamp-compiled: .stamp-prepared
	$(UMASK); \
	  $(MAKE) -C lede IGNORE_ERRORS=m $(MAKE_ARGS)
	touch $@

# fill firmwares-directory with:
#  * firmwares built with imagebuilder
#  * imagebuilder file
#  * packages directory
firmwares: stamp-clean-firmwares .stamp-firmwares
.stamp-firmwares: .stamp-compiled
	rm -rf $(IB_BUILD_DIR)
	mkdir -p $(IB_BUILD_DIR)
	$(eval TOOLCHAIN_PATH := $(shell printf "%s:" $(LEDE_DIR)/staging_dir/toolchain-*/bin))
	$(eval IB_FILE := $(shell ls $(LEDE_DIR)/bin/targets/$(MAINTARGET)/$(SUBTARGET)/*-imagebuilder*.tar.bz2))
	$(eval IB_DIR := $(shell basename $(IB_FILE) .tar.bz2))
	cd $(IB_BUILD_DIR); tar xf $(IB_FILE)
	export PATH=$(PATH):$(TOOLCHAIN_PATH); \
	PACKAGES_PATH="$(FW_DIR)/packages"; \
	for PROFILE in $(PROFILES); do \
	  for PACKAGES_FILE in $(PACKAGES_LIST_DEFAULT); do \
	    if [[ $$PROFILE =~ ":" ]]; then \
	      SUFFIX="$$(echo $$PROFILE | cut -d':' -f 2)"; \
	      PACKAGES_SUFFIXED="$$(PACKAGES_FILE)_$$(SUFFIX)"; \
	      if [[ -f "$$PACKAGES_PATH/$$PACKAGES_SUFFIXED.txt" ]]; then \
	        PACKAGES_FILE="$$PACKAGES_SUFFIXED"; \
	        PROFILE=$$(echo $$PROFILE | cut -d':' -f 1); \
	      fi; \
	    fi; \
	    PACKAGES_FILE_ABS="$$PACKAGES_PATH/$$PACKAGES_FILE.txt"; \
	    PACKAGES_LIST=$$(grep -v '^\#' $$PACKAGES_FILE_ABS | tr -t '\n' ' '); \
	    $(UMASK);\
	    $(MAKE) -C $(IB_BUILD_DIR)/$(IB_DIR) image PROFILE="$$PROFILE" PACKAGES="$$PACKAGES_LIST" BIN_DIR="$(IB_BUILD_DIR)/$(IB_DIR)/bin/$$PACKAGES_FILE" || exit 1; \
	  done; \
	done
	mkdir -p $(FW_TARGET_DIR)
	# copy different firmwares (like vpn, minimal) including imagebuilder
	for DIR_ABS in $(IB_BUILD_DIR)/$(IB_DIR)/bin/*; do \
	  TARGET_DIR=$(FW_TARGET_DIR)/$$(basename $$DIR_ABS); \
	  rm -rf $$TARGET_DIR; \
	  mv $$DIR_ABS $$TARGET_DIR; \
	done;
	# copy imagebuilder, sdk and toolchain (if existing)
	cp -a $(LEDE_DIR)/bin/targets/$(MAINTARGET)/$(SUBTARGET)/*.tar.bz2 $(FW_TARGET_DIR)/
	# copy packages
	PACKAGES_DIR="$(FW_TARGET_DIR)/packages"; \
	rm -rf $$PACKAGES_DIR; \
	cp -a $(LEDE_DIR)/bin/targets/$(MAINTARGET)/$(SUBTARGET)/packages $$PACKAGES_DIR
	# TODO: missing /bin/packages/
	rm -rf $(IB_BUILD_DIR)
	touch $@

stamp-clean-%:
	rm -f .stamp-$*

stamp-clean:
	rm -f .stamp-*

clean: stamp-clean .stamp-lede-cleaned

.PHONY: lede-clean lede-update patch feeds-update prepare compile firmwares stamp-clean clean
.NOTPARALLEL:
