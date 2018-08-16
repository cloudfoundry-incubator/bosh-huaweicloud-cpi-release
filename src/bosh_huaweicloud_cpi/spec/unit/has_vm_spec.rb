require 'spec_helper'

describe Bosh::HuaweiCloud::Cloud do
  it 'has_vm? returns true if HuaweiCloud server exists' do
    server = double('server', id: 'i-foobar', state: :active)
    cloud = mock_cloud(mock_cloud_options['properties']) do |fog|
      allow(fog.compute.servers).to receive(:get).with('i-foobar').and_return(server)
    end
    expect(cloud.has_vm?('i-foobar')).to be(true)
  end

  it "has_vm? returns false if HuaweiCloud server doesn't exists" do
    cloud = mock_cloud(mock_cloud_options['properties']) do |fog|
      allow(fog.compute.servers).to receive(:get).with('i-foobar').and_return(nil)
    end
    expect(cloud.has_vm?('i-foobar')).to be(false)
  end

  it 'has_vm? returns false if HuaweiCloud server state is :terminated' do
    server = double('server', id: 'i-foobar', state: :terminated)
    cloud = mock_cloud(mock_cloud_options['properties']) do |fog|
      allow(fog.compute.servers).to receive(:get).with('i-foobar').and_return(server)
    end
    expect(cloud.has_vm?('i-foobar')).to be(false)
  end

  it 'has_vm? returns false if HuaweiCloud server state is :deleted' do
    server = double('server', id: 'i-foobar', state: :deleted)
    cloud = mock_cloud(mock_cloud_options['properties']) do |fog|
      allow(fog.compute.servers).to receive(:get).with('i-foobar').and_return(server)
    end
    expect(cloud.has_vm?('i-foobar')).to be(false)
  end
end
