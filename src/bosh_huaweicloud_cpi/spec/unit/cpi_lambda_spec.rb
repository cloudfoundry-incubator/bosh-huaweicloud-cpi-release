require 'spec_helper'

describe Bosh::HuaweiCloud::CpiLambda do
  subject { described_class.create(cpi_config, cpi_log, ssl_ca_file, ca_cert_from_context) }
  let(:cpi_config) {
    {
      'cloud' => {
        'properties' => {
          'huaweicloud' => {
            'key1' => 'value1',
            'key2' => 'value2',
          },
        },
      },
    }
  }
  let(:ssl_ca_file) { 'feel-free-to-change' }
  let(:cpi_log) { StringIO.new }
  let(:ca_cert_from_context) { Tempfile.new('ca_cert').path }

  describe 'when creating a cloud' do
    it 'passes parts of the cpi config to huaweicloud' do
      expect(Bosh::Clouds::Huawei).to receive(:new).with('huaweicloud' => cpi_config['cloud']['properties']['huaweicloud'],
                                                            'cpi_log' => cpi_log)
      subject.call({})
    end

    context 'if invalid cpi config is given' do
      let(:cpi_config) { { 'empty' => 'config' } }

      it 'raises an error' do
        expect {
          subject.call({})
        }.to raise_error /Could not find cloud properties in the configuration/
      end
    end

    context 'if using ca_certs in config' do
      let(:cpi_config) { { 'cloud' => { 'properties' => { 'huaweicloud' => { 'connection_options' => { 'ca_cert' => 'xyz' } } } } } }

      it 'sets ssl_ca_file that is passed and removes ca_certs' do
        expect(Bosh::Clouds::Huawei).to receive(:new).with('huaweicloud' => { 'connection_options' => { 'ssl_ca_file' => ssl_ca_file } },
                                                              'cpi_log' => cpi_log)
        subject.call({})
      end
    end

    context 'if huaweicloud properties are provided in the context' do
      it 'merges the huaweicloud properties' do
        context = {
          'newkey' => 'newvalue',
          'newkey2' => 'newvalue2',
        }

        expect(Bosh::Clouds::Huawei).to receive(:new).with('huaweicloud' => { 'key1' => 'value1',
                                                                               'key2' => 'value2',
                                                                               'newkey' => 'newvalue',
                                                                               'newkey2' => 'newvalue2' },
                                                              'cpi_log' => cpi_log)
        subject.call(context)
      end

      it 'writes the given ca_cert to the disk and sets ssl_ca_file to its path' do
        context = {
          'newkey' => 'newvalue',
          'connection_options' => { 'ca_cert' => 'xyz' },
        }

        expect(Bosh::Clouds::Huawei).to receive(:new).with('huaweicloud' => { 'newkey' => 'newvalue',
                                                                               'key1' => 'value1',
                                                                               'key2' => 'value2',
                                                                               'connection_options' => { 'ssl_ca_file' => ca_cert_from_context } },
                                                              'cpi_log' => cpi_log)

        subject.call(context)
        expect(File.read(ca_cert_from_context)).to eq('xyz')
      end

      context 'when the context does not include a ca_cert' do
        it 'does not write into the file' do
          allow(Bosh::Clouds::Huawei).to receive(:new)

          subject.call({})

          expect(File.read(ca_cert_from_context)).to eq('')
        end
      end
    end
  end
end
