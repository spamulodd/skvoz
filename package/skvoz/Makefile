#
# Skvoz — OpenWrt package (arch-independent scripts/rules)
# Place this directory under SDK package/ and build with: make package/skvoz/compile V=s
#

include $(TOPDIR)/rules.mk

PKG_NAME:=skvoz
PKG_VERSION:=1.0.1
PKG_RELEASE:=1

PKG_MAINTAINER:=Skvoz
PKG_LICENSE:=MIT

PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)-$(PKG_VERSION)

# Repo layout: rvpn/openwrt/ and rvpn/package/skvoz/
SKVOZ_SRC_DIR:=$(abspath $(CURDIR)/../../openwrt)

include $(INCLUDE_DIR)/package.mk

define Package/skvoz
	SECTION:=net
	CATEGORY:=Network
	TITLE:=Skvoz hybrid bypass (zapret + VPN)
	URL:=https://github.com/
	DEPENDS:=+libnetfilter-queue +kmod-nfnetlink-queue +kmod-nft-queue +kmod-nft-tproxy +curl +ca-bundle
	PKGARCH:=all
endef

define Package/skvoz/description
	Skvoz: zapret DPI bypass + narrow VPN for hard-blocked services on OpenWrt.
	Installs rvpn scripts, rules, web UI, and init integration. nfqws binary is external.
endef

define Package/skvoz/conffiles
/etc/config/rvpn
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
endef

define Build/Compile
	# arch-independent shell package
endef

define Package/skvoz/install
	$(INSTALL_DIR) $(1)/usr/lib/rvpn
	$(INSTALL_BIN) $(SKVOZ_SRC_DIR)/usr/lib/rvpn/*.sh $(1)/usr/lib/rvpn/

	$(INSTALL_DIR) $(1)/usr/share/rvpn/rules
	$(INSTALL_DATA) $(SKVOZ_SRC_DIR)/usr/share/rvpn/rules/* $(1)/usr/share/rvpn/rules/

	$(INSTALL_DIR) $(1)/www/rvpn/cgi-bin
	$(INSTALL_DATA) $(SKVOZ_SRC_DIR)/www/rvpn/index.html $(1)/www/rvpn/
	$(INSTALL_BIN) $(SKVOZ_SRC_DIR)/www/rvpn/cgi-bin/rvpn.cgi $(1)/www/rvpn/cgi-bin/

	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) $(SKVOZ_SRC_DIR)/etc/init.d/rvpn $(1)/etc/init.d/

	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) $(SKVOZ_SRC_DIR)/etc/config/rvpn $(1)/etc/config/

	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(SKVOZ_SRC_DIR)/usr/bin/rvpnctl $(1)/usr/bin/

	$(INSTALL_DIR) $(1)/opt/rvpn
endef

define Package/skvoz/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
chmod +x /etc/init.d/rvpn /usr/bin/rvpnctl /www/rvpn/cgi-bin/rvpn.cgi 2>/dev/null || true
chmod +x /usr/lib/rvpn/*.sh 2>/dev/null || true
mkdir -p /opt/rvpn /tmp/rvpn
chmod 700 /tmp/rvpn 2>/dev/null || true
lan=$$(uci -q get network.lan.ipaddr 2>/dev/null)
lan=$${lan%%/*}
case "$$lan" in *[!0-9.]*|'') lan=192.168.1.1 ;; esac
uci -q delete uhttpd.rvpn
uci set uhttpd.rvpn=uhttpd
uci set uhttpd.rvpn.listen_http="$$lan:81"
uci set uhttpd.rvpn.home='/www/rvpn'
uci set uhttpd.rvpn.cgi_prefix='/cgi-bin'
uci set uhttpd.rvpn.script_timeout='120'
uci set uhttpd.rvpn.network_timeout='60'
uci set uhttpd.rvpn.tcp_keepalive='1'
uci set uhttpd.rvpn.rfc1918_filter='1'
uci set uhttpd.rvpn.max_requests='40'
uci commit uhttpd
# Do not force layers OFF on upgrade (defaults are in /etc/config/rvpn)
if [ -f /usr/lib/rvpn/common.sh ]; then
	. /usr/lib/rvpn/common.sh
	ensure_ui_secret >/dev/null 2>&1 || true
	ensure_clash_secret >/dev/null 2>&1 || true
fi
uci commit rvpn
/etc/init.d/uhttpd restart 2>/dev/null || true
/etc/init.d/rvpn enable
/etc/init.d/rvpn stop 2>/dev/null || true
exit 0
endef

define Package/skvoz/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
/etc/init.d/rvpn stop 2>/dev/null || true
/etc/init.d/rvpn disable 2>/dev/null || true
exit 0
endef

$(eval $(call BuildPackage,skvoz))
