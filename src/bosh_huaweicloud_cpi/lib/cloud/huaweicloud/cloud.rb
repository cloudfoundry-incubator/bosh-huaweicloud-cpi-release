module Bosh::HuaweiCloud
  ##
  # BOSH OpenStack CPI
  class Cloud < Bosh::Cloud
    include Helpers

    OPTION_KEYS = %w[openstack registry agent use_dhcp].freeze

    BOSH_APP_DIR = '/var/vcap/bosh'.freeze
    FIRST_DEVICE_NAME_LETTER = 'b'.freeze
    REGISTRY_KEY_TAG = :registry_key

    attr_reader :registry
    attr_reader :state_timeout
    attr_reader :openstack
    attr_accessor :logger

    ##
    # Creates a new BOSH OpenStack CPI
    #
    # @param [Hash] options CPI options
    # @option options [Hash] openstack OpenStack specific options
    # @option options [Hash] agent agent options
    # @option options [Hash] registry agent options
    def initialize(options)
      @options = normalize_options(options)

      validate_options
      initialize_registry

      @logger = Bosh::Clouds::Config.logger

      @agent_properties = @options.fetch('agent', {})
      openstack_properties = @options['openstack']
      @default_key_name = openstack_properties['default_key_name']
      @default_security_groups = openstack_properties['default_security_groups']
      @default_volume_type = openstack_properties['default_volume_type']
      @stemcell_public_visibility = openstack_properties['stemcell_public_visibility']
      @boot_from_volume = openstack_properties['boot_from_volume']
      @use_dhcp = openstack_properties['use_dhcp']
      @human_readable_vm_names = openstack_properties['human_readable_vm_names']
      @enable_auto_anti_affinity = openstack_properties['enable_auto_anti_affinity']
      @use_config_drive = !!openstack_properties.fetch('config_drive', false)
      @config_drive = openstack_properties['config_drive']

      @openstack = Bosh::HuaweiCloud::Huawei.new(@options['openstack'])

      @az_provider = Bosh::HuaweiCloud::AvailabilityZoneProvider.new(
        @openstack,
        openstack_properties['ignore_server_availability_zone'],
      )

      @metadata_lock = Mutex.new

      @instance_type_mapper = Bosh::HuaweiCloud::InstanceTypeMapper.new
    end

    def compute
      @openstack.compute
    end

    def glance
      @openstack.image
    end

    def volume
      @openstack.volume
    end

    def auth_url
      @openstack.auth_url
    end

    def network
      @openstack.network
    end

    ##
    # Creates a new OpenStack Image using stemcell image. It requires access
    # to the OpenStack Glance service.
    #
    # @param [String] image_path Local filesystem path to a stemcell image
    # @param [Hash] cloud_properties CPI-specific properties
    # @option cloud_properties [String] name Stemcell name
    # @option cloud_properties [String] version Stemcell version
    # @option cloud_properties [String] infrastructure Stemcell infrastructure
    # @option cloud_properties [String] disk_format Image disk format
    # @option cloud_properties [String] container_format Image container format
    # @option cloud_properties [optional, String] kernel_file Name of the
    #   kernel image file provided at the stemcell archive
    # @option cloud_properties [optional, String] ramdisk_file Name of the
    #   ramdisk image file provided at the stemcell archive
    # @return [String] OpenStack image UUID of the stemcell
    def create_stemcell(image_path, cloud_properties)
      with_thread_name("create_stemcell(#{image_path}...)") do
        stemcell_creator = StemcellCreator.new(@logger, @openstack, cloud_properties)
        stemcell = stemcell_creator.create(image_path, @stemcell_public_visibility)
        stemcell.id
      end
    end

    ##
    # Deletes a stemcell
    #
    # @param [String] stemcell_id OpenStack image UUID of the stemcell to be
    #   deleted
    # @return [void]
    def delete_stemcell(stemcell_id)
      with_thread_name("delete_stemcell(#{stemcell_id})") do
        @logger.info("Deleting stemcell `#{stemcell_id}'...")

        stemcell = Stemcell.create(@logger, @openstack, stemcell_id)
        stemcell.delete
      end
    end

    ##
    # Creates an OpenStack server and waits until it's in running state
    #
    # @param [String] agent_id UUID for the agent that will be used later on by
    #   the director to locate and talk to the agent
    # @param [String] stemcell_id OpenStack image UUID that will be used to
    #   power on new server
    # @param [Hash] cloud_properties cloud specific properties describing the
    #   resources needed for this VM
    # @param [Hash] network_spec list of networks and their settings needed for
    #   this VM
    # @param [optional, Array] disk_locality List of disks that might be
    #   attached to this server in the future, can be used as a placement
    #   hint (i.e. server will only be created if resource pool availability
    #   zone is the same as disk availability zone)
    # @param [optional, Hash] environment Data to be merged into agent settings
    # @return [String] OpenStack server UUID
    def create_vm(agent_id, stemcell_id, cloud_properties,
                  network_spec = nil, disk_locality = nil, environment = nil)
      with_thread_name("create_vm(#{agent_id}, ...)") do
        @logger.info('Creating new server...')
        @logger.debug("Using scheduler hints: `#{cloud_properties['scheduler_hints']}'") if cloud_properties['scheduler_hints']
        registry_key = "vm-#{generate_unique_name}"
        create_vm_params = {
          name: registry_key,
          os_scheduler_hints: cloud_properties['scheduler_hints'],
          config_drive: @use_config_drive,
        }
        server = Server.new(@agent_properties, @human_readable_vm_names, @logger, @openstack, @registry, @use_dhcp)

        openstack_properties = OpenStruct.new(
          boot_from_volume: @boot_from_volume,
          default_key_name: @default_key_name,
          enable_auto_anti_affinity: @enable_auto_anti_affinity,
          default_security_groups: @default_security_groups,
        )

        vm_factory = VmFactory.new(@openstack, server, create_vm_params, disk_locality, @az_provider, openstack_properties)
        network_configurator = NetworkConfigurator.new(network_spec, cloud_properties['allowed_address_pairs'])
        vm_factory.create_vm(network_configurator, agent_id, environment, stemcell_id, cloud_properties)
      end
    end

    ##
    # Terminates an OpenStack server and waits until it reports as terminated
    #
    # @param [String] server_id OpenStack server UUID
    # @return [void]
    def delete_vm(server_id)
      with_thread_name("delete_vm(#{server_id})") do
        @logger.info("Deleting server `#{server_id}'...")
        server = @openstack.with_huaweicloud { @openstack.compute.servers.get(server_id) }
        if server
          server_tags = metadata_to_tags(server.metadata)
          @logger.debug("Server tags: `#{server_tags}' found for server #{server_id}")
          Server.new(@agent_properties, @human_readable_vm_names, @logger, @openstack, @registry, @use_dhcp).destroy(server, server_tags)
        else
          @logger.info("Server `#{server_id}' not found. Skipping.")
        end
      end
    end

    ##
    # Checks if an OpenStack server exists
    #
    # @param [String] server_id OpenStack server UUID
    # @return [Boolean] True if the vm exists
    def has_vm?(server_id)
      with_thread_name("has_vm?(#{server_id})") do
        server = @openstack.with_huaweicloud { @openstack.compute.servers.get(server_id) }
        !server.nil? && !%i[terminated deleted].include?(server.state.downcase.to_sym)
      end
    end

    ##
    # Reboots an OpenStack Server
    #
    # @param [String] server_id OpenStack server UUID
    # @return [void]
    def reboot_vm(server_id)
      with_thread_name("reboot_vm(#{server_id})") do
        server = @openstack.with_huaweicloud { @openstack.compute.servers.get(server_id) }
        cloud_error("Server `#{server_id}' not found") unless server

        soft_reboot(server)
      end
    end

    ##
    # Configures networking on existing OpenStack server
    #
    # @param [String] server_id OpenStack server UUID
    # @param [Hash] network_spec Raw network spec passed by director
    # @return [void]
    # @raise [Bosh::Clouds:NotSupported] If there's a network change that requires the recreation of the VM
    def configure_networks(server_id, network_spec)
      with_thread_name("configure_networks(#{server_id}, ...)") do
        raise Bosh::Clouds::NotSupported,
              format('network configuration change requires VM recreation: %s', network_spec)
      end
    end

    ##
    # Creates a new OpenStack volume
    #
    # @param [Integer] size disk size in MiB
    # @param [optional, String] server_id OpenStack server UUID of the VM that
    #   this disk will be attached to
    # @return [String] OpenStack volume UUID
    def create_disk(size, cloud_properties, server_id = nil)
      volume_service_client = @openstack.volume
      with_thread_name("create_disk(#{size}, #{cloud_properties}, #{server_id})") do
        raise ArgumentError, 'Disk size needs to be an integer' unless size.is_a?(Integer)
        cloud_error('Minimum disk size is 1 GiB') if size < 1024

        unique_name = generate_unique_name
        volume_params = {
          # cinder v1 requires display_ prefix
          display_name: "volume-#{unique_name}",
          display_description: '',
          # cinder v2 does not require prefix
          name: "volume-#{unique_name}",
          description: '',
          size: mib_to_gib(size),
        }

        if cloud_properties.key?('type')
          volume_params[:volume_type] = cloud_properties['type']
        elsif !@default_volume_type.nil?
          volume_params[:volume_type] = @default_volume_type
        end

        if server_id && @az_provider.use_server_availability_zone?
          server = @openstack.with_huaweicloud { @openstack.compute.servers.get(server_id) }
          volume_params[:availability_zone] = server.availability_zone if server&.availability_zone
        end

        @logger.info('Creating new volume...')
        new_volume = @openstack.with_huaweicloud { volume_service_client.volumes.create(volume_params) }

        @logger.info("Creating new volume `#{new_volume.id}'...")
        @openstack.wait_resource(new_volume, :available)

        new_volume.id.to_s
      end
    end

    ##
    # Check whether an OpenStack volume exists or not
    #
    # @param [String] disk_id OpenStack volume UUID
    # @return [bool] whether the specific disk is there or not
    def has_disk?(disk_id)
      with_thread_name("has_disk?(#{disk_id})") do
        @logger.info("Check the presence of disk with id `#{disk_id}'...")
        volume = @openstack.with_huaweicloud { @openstack.volume.volumes.get(disk_id) }

        !volume.nil?
      end
    end

    ##
    # Deletes an OpenStack volume
    #
    # @param [String] disk_id OpenStack volume UUID
    # @return [void]
    # @raise [Bosh::Clouds::CloudError] if disk is not in available state
    def delete_disk(disk_id)
      with_thread_name("delete_disk(#{disk_id})") do
        @logger.info("Deleting volume `#{disk_id}'...")
        volume = @openstack.with_huaweicloud { @openstack.volume.volumes.get(disk_id) }
        if volume
          state = volume.status
          cloud_error("Cannot delete volume `#{disk_id}', state is #{state}") if state.to_sym != :available

          @openstack.with_huaweicloud { volume.destroy }
          @openstack.wait_resource(volume, :deleted, :status, true)
        else
          @logger.info("Volume `#{disk_id}' not found. Skipping.")
        end
      end
    end

    ##
    # Attaches an OpenStack volume to an OpenStack server
    #
    # @param [String] server_id OpenStack server UUID
    # @param [String] disk_id OpenStack volume UUID
    # @return [void]
    def attach_disk(server_id, disk_id)
      with_thread_name("attach_disk(#{server_id}, #{disk_id})") do
        server = @openstack.with_huaweicloud { @openstack.compute.servers.get(server_id) }
        cloud_error("Server `#{server_id}' not found") unless server

        volume = @openstack.with_huaweicloud { @openstack.volume.volumes.get(disk_id) }
        cloud_error("Volume `#{disk_id}' not found") unless volume

        device_name = attach_volume(server, volume)

        update_agent_settings(server) do |settings|
          settings['disks'] ||= {}
          settings['disks']['persistent'] ||= {}
          settings['disks']['persistent'][disk_id] = device_name
        end
      end
    end

    ##
    # Detaches an OpenStack volume from an OpenStack server
    #
    # @param [String] server_id OpenStack server UUID
    # @param [String] disk_id OpenStack volume UUID
    # @return [void]
    def detach_disk(server_id, disk_id)
      with_thread_name("detach_disk(#{server_id}, #{disk_id})") do
        server = @openstack.with_huaweicloud { @openstack.compute.servers.get(server_id) }
        cloud_error("Server `#{server_id}' not found") unless server

        volume = @openstack.with_huaweicloud { @openstack.volume.volumes.get(disk_id) }
        if volume.nil?
          @logger.info("Disk `#{disk_id}' not found while trying to detach it from vm `#{server_id}'...")
        else
          detach_volume(server, volume)
        end

        update_agent_settings(server) do |settings|
          settings['disks'] ||= {}
          settings['disks']['persistent'] ||= {}
          settings['disks']['persistent'].delete(disk_id)
        end
      end
    end

    ##
    # Takes a snapshot of an OpenStack volume
    #
    # @param [String] disk_id OpenStack volume UUID
    # @param [Hash] metadata Metadata key/value pairs to add to snapshot
    # @return [String] OpenStack snapshot UUID
    # @raise [Bosh::Clouds::CloudError] if volume is not found
    def snapshot_disk(disk_id, metadata)
      with_thread_name("snapshot_disk(#{disk_id})") do
        metadata = Hash[metadata.map { |key, value| [key.to_s, value] }]
        volume = @openstack.with_huaweicloud { @openstack.volume.volumes.get(disk_id) }
        cloud_error("Volume `#{disk_id}' not found") unless volume

        devices = []
        volume.attachments.each { |attachment| devices << attachment['device'] unless attachment.empty? }

        description = %w[deployment job index].collect { |key| metadata[key] }
        description << devices.first.split('/').last unless devices.empty?
        name = "snapshot-#{generate_unique_name}"
        snapshot_params = {
          # cinder v1 requires display_ prefix
          display_name: name,
          display_description: description.join('/'),
          # cinder v2 does not require prefix
          name: name,
          description: description.join('/'),
          volume_id: volume.id,
          force: true,
        }

        @logger.info("Creating new snapshot for volume `#{disk_id}'...")
        snapshot = @openstack.volume.snapshots.new(snapshot_params)
        @openstack.with_huaweicloud {
          snapshot.save
        }

        @logger.info("Creating new snapshot `#{snapshot.id}' for volume `#{disk_id}'...")
        @openstack.wait_resource(snapshot, :available)

        metadata.merge!(
          'director' => metadata['director_name'],
          'instance_index' => metadata['index'].to_s,
          'instance_name' => metadata['job'] + '/' + metadata['instance_id'],
        )

        metadata.delete('director_name')
        metadata.delete('index')
        metadata.delete('job')

        @logger.info("Creating metadata for snapshot `#{snapshot.id}'...")
        @openstack.with_huaweicloud {
          TagManager.tag_snapshot(snapshot, metadata)
        }

        snapshot.id.to_s
      end
    end

    ##
    # Deletes an OpenStack volume snapshot
    #
    # @param [String] snapshot_id OpenStack snapshot UUID
    # @return [void]
    # @raise [Bosh::Clouds::CloudError] if snapshot is not in available state
    def delete_snapshot(snapshot_id)
      with_thread_name("delete_snapshot(#{snapshot_id})") do
        @logger.info("Deleting snapshot `#{snapshot_id}'...")
        snapshot = @openstack.with_huaweicloud { @openstack.volume.snapshots.get(snapshot_id) }
        if snapshot
          state = snapshot.status
          cloud_error("Cannot delete snapshot `#{snapshot_id}', state is #{state}") if state.to_sym != :available

          @openstack.with_huaweicloud { snapshot.destroy }
          @openstack.wait_resource(snapshot, :deleted, :status, true)
        else
          @logger.info("Snapshot `#{snapshot_id}' not found. Skipping.")
        end
      end
    end

    ##
    # Set metadata for an OpenStack server
    #
    # @param [String] server_id OpenStack server UUID
    # @param [Hash] metadata Metadata key/value pairs
    # @return [void]
    def set_vm_metadata(server_id, metadata)
      with_thread_name("set_vm_metadata(#{server_id}, ...)") do
        @openstack.with_huaweicloud do
          server = @openstack.compute.servers.get(server_id)
          cloud_error("Server `#{server_id}' not found") unless server

          TagManager.tag_server(server, metadata)

          if server.metadata.get(REGISTRY_KEY_TAG)
            name = metadata['name']
            job = metadata['job']
            index = metadata['index']
            compiling = metadata['compiling']
            if name
              @logger.debug("Rename VM with id '#{server_id}' to '#{name}'")
              @openstack.compute.update_server(server_id, 'name' => name.to_s)
            elsif job && index
              @logger.debug("Rename VM with id '#{server_id}' to '#{job}/#{index}'")
              @openstack.compute.update_server(server_id, 'name' => "#{job}/#{index}")
            elsif compiling
              @logger.debug("Rename VM with id '#{server_id}' to 'compiling/#{compiling}'")
              @openstack.compute.update_server(server_id, 'name' => "compiling/#{compiling}")
            end
          else
            @logger.debug("VM with id '#{server_id}' has no 'registry_key' tag")
          end
        end
      end
    end

    ##
    # Set metadata for an OpenStack disk
    #
    # @param [String] disk_id OpenStack disk UUID
    # @param [Hash] metadata Metadata key/value pairs
    # @return [void]
    def set_disk_metadata(disk_id, metadata)
      with_thread_name("set_disk_metadata(#{disk_id}, ...)") do
        @openstack.with_huaweicloud do
          disk = @openstack.volume.volumes.get(disk_id)
          cloud_error("Disk `#{disk_id}' not found") unless disk
          TagManager.tag_volume(@openstack.volume, disk_id, metadata)
        end
      end
    end

    # Map a set of cloud agnostic VM properties (cpu, ram, ephemeral_disk_size) to
    # a set of OpenStack specific cloud_properties
    # @param [Hash] requirements requested cpu, ram, and ephemeral_disk_size
    # @return [Hash] OpenStack specific cloud_properties describing instance (e.g. instance_type)
    def calculate_vm_cloud_properties(requirements)
      required_keys = %w[cpu ram ephemeral_disk_size]
      missing_keys = required_keys.reject { |key| requirements[key] }
      unless missing_keys.empty?
        missing_keys.map! { |k| "'#{k}'" }
        raise "Missing VM cloud properties: #{missing_keys.join(', ')}"
      end

      @instance_type_mapper.map(
        requirements: requirements,
        flavors: compute.flavors,
        boot_from_volume: @boot_from_volume,
      )
    end

    def is_v3
      @options['openstack']['auth_url'].match(/\/v3(?=\/|$)/)
    end

    ##
    # Updates the agent settings
    #
    # @param [Fog::Compute::HuaweiCloud::Server] server OpenStack server
    def update_agent_settings(server)
      raise ArgumentError, 'Block is not provided' unless block_given?
      registry_key = registry_key_for(server)
      @logger.info("Updating settings for server `#{server.id}' with registry key `#{registry_key}'...")
      settings = @registry.read_settings(registry_key)
      yield settings
      @registry.update_settings(registry_key, settings)
    end

    # Information about Openstack CPI, currently supported stemcell formats
    # @return [Hash] Openstack CPI properties
    def info
      { 'stemcell_formats' => ['openstack-raw', 'openstack-qcow2', 'openstack-light'] }
    end

    ##
    # Resizes an existing OpenStack volume
    #
    # @param [String] disk_id volume Cloud ID
    # @param [Integer] new_size disk size in MiB
    def resize_disk(disk_id, new_size)
      new_size_gib = mib_to_gib(new_size)

      with_thread_name("resize_disk(#{disk_id}, #{new_size_gib})") do
        @logger.info("Resizing volume `#{disk_id}'...")
        @openstack.with_huaweicloud do
          volume = @openstack.volume.volumes.get(disk_id)
          cloud_error("Cannot resize volume because volume with #{disk_id} not found") unless volume
          actual_size_gib = volume.size
          if actual_size_gib == new_size_gib
            @logger.info("Skipping resize of disk #{disk_id} because current value #{actual_size_gib} GiB is equal new value #{new_size_gib} GiB")
          elsif actual_size_gib > new_size_gib
            not_supported_error("Cannot resize volume to a smaller size from #{actual_size_gib} GiB to #{new_size_gib} GiB") if actual_size_gib > new_size_gib
          else
            attachments = volume.attachments
            cloud_error("Cannot resize volume '#{disk_id}' it still has #{attachments.size} attachment(s)") unless attachments.empty?
            volume.extend(new_size_gib)
            @logger.info("Resizing #{disk_id} from #{actual_size_gib} GiB to #{new_size_gib} GiB")
            @openstack.wait_resource(volume, :available)
            @logger.info("Disk #{disk_id} resized from #{actual_size_gib} GiB to #{new_size_gib} GiB")
          end
        end
      end

      nil
    end

    private

    def mib_to_gib(size)
      (size / 1024.0).ceil
    end

    def registry_key_for(server)
      registry_key_metadatum = @openstack.with_huaweicloud { server.metadata.get(REGISTRY_KEY_TAG) }
      registry_key_metadatum ? registry_key_metadatum.value : server.name
    end

    ##
    # Generates an unique name
    #
    # @return [String] Unique name
    def generate_unique_name
      SecureRandom.uuid
    end

    ##
    # Soft reboots an OpenStack server
    #
    # @param [Fog::Compute::HuaweiCloud::Server] server OpenStack server
    # @return [void]
    def soft_reboot(server)
      @logger.info("Soft rebooting server `#{server.id}'...")
      @openstack.with_huaweicloud { server.reboot }
      @openstack.wait_resource(server, :active, :state)
    end

    ##
    # Hard reboots an OpenStack server
    #
    # @param [Fog::Compute::HuaweiCloud::Server] server OpenStack server
    # @return [void]
    def hard_reboot(server)
      @logger.info("Hard rebooting server `#{server.id}'...")
      @openstack.with_huaweicloud { server.reboot(type = 'HARD') }
      @openstack.wait_resource(server, :active, :state)
    end

    ##
    # Attaches an OpenStack volume to an OpenStack server
    #
    # @param [Fog::Compute::HuaweiCloud::Server] server OpenStack server
    # @param [Fog::Compute::HuaweiCloud::Volume] volume OpenStack volume
    # @return [String] Device name
    def attach_volume(server, volume)
      @logger.info("Attaching volume `#{volume.id}' to server `#{server.id}'...")
      volume_attachments = @openstack.with_huaweicloud { server.volume_attachments }
      device = volume_attachments.find { |a| a['volumeId'] == volume.id }

      if device.nil?
        device_name = select_device_name(volume_attachments, first_device_name_letter(server))
        cloud_error('Server has too many disks attached') if device_name.nil?

        @logger.info("Attaching volume `#{volume.id}' to server `#{server.id}', device name is `#{device_name}'")
        @openstack.with_huaweicloud { server.attach_volume(volume.id, device_name) }
        @openstack.wait_resource(volume, :'in-use')
      else
        device_name = device['device']
        @logger.info("Volume `#{volume.id}' is already attached to server `#{server.id}' in `#{device_name}'. Skipping.")
      end

      device_name
    end

    ##
    # Select the first available device name
    #
    # @param [Array] volume_attachments Volume attachments
    # @param [String] first_device_name_letter First available letter for device names
    # @return [String] First available device name or nil is none is available
    def select_device_name(volume_attachments, first_device_name_letter)
      (first_device_name_letter..'z').each do |char|
        # Some kernels remap device names (from sd* to vd* or xvd*).
        device_names = ["/dev/sd#{char}", "/dev/vd#{char}", "/dev/xvd#{char}"]
        # Bosh Agent will lookup for the proper device name if we set it initially to sd*.
        return "/dev/sd#{char}" if volume_attachments.select { |v| device_names.include?(v['device']) }.empty?
        @logger.warn("`/dev/sd#{char}' is already taken")
      end

      nil
    end

    ##
    # Returns the first letter to be used on device names
    #
    # @param [Fog::Compute::HuaweiCloud::Server] server OpenStack server
    # @return [String] First available letter
    def first_device_name_letter(server)
      letter = FIRST_DEVICE_NAME_LETTER.dup
      return letter if server.flavor.nil?
      return letter unless server.flavor.key?('id')
      flavor = @openstack.with_huaweicloud { @openstack.compute.flavors.find { |f| f.id == server.flavor['id'] } }
      return letter if flavor.nil?

      letter.succ! if flavor_has_ephemeral_disk?(flavor)
      letter.succ! if flavor_has_swap_disk?(flavor)
      letter.succ! if @config_drive == 'disk'
      letter
    end

    ##
    # Detaches an OpenStack volume from an OpenStack server
    #
    # @param [Fog::Compute::HuaweiCloud::Server] server OpenStack server
    # @param [Fog::Compute::HuaweiCloud::Volume] volume OpenStack volume
    # @return [void]
    def detach_volume(server, volume)
      @logger.info("Detaching volume `#{volume.id}' from `#{server.id}'...")
      volume_attachments = @openstack.with_huaweicloud { server.volume_attachments }
      attachment = volume_attachments.find { |a| a['volumeId'] == volume.id }
      if attachment
        @openstack.with_huaweicloud { server.detach_volume(volume.id) }
        @openstack.wait_resource(volume, :available)
      else
        @logger.info("Disk `#{volume.id}' is not attached to server `#{server.id}'. Skipping.")
      end
    end

    ##
    # Checks if the OpenStack flavor has ephemeral disk
    #
    # @param [Fog::Compute::HuaweiCloud::Flavor] OpenStack flavor
    # @return [Boolean] true if flavor has ephemeral disk, false otherwise
    def flavor_has_ephemeral_disk?(flavor)
      flavor.ephemeral && flavor.ephemeral.to_i > 0
    end

    ##
    # Checks if the OpenStack flavor has swap disk
    #
    # @param [Fog::Compute::HuaweiCloud::Flavor] OpenStack flavor
    # @return [Boolean] true if flavor has swap disk, false otherwise
    def flavor_has_swap_disk?(flavor)
      flavor.swap.nil? || flavor.swap.to_i <= 0 ? false : true
    end

    ##
    # Checks if options passed to CPI are valid and can actually
    # be used to create all required data structures etc.
    #
    # @return [void]
    # @raise [ArgumentError] if options are not valid
    def validate_options
      raise ArgumentError, "Invalid OpenStack cloud properties: No 'openstack' properties specified." unless @options['openstack']
      auth_url = @options['openstack']['auth_url']
      schema = Membrane::SchemaParser.parse do
        openstack_options_schema = {
          'openstack' => {
            'auth_url' => String,
            'username' => String,
            'api_key' => String,
            optional('region') => String,
            optional('endpoint_type') => String,
            optional('state_timeout') => Numeric,
            optional('stemcell_public_visibility') => bool,
            optional('connection_options') => Hash,
            optional('boot_from_volume') => bool,
            optional('default_key_name') => String,
            optional('default_security_groups') => [String],
            optional('default_volume_type') => String,
            optional('wait_resource_poll_interval') => Integer,
            optional('config_drive') => enum('disk', 'cdrom'),
            optional('human_readable_vm_names') => bool,
            optional('use_dhcp') => bool,
            optional('use_nova_networking') => bool,
          },
          'registry' => {
            'endpoint' => String,
            'user' => String,
            'password' => String,
          },
          optional('agent') => Hash,
        }
        if Bosh::HuaweiCloud::Huawei.is_v3(auth_url)
          openstack_options_schema['openstack']['project'] = String
          openstack_options_schema['openstack']['domain'] = String
        else
          openstack_options_schema['openstack']['tenant'] = String
          openstack_options_schema['openstack'][optional('domain')] = String
        end
        openstack_options_schema
      end
      schema.validate(@options)
    rescue Membrane::SchemaValidationError => e
      raise ArgumentError, "Invalid OpenStack cloud properties: #{e.inspect}"
    end

    def initialize_registry
      registry_properties = @options.fetch('registry')
      registry_endpoint   = registry_properties.fetch('endpoint')
      registry_user       = registry_properties.fetch('user')
      registry_password   = registry_properties.fetch('password')

      @registry = Bosh::Cpi::RegistryClient.new(registry_endpoint,
                                                registry_user,
                                                registry_password)
    end

    def normalize_options(options)
      raise ArgumentError, "Invalid OpenStack cloud properties: Hash expected, received #{options}" unless options.is_a?(Hash)
      # we only care about two top-level fields
      options = hash_filter(options.dup) { |key| OPTION_KEYS.include?(key) }
      # nil values should be treated the same as missing keys (makes validating optional fields easier)
      delete_entries_with_nil_keys(options)
    end

    def hash_filter(hash)
      copy = {}
      hash.each do |key, value|
        copy[key] = value if yield(key)
      end
      copy
    end

    def delete_entries_with_nil_keys(options)
      options.each do |key, value|
        if value.nil?
          options.delete(key)
        elsif value.is_a?(Hash)
          options[key] = delete_entries_with_nil_keys(value.dup)
        end
      end
      options
    end

    def metadata_to_tags(fog_metadata)
      fog_metadata.map { |metadatum| [metadatum.key, metadatum.value] }.to_h
    end
  end
end
