require 'rspec'

ENV["Y2DIR"] = File.expand_path("../../src", __FILE__)

require "yast"

module SystemctlStubs

  def stub_systemctl
    stub_socket_unit_files
    stub_socket_units
    stub_execute
  end


  def stub_execute success: true
    Yast::Systemctl.stub(:execute).and_return(
      OpenStruct.new \
      :stdout => 'success',
      :stderr => ( success ? '' : 'failure'),
      :exit   => ( success ? 0  : 1 )
    )
  end

  def stub_socket_unit_files
    Yast::Systemctl.stub(:list_unit_files).and_return(<<LIST
iscsid.socket                disabled
avahi-daemon.socket          enabled
cups.socket                  enabled
dbus.socket                  static
dm-event.socket              disabled
LIST
    )
  end

  def stub_socket_units
    Yast::Systemctl.stub(:list_units).and_return(<<LIST
iscsid.socket                loaded active   listening Open-iSCSI iscsid Socket
avahi-daemon.socket          loaded active   running   Avahi mDNS/DNS-SD Stack Activation Socket
cups.socket                  loaded inactive dead      CUPS Printing Service Sockets
dbus.socket                  loaded active   running   D-Bus System Message Bus Socket
dm-event.socket              loaded inactive dead      Device-mapper event daemon FIFOs
lvm2-lvmetad.socket          loaded inactive dead      LVM2 metadata daemon socket
pcscd.socket                 loaded active   listening PC/SC Smart Card Daemon Activation Socket
LIST
    )
  end

end

module SystemdUnitStubs
  def stub_unit_command success: true
    Yast::SystemdUnit
      .any_instance
      .stub(:command)
      .and_return(
        OpenStruct.new \
        :stdout => 'success',
        :stderr => ( success ? '' : 'failure'),
        :exit   => ( success ? 0  : 1 )
      )
  end
end

module SystemdSocketStubs
  include SystemctlStubs
  include SystemdUnitStubs

  def socket_properties
    @properties ||= OpenStruct.new(
      :stdout => File.read(File.join(__dir__, 'data', 'iscsid_socket_properties')),
      :stderr => '',
      :exit   => 0
      )
  end

  def stub_sockets
    stub_unit_command
    stub_systemctl
    stub_socket_properties
  end

  def stub_socket_properties
    Yast::SystemdUnit::Properties
      .any_instance
      .stub(:load_systemd_properties)
      .and_return(socket_properties)
  end

end

