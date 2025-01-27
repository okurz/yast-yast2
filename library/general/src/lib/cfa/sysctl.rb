# Copyright (c) [2019] SUSE LLC
#
# All Rights Reserved.
#
# This program is free software; you can redistribute it and/or modify it
# under the terms of version 2 of the GNU General Public License as published
# by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
# FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
# more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, contact SUSE LLC.
#
# To contact SUSE LLC about this file by physical or electronic mail, you may
# find current contact information at www.suse.com.

require "yast"
require "cfa/base_model"
require "yast2/target_file"

module CFA
  # CFA based API to adjust the sysctl tool configuration
  #
  # This class does not modify the running kernel configuration. It just writes
  # the desired values into the configuration file ({PATH}).
  #
  # @example Enabling IPv4 forwarding
  #   sysctl = Sysctl.new
  #   sysctl.forward_ipv4 = true
  #   sysctl.save
  #
  # Although in the previous example we enabled the IPv4 forwarding using by
  # setting +forward_ipv4+ to true. However, under the hood, the kernel maps
  # boolean values to "1" or "0". If you want to access to that raw value,
  # you can prepend "raw_" to the method's name.
  #
  # @example Accessing the raw value of a setting
  #   sysctl = Sysctl.new
  #   sysctl.load
  #   sysctl.raw_forward_ipv6 #=> "0"
  #   sysctl.raw_forward_ipv6 = "1"
  #   sysctl.forward_ipv6? #=> true
  class Sysctl < BaseModel
    include Yast::Logger

    PARSER = AugeasParser.new("sysctl.lns")
    PATH = "/etc/sysctl.d/30-yast.conf".freeze

    class << self
      # Modifies default CFA methods to handle boolean values
      #
      # When getting or setting the value, a boolean value will be expected. Under the hood, it will
      # be translated into "1" or "0". Additionally, to access to the raw value ("1", "0" or +nil+),
      # just prepend "raw_" to the name of the method. Bear in mind that if the raw value is +nil+,
      # it will be considered +false+.
      #
      # @param attrs [Array<Symbol>] Attribute name
      def boolean_attr(*attrs)
        attrs.each do |attr|
          raw_attr = "raw_#{attr}"
          alias_method raw_attr, attr
          define_method attr do
            public_send(raw_attr) == "1"
          end
          alias_method "#{attr}?", attr

          alias_method "#{raw_attr}=", "#{attr}="
          define_method "#{attr}=" do |value|
            str_value = value ? "1" : "0"
            public_send("#{raw_attr}=", str_value)
          end
        end
      end
    end

    ATTRIBUTES = {
      kernel_sysrq:            "kernel.sysrq",
      forward_ipv4:            "net.ipv4.ip_forward",
      # FIXME: alias for ipv6_forwarding_all
      forward_ipv6:            "net.ipv6.conf.all.forwarding",
      ipv4_forwarding_default: "net.ipv4.conf.default.forwarding",
      ipv4_forwarding_all:     "net.ipv4.conf.all.forwarding",
      ipv6_forwarding_default: "net.ipv6.conf.default.forwarding",
      ipv6_forwarding_all:     "net.ipv6.conf.all.forwarding",
      tcp_syncookies:          "net.ipv4.tcp_syncookies",
      disable_ipv6:            "net.ipv6.conf.all.disable_ipv6"
    }.freeze

    attributes(ATTRIBUTES)

    # Keys that are handled by this class
    KNOWN_KEYS = ATTRIBUTES.values.uniq.freeze

    boolean_attr :forward_ipv4, :forward_ipv6, :tcp_syncookies, :disable_ipv6,
      :ipv4_forwarding_default, :ipv4_forwarding_all, :ipv6_forwarding_default,
      :ipv6_forwarding_all

    def initialize(file_handler: Yast::TargetFile)
      super(PARSER, PATH, file_handler: file_handler)
    end

    # Loads sysctl content
    #
    # This method reads {PATH} and uses +/etc/sysctl.conf+ values as fallback.
    def load
      begin
        super
      rescue Errno::ENOENT # PATH does not exist yet
        self.data = @parser.empty
        @loaded = true
      end

      KNOWN_KEYS.each do |key|
        next if data[key]

        old_value = Yast::SCR.Read(SYSCTL_AGENT_PATH + key)
        data[key] = old_value if old_value
      end
      nil
    end

    # Writes sysctl configuration
    #
    # Apart from writing the values to {PATH}, it cleans up the same entries in
    # +/etc/sysctl.conf+ to avoid confusion.
    def save
      super
      clean_old_values
    end

  private

    # Path to the agent to handle the +/etc/sysctl.conf+ file
    SYSCTL_AGENT_PATH = Yast::Path.new(".etc.sysctl_conf")

    # Main sysctl configuration file
    MAIN_SYSCTL_CONF_PATH = "/etc/sysctl.conf".freeze

    # Cleans up present values from +/etc/sysctl.conf+ to reduce confusion
    def clean_old_values
      handler = BaseModel.default_file_handler
      parser = AugeasParser.new("sysctl.lns")
      parser.file_name = MAIN_SYSCTL_CONF_PATH
      content = parser.parse(handler.read(MAIN_SYSCTL_CONF_PATH))
      KNOWN_KEYS.each { |k| content.delete(k) }
      handler.write(MAIN_SYSCTL_CONF_PATH, parser.serialize(content))
    rescue Errno::ENOENT
      log.info "File #{MAIN_SYSCTL_CONF_PATH} was not found"
    end
  end
end
