require 'spec_helper'

describe Bosh::HuaweiCloud::Cloud do
  it 'deletes an OpenStack volume' do
    volume = double('volume', id: 'v-foobar')

    cloud = mock_cloud do |fog|
      expect(fog.volume.volumes).to receive(:get)
        .with('v-foobar').and_return(volume)
    end

    expect(volume).to receive(:status).and_return(:available)
    expect(volume).to receive(:destroy).and_return(true)
    expect(cloud.huaweicloud).to receive(:wait_resource).with(volume, :deleted, :status, true)

    cloud.delete_disk('v-foobar')
  end

  it "doesn't delete an OpenStack volume unless it's state is `available'" do
    volume = double('volume', id: 'v-foobar')

    cloud = mock_cloud do |fog|
      expect(fog.volume.volumes).to receive(:get).with('v-foobar').and_return(volume)
    end

    expect(volume).to receive(:status).and_return(:busy)

    expect {
      cloud.delete_disk('v-foobar')
    }.to raise_error(Bosh::Clouds::CloudError,
                     "Cannot delete volume `v-foobar', state is busy")
  end
end
