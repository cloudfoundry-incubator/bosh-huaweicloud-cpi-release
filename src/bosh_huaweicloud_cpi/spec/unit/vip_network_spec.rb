require 'spec_helper'

describe Bosh::HuaweiCloud::VipNetwork do
  describe 'configure' do
    subject do
      described_class.new('network_b', network_spec)
    end

    let(:network_spec) { vip_network_spec }

    context 'no floating IP provided for vip network' do
      before(:each) do
        network_spec['ip'] = nil
      end

      it 'fails' do
        expect {
          subject.configure(nil, nil, nil)
        }.to raise_error Bosh::Clouds::CloudError, /No IP provided for vip network/
      end
    end

    context 'floating IP is provided' do
      let(:huaweicloud) { double('huaweicloud') }
      before { allow(huaweicloud).to receive(:with_huaweicloud) { |&block| block.call } }

      it 'calls FloatingIp.reassiciate' do
        server = double('server')
        allow(Bosh::HuaweiCloud::FloatingIp).to receive(:reassociate)

        subject.configure(huaweicloud, server, 'network_id')

        expect(Bosh::HuaweiCloud::FloatingIp).to have_received(:reassociate).with(huaweicloud, '10.0.0.1', server, 'network_id')
      end
    end
  end
end
