require_relative './spec_helper'

describe Bosh::HuaweiCloud::Cloud do
  before(:all) do
    @config = IntegrationConfig.new
    @cpi_for_stemcell = @config.create_cpi
    @stemcell_id, = upload_stemcell(@cpi_for_stemcell, @config.stemcell_path)
  end

  before { allow(Bosh::Clouds::Config).to receive(:logger).and_return(@config.logger) }

  after(:all) do
    @cpi_for_stemcell.delete_stemcell(@stemcell_id)
  end

  let(:boot_from_volume) { false }
  let(:config_drive) { nil }
  let(:use_dhcp) { true }
  let(:human_readable_vm_names) { false }
  let(:use_nova_networking) { false }
  let(:enable_auto_anti_affinity) { false }
  let(:huaweicloud) { @config.create_huaweicloud }

  subject(:cpi) do
    @config.create_cpi(boot_from_volume: boot_from_volume, config_drive: config_drive, human_readable_vm_names: human_readable_vm_names, use_nova_networking: use_nova_networking, use_dhcp: use_dhcp, enable_auto_anti_affinity: enable_auto_anti_affinity)
  end

  before { allow(Bosh::Cpi::RegistryClient).to receive(:new).and_return(double('registry').as_null_object) }

  describe 'dynamic network' do
    # even for dynamic networking we need to set the subnet_id as we may be in an environment
    # with multiple networks
    let(:network_spec) do
      {
        'default' => {
          'type' => 'dynamic',
          'cloud_properties' => {
            'subnet_id' => @config.subnet_id,
          },
        },
      }
    end

    context 'without existing disks and with a floating ip' do
      let(:network_spec_with_vip_network) do
        {
          'vip_network' => {
            'type' => 'vip',
              'ip' => @config.floating_ip,
          },
        }.merge(network_spec)
      end

      before { @vm_with_assigned_floating_ip = create_vm(@stemcell_id, network_spec_with_vip_network, []) }
      after { clean_up_vm(@vm_with_assigned_floating_ip) if @vm_with_assigned_floating_ip }

      it 'exercises the vm lifecycle and reassigns the floating ip' do
        vm_lifecycle(@stemcell_id, network_spec_with_vip_network)
      end
    end

    context 'with existing disks' do
      before do
        @temp_vm_cid = create_vm(@stemcell_id, network_spec, [])
        @existing_volume_id = cpi.create_disk(2048, {}, @temp_vm_cid)
        cpi.delete_vm(@temp_vm_cid)
      end
      after { cpi.delete_disk(@existing_volume_id) if @existing_volume_id }

      it 'exercises the vm lifecycle' do
        expect {
          vm_lifecycle(@stemcell_id, network_spec, @existing_volume_id)
        }.to_not raise_error
      end
    end

    describe 'set_vm_metadata' do
      let(:human_readable_vm_names) { true }
      before { @human_readable_vm_name_id = create_vm(@stemcell_id, network_spec, []) }
      after { clean_up_vm(@human_readable_vm_name_id) if @human_readable_vm_name_id }

      it 'sets the vm name according to the metadata' do
        vm = huaweicloud.compute.servers.get(@human_readable_vm_name_id)
        expect(vm.name).to eq 'huaweicloud_cpi_spec/instance_id'
      end
    end
  end

  describe 'manual network' do
    let(:network_spec) do
      {
        'default' => {
          'type' => 'manual',
          'ip' => @config.manual_ip,
          'cloud_properties' => {
            'subnet_id' => @config.subnet_id,
          },
        },
      }
    end

    context 'without existing disks' do
      it 'exercises the vm lifecycle' do
        expect {
          vm_lifecycle(@stemcell_id, network_spec)
        }.to_not raise_error
      end
    end

    context 'with existing disks' do
      before do
        @temp_vm_cid = create_vm(@stemcell_id, network_spec, [])
        @existing_volume_id = cpi.create_disk(2048, {}, @temp_vm_cid)
        clean_up_vm(@temp_vm_cid)
      end

      after { cpi.delete_disk(@existing_volume_id) if @existing_volume_id }

      it 'exercises the vm lifecycle' do
        expect {
          vm_lifecycle(@stemcell_id, network_spec, @existing_volume_id)
        }.to_not raise_error
      end
    end

    context 'with multiple networks and config_drive' do
      let(:multiple_network_spec) do
        {
          'network_1' => {
            'type' => 'manual',
            'ip' => @config.no_dhcp_manual_ip_1,
            'cloud_properties' => {
              'subnet_id' => @config.net_id_no_dhcp_1,
            },
          },
          'network_2' => {
            'type' => 'manual',
            'ip' => @config.no_dhcp_manual_ip_2,
            'cloud_properties' => {
              'subnet_id' => @config.net_id_no_dhcp_2,
            },
            'use_dhcp' => false,
          },
        }
      end

      let(:config_drive) { 'cdrom' }
      let(:use_dhcp) { false }

      after { clean_up_vm(@multiple_nics_vm_id) if @multiple_nics_vm_id }

      it 'creates writes the mac addresses of the two networks to the registry' do
        registry = double('registry')
        registry_settings = nil
        allow(Bosh::Cpi::RegistryClient).to receive(:new).and_return(registry)
        allow(registry).to receive_messages(endpoint: nil, delete_settings: nil)
        allow(registry).to receive(:update_settings) do |_, settings|
          registry_settings = settings
        end

        @multiple_nics_vm_id = create_vm(@stemcell_id, multiple_network_spec, [])

        vm = huaweicloud.compute.servers.get(@multiple_nics_vm_id)
        network_interfaces = vm.addresses.map { |_, network_interfaces| network_interfaces }.flatten
        network_interface_1 = network_interfaces.find(&where_ip_address_is(@config.no_dhcp_manual_ip_1))
        network_interface_2 = network_interfaces.find(&where_ip_address_is(@config.no_dhcp_manual_ip_2))

        expect(network_interface_1['OS-EXT-IPS-MAC:mac_addr']).to eq(registry_settings['networks']['network_1']['mac'])
        expect(network_interface_2['OS-EXT-IPS-MAC:mac_addr']).to eq(registry_settings['networks']['network_2']['mac'])

        ports = huaweicloud.network.ports.all(device_id: @multiple_nics_vm_id)
        clean_up_vm(@multiple_nics_vm_id) if @multiple_nics_vm_id
        expect(ports.find { |port| huaweicloud.network.ports.get port.id }).to be_nil
      end

      def where_ip_address_is(ip)
        ->(network_interface) { network_interface['addr'] == ip }
      end
    end

    context 'with vrrp' do
      before { @vm_with_vrrp_ip = create_vm(@stemcell_id, network_spec, [], { 'allowed_address_pairs' => @config.allowed_address_pairs }) }
      after { clean_up_vm(@vm_with_vrrp_ip) if @vm_with_vrrp_ip }

      it 'adds vrrp_ip as allowed_address_pairs' do
        vrrp_port = huaweicloud.network.ports.all(fixed_ips: "ip_address=#{@config.manual_ip}")[0]
        port_info = huaweicloud.network.get_port(vrrp_port.id)
        expect(port_info).to be

        allowed_address_pairs = port_info[:body]['port']['allowed_address_pairs']
        expect(allowed_address_pairs.size).not_to be_zero

        assigned_allowed_address_pairs = allowed_address_pairs[0]['ip_address']

        expect(assigned_allowed_address_pairs).to eq(@config.allowed_address_pairs)
      end
    end
  end

  context 'when booting from volume' do
    let(:boot_from_volume) { true }
    let(:network_spec) do
      {
        'default' => {
          'type' => 'manual',
          'ip' => @config.manual_ip,
          'cloud_properties' => {
            'subnet_id' => @config.subnet_id,
          },
        },
      }
    end

    def test_boot_volume(resource_pool = {})
      @vm_id = create_vm(@stemcell_id, network_spec, [], resource_pool)
      volumes = volumes(@vm_id)
      expect(volumes.size).to eq(1)
      expect(volumes.first['device']).to eq('/dev/vda')
    end

    after(:each) { clean_up_vm(@vm_id) if @vm_id }

    it 'creates a vm with boot_volume on /dev/vda' do
      test_boot_volume
    end

    context 'when boot_from_volume defined in the cloud_properties' do
      let(:boot_from_volume) { false }

      it 'creates a vm with boot_volume on /dev/vda' do
        test_boot_volume({ 'boot_from_volume' => true })
      end
    end

    context 'and flavor has root disk size 0' do
      let(:resource_pool) do
        {
          'instance_type' => @config.instance_type_with_no_root_disk,
        }
      end

      context 'and root disk size given in manifest' do
        before do
          resource_pool['root_disk'] = {
            'size' => 20,
          }
        end

        it 'creates a vm with boot_volume on /dev/vda' do
          test_boot_volume
        end
      end

      context 'and root disk size not given in manifest' do
        it 'raises an error' do
          expect {
            vm_lifecycle(@stemcell_id, network_spec, nil, {}, resource_pool)
          }.to raise_error(Bosh::Clouds::CloudError, /Flavor '#{@config.instance_type_with_no_root_disk}' has a root disk size of 0/)
        end
      end
    end
  end

  context 'when using cloud_properties and specifying security groups' do
    let(:cloud_properties) { { 'type' => @config.volume_type } }
    let(:security_group) {}
    let(:network_spec) do
      {
        'default' => {
          'type' => 'dynamic',
          'cloud_properties' => {
            'subnet_id' => @config.subnet_id,
            'security_groups' => [security_group],
          },
        },
      }
    end

    context 'when security group is specified by name' do
      let(:security_group) { @config.security_group_name }

      it 'exercises the vm lifecycle' do
        expect {
          vm_lifecycle(@stemcell_id, network_spec, nil, cloud_properties)
        }.to_not raise_error
      end
    end

    context 'when security group is specified by id' do
      let(:security_group) { @config.security_group_id }

      it 'exercises the vm lifecycle' do
        expect {
          vm_lifecycle(@stemcell_id, network_spec, nil, cloud_properties)
        }.to_not raise_error
      end
    end
  end

  context 'when using config drive as cdrom' do
    let(:config_drive) { @config.config_drive }

    let(:network_spec) do
      {
        'default' => {
          'type' => 'dynamic',
          'cloud_properties' => {
            'subnet_id' => @config.subnet_id,
          },
        },
      }
    end

    it 'exercises the vm lifecycle' do
      expect {
        vm_lifecycle(@stemcell_id, network_spec)
      }.to_not raise_error
    end
  end

  context 'when vm creation fails' do
    let(:network_spec_that_fails) do
      {
        'default' => {
          'type' => 'manual',
          'ip' => @config.manual_ip,
          'cloud_properties' => {
            'subnet_id' => @config.subnet_id,
          },
        },
        'vip' => {
          'type' => 'vip',
          'ip' => '255.255.255.255',
        },
      }
    end

    def no_active_vm_with_ip?(ip)
      huaweicloud.compute.servers.none? do |s|
        s.private_ip_address == ip && [:active].include?(s.state.downcase.to_sym)
      end
    end

    def no_port_remaining?(subnet_id, ip)
      huaweicloud.network.ports
               .select { |port| port.network_id == subnet_id }
               .none? { |port| port.fixed_ips.detect { |ips| ips['ip_address'] == ip } }
    end

    it 'cleans up vm' do
      expect {
        create_vm(@stemcell_id, network_spec_that_fails, [])
      }.to raise_error Bosh::Clouds::VMCreationFailed, /Floating IP '255.255.255.255' not allocated/

      expect(no_active_vm_with_ip?(@config.manual_ip)).to be
      expect(no_port_remaining?(@config.subnet_id, @config.manual_ip)).to eq(true)
    end

    it 'better error message for wrong net ID' do
      network_spec_with_wrong_net_id = {
        'default' => {
          'type' => 'dynamic',
          'cloud_properties' => {
            'subnet_id' => '00000000-0000-0000-0000-000000000000',
          },
        },
      }
      expect {
        create_vm(@stemcell_id, network_spec_with_wrong_net_id, [])
      }.to raise_error Bosh::Clouds::VMCreationFailed, /'00000000-0000-0000-0000-000000000000'/
    end
  end

  context 'when detaching a non-existing disk' do
    # Detaching a non-existing disk from vm should NOT raise error
    let(:network_spec) do
      {
        'default' => {
          'type' => 'dynamic',
          'cloud_properties' => {
            'subnet_id' => @config.subnet_id,
          },
        },
      }
    end

    it 'exercises the vm lifecycles' do
      vm_id = create_vm(@stemcell_id, network_spec, [])

      expect {
        @config.logger.info("Detaching disk vm_id=#{vm_id} disk_id=non-existing-disk")
        cpi.detach_disk(vm_id, 'non-existing-disk')
      }.to_not raise_error

      clean_up_vm(vm_id)
    end
  end

  describe 'use_nova_networking=true' do
    let(:network_spec) do
      {
        'default' => {
          'type' => 'dynamic',
            'cloud_properties' => {
              'subnet_id' => @config.subnet_id,
            },
        },
      }
    end

    let(:use_nova_networking) { true }
    after { clean_up_vm(@vm_id_for_nova_compatibility) if @vm_id_for_nova_compatibility }

    it 'create vm does not use neutron for security groups' do
      stub_request(:any, /.*\/v2\.0\/security-groups/)

      @vm_id_for_nova_compatibility = create_vm(@stemcell_id, network_spec, [])

      expect(WebMock).to_not have_requested(:any, /.*\/v2\.0\/security-groups/)
    end
  end

  describe 'light stemcell' do
    let(:light_stemcell_id) { "#{@stemcell_id} light" }

    describe '#create_stemcell' do
      it 'returns the stemcell id with ` light` suffix' do
        cloud_properties = {
          'image_id' => @stemcell_id,
        }

        expect(cpi.create_stemcell('not_relevant_path', cloud_properties)).to eq(light_stemcell_id)
      end

      context 'when referenced image does not exist' do
        it 'raises an error' do
          cloud_properties = {
            'image_id' => 'non-existing-id',
          }

          expect {
            cpi.create_stemcell('not_relevant_path', cloud_properties)
          }.to raise_error Bosh::Clouds::CloudError
        end
      end
    end

    describe '#create_vm' do
      let(:network_spec) do
        {
          'default' => {
            'type' => 'dynamic',
            'cloud_properties' => {
              'subnet_id' => @config.subnet_id,
            },
          },
        }
      end

      it 'creates a vm with the heavy stemcell id' do
        vm_lifecycle(light_stemcell_id, network_spec)
      end
    end
  end

  describe 'set_disk_metadata' do
    before { @disk_id = cpi.create_disk(2048, {}, nil) }
    after { clean_up_disk(@disk_id) if @disk_id }

    let(:metadata) do
      {
        'id' => 'my-id',
        'deployment' => 'my-deployment',
        'job' => 'my-job',
        'index' => 'my-index',
        'some_key' => 'some_value',
      }
    end

    it 'sets the disk metadata accordingly' do
      disk = huaweicloud.volume.volumes.get(@disk_id)
      expect(disk.metadata).not_to include(metadata)

      cpi.set_disk_metadata(@disk_id, metadata)

      disk = huaweicloud.volume.volumes.get(@disk_id)
      expect(disk.metadata).to include(metadata)
    end
  end

  describe 'enable_auto_anti_affinity' do
    let (:enable_auto_anti_affinity) { true }
    let(:network_spec) do
      {
        'default' => {
          'type' => 'dynamic',
          'cloud_properties' => {
            'subnet_id' => @config.subnet_id,
          },
        },
      }
    end

    before(:all) do
      skip('Tests for auto-anti-affinity are not activated.') unless @config.test_auto_anti_affinity
    end

    before(:each) do
      allow(Bosh::Clouds::Config).to receive(:uuid).and_return('fake-uuid')
      remove_server_groups(huaweicloud)
    end

    after do
      clean_up_vm(@server_groups_vm_id) if @server_groups_vm_id
      remove_server_groups(huaweicloud)
    end

    it 'creates a server group' do
      @server_groups_vm_id = create_vm(@stemcell_id, network_spec, [])
      vm_server_groups = huaweicloud.compute.server_groups.all.select { |g| g.name == 'fake-uuid-instance-group-1' }
      expect(vm_server_groups.size).to eq(1)
      expect(vm_server_groups.first.members).to include(@server_groups_vm_id)
    end

    it 'does not create a server group if instance group is missing from environment' do
      @server_groups_vm_id = create_vm(@stemcell_id, network_spec, [], {}, {})
      expect(huaweicloud.compute.server_groups.all).to be_empty
    end
  end

  describe 'resize_disk' do
    before { @disk_id = cpi.create_disk(2048, {}, nil) }
    after { clean_up_disk(@disk_id) if @disk_id }

    it 'resizes the disk' do
      cpi.resize_disk(@disk_id, 4096)

      disk = huaweicloud.volume.volumes.get(@disk_id)
      expect(disk.size).to eq(4)
    end
  end

  describe 'when using load balancer pool' do
    before(:all) do
      skip('No lbaas pool configured') unless @config.lbaas_pool_name
    end

    let(:network_spec) do
      {
        'default' => {
          'type' => 'dynamic',
          'cloud_properties' => {
            'subnet_id' => @config.subnet_id,
          },
        },
      }
    end

    let(:resource_pool_spec_with_lbaas_pools) do
      {
        'loadbalancer_pools' => [
          { 'name' => @config.lbaas_pool_name, 'port' => 4443 },
        ],
        'key_name' => @config.default_key_name,
        'availability_zone' => @config.availability_zone,
        'instance_type' => @config.instance_type,
      }
    end

    it 'exercises vm lifecycle' do
      vm_id = nil

      expect {
        vm_id = create_vm(@stemcell_id, network_spec, [], resource_pool_spec_with_lbaas_pools)
      }.to_not raise_error

      expect(vm_id).not_to be_nil

      expect {
        clean_up_vm(vm_id)
      }.to_not raise_error
    end
  end

  describe 'when creating a server in a non-existent availability zone' do
    let(:network_spec) do
      {
        'default' => {
          'type' => 'dynamic',
          'cloud_properties' => {
            'subnet_id' => @config.subnet_id,
          },
        },
      }
    end

    let(:resource_pool_spec) do
      {
        'key_name' => @config.default_key_name,
        'availability_zone' => 'fake-availability-zone',
        'instance_type' => @config.instance_type,
      }
    end

    it 'raises an error' do
      expect{
        create_vm(@stemcell_id, network_spec, [], resource_pool_spec)
      }.to raise_error;
    end
  end
end
