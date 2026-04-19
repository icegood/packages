include $(TOPDIR)/rules.mk

PKG_NAME:=rdfind
PKG_VERSION:=1.8.0
PKG_RELEASE:=1

PKG_SOURCE:=$(PKG_NAME)-$(PKG_VERSION).tar.gz
PKG_SOURCE_URL:=https://github.com/pauldreik/rdfind/releases/download/releases%2F$(PKG_VERSION)
PKG_HASH:=0a2d0d32002cc2dc0134ee7b649bcc811ecfb2f8d9f672aa476a851152e7af35

PKG_LICENSE:=GPL-2.0-or-later
PKG_LICENSE_FILES:=COPYING
PKG_MAINTAINER:=Your Name <you@example.com>

# Tell OpenWrt to handle autoreconf automatically
PKG_FIXUP:=autoreconf

# Build dependency on the SOURCE package name
PKG_BUILD_DEPENDS:=nettle

include $(INCLUDE_DIR)/package.mk

define Package/rdfind
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=Find duplicate files
  URL:=https://github.com/pauldreik/rdfind
  # Runtime dependency on the BINARY package name
  DEPENDS:=+libstdcpp +libnettle
endef

define Package/rdfind/description
  rdfind is a command line tool that finds duplicate files based on content.
endef

CONFIGURE_ARGS += \
    --disable-nls

# Ensure modern C++ via the toolchain
TARGET_CXXFLAGS += -std=c++17

define Package/rdfind/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/rdfind $(1)/usr/bin/
endef

$(eval $(call BuildPackage,rdfind))