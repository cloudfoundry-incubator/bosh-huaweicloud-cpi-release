require 'spec_helper'

describe Bosh::HuaweiCloud::ServerGroups do
  let(:logger) { instance_double(Logger, error: nil) }

  let(:lock_file_folder) {
    File.join(Dir.tmpdir, 'huaweicloud-server-groups')
  }

  let(:bosh_group) {
    'director_name-deployment_name-instance_group_name'
  }

  let(:fog_server_groups) {
    double(:compute_server_groups, all: [],
                                   create: OpenStruct.new('id' => 'fake-server-group-id', 'name' => "fake-uuid-#{bosh_group}", 'policy' => 'soft-anti-affinity'))
  }

  let(:huaweicloud) {
    double('huaweicloud', compute: double(:compute, server_groups: fog_server_groups))
  }

  subject(:server_groups) {
    Bosh::HuaweiCloud::ServerGroups.new(huaweicloud)
  }

  after do
    FileUtils.rm_rf(lock_file_folder)
  end

  before do
    allow(Bosh::Clouds::Config).to receive(:logger).and_return(logger)
    allow(huaweicloud).to receive(:with_huaweicloud) { |&block| block.call }
    allow(huaweicloud).to receive(:is_v3).and_return(version == 'v3' ? true : false)
  end

  let(:version) {
    'v3'
  }

  it 'uses name derived from uuid and bosh groups' do
    server_groups.find_or_create('fake-uuid', bosh_group)

    expect(fog_server_groups).to have_received(:create).with("fake-uuid-#{bosh_group}", 'soft-anti-affinity')
  end

  it 'uses a lock file to synchronize getting and creating server groups' do
    server_groups.find_or_create('fake-uuid', bosh_group)

    expect(File.exist?(File.join(lock_file_folder, "#{bosh_group}.lock"))).to be true
  end

  it 'uses a lock file to synchronize deletion of server groups' do
    server_groups.delete_if_no_members('fake-uuid', bosh_group)

    expect(File.exist?(File.join(lock_file_folder, "#{bosh_group}.lock"))).to be true
  end

  context 'when a server_group with soft-anti-affinity policy already exists for this name' do
    before(:each) do
      allow(huaweicloud.compute).to receive(:delete_server_group)
    end

    context 'when there are no members in the server group' do
      let(:fog_server_groups) {
        double(:compute_server_groups, all:
            [
              OpenStruct.new('id' => '456', 'name' => "fake-uuid-#{bosh_group}", 'policies' => ['anti-affinity'], 'members' => []),
              OpenStruct.new('id' => '123', 'name' => "fake-uuid-#{bosh_group}", 'policies' => ['soft-anti-affinity'], 'members' => []),
              OpenStruct.new('id' => '234', 'name' => 'other-uuid-other-group', 'policies' => ['soft-anti-affinity'], 'members' => []),
            ],
                                       create: OpenStruct.new('id' => 'fake-server-group-id', 'name' => "fake-uuid-#{bosh_group}", 'policy' => 'soft-anti-affinity'))
      }

      it 'returns id of existing server group' do
        id = server_groups.find_or_create('fake-uuid', bosh_group)

        expect(fog_server_groups).to have_received(:all)
        expect(fog_server_groups).to_not have_received(:create)
        expect(id).to eq('123')
      end

      it 'deletes the server group' do
        server_groups.delete_if_no_members('fake-uuid', bosh_group)

        expect(fog_server_groups).to have_received(:all)
        expect(huaweicloud.compute).to have_received(:delete_server_group).with('123')
      end
    end

    context 'when there are members in the server group' do
      let(:fog_server_groups) {
        double(:compute_server_groups, all:
            [OpenStruct.new('id' => '123', 'name' => "fake-uuid-#{bosh_group}", 'policies' => ['soft-anti-affinity'], 'members' => ['member_1'])])
      }

      it 'does not delete the server group' do
        server_groups.delete_if_no_members('fake-uuid', bosh_group)

        expect(fog_server_groups).to have_received(:all)
        expect(huaweicloud.compute).to_not have_received(:delete_server_group)
      end
    end
  end

  context 'when no server group exists for that name' do
    it 'creates the server group and returns id' do
      id = server_groups.find_or_create('fake-uuid', bosh_group)

      expect(fog_server_groups).to have_received(:all)
      expect(fog_server_groups).to have_received(:create)
      expect(id).to eq('fake-server-group-id')
    end
  end

  %w(v2 v3).each do |keystone_version|
    context "when keystone #{keystone_version} is used" do
      let(:version) {
        keystone_version
      }

      before(:each) do
        if keystone_version == 'v2'
          allow(huaweicloud).to receive(:project_name).and_return('my-project')
        else
          allow(huaweicloud).to receive(:project_name).and_return('my-project')
        end
      end

      context 'when quota of server groups is reached' do
        before(:each) do
          allow(fog_server_groups).to receive(:create).and_raise(Excon::Error::Forbidden.new('Quota exceeded, too many server groups'))
        end

        it 'raises a cloud error' do
          expect {
            server_groups.find_or_create('fake-uuid', bosh_group)
          }.to raise_error(Bosh::Clouds::CloudError, "You have reached your quota for server groups for project 'my-project'. Please disable auto-anti-affinity server groups or increase your quota.")
        end
      end

      context 'when quota of members in a server group is reached' do
        before(:each) do
          allow(fog_server_groups).to receive(:create).and_raise(Excon::Error::Forbidden.new('Quota exceeded, too many servers in group'))
        end

        it 'raises a cloud error' do
          expect{
            server_groups.find_or_create('fake-uuid', bosh_group)
          }.to raise_error(Bosh::Clouds::CloudError, "You have reached your quota for members in a server group for project 'my-project'. Please disable auto-anti-affinity server groups or increase your quota.")
        end
      end
    end
  end

  context "when HuaweiCloud does not support 'soft-anti-affinity'" do
    before(:each) do
      allow(fog_server_groups).to receive(:create).and_raise(Excon::Error::BadRequest.new("Invalid input for field/attribute 0. Value: soft-anti-affinity. u'soft-anti-affinity' is not one of ['anti-affinity', 'affinity']"))
    end

    it 'raises a cloud error and logs message as well as excon bad request error' do
      message_logged = false
      exception_logged = false
      allow(logger).to receive(:error) do |arg|
        if arg == "Auto-anti-affinity is only supported on HuaweiCloud Mitaka or higher. Please upgrade or set 'huaweicloud.enable_auto_anti_affinity=false'."
          message_logged = true
        elsif arg.is_a? Excon::Error::BadRequest
          exception_logged = true
        end
      end

      expect {
        server_groups.find_or_create('fake-uuid', bosh_group)
      }.to raise_error(Bosh::Clouds::CloudError, "Auto-anti-affinity is only supported on HuaweiCloud Mitaka or higher. Please upgrade or set 'huaweicloud.enable_auto_anti_affinity=false'.")
      expect(message_logged).to be(true)
      expect(exception_logged).to be(true)
    end
  end

end
