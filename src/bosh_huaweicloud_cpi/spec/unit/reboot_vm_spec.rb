require 'spec_helper'

describe Bosh::HuaweiCloud::Cloud do
  before :each do
    @server = double('server', id: 'i-foobar')

    @cloud = mock_cloud(mock_cloud_options['properties']) do |fog|
      allow(fog.compute.servers).to receive(:get).with('i-foobar').and_return(@server)
    end
  end

  it 'reboots an OpenStack server (CPI call picks soft reboot)' do
    expect(@cloud).to receive(:soft_reboot).with(@server)
    @cloud.reboot_vm('i-foobar')
  end

  it 'soft reboots an OpenStack server' do
    expect(@server).to receive(:reboot)
    expect(@cloud.openstack).to receive(:wait_resource).with(@server, :active, :state)
    @cloud.send(:soft_reboot, @server)
  end

  it 'hard reboots an OpenStack server' do
    expect(@server).to receive(:reboot)
    expect(@cloud.openstack).to receive(:wait_resource).with(@server, :active, :state)
    @cloud.send(:hard_reboot, @server)
  end
end
