module Bosh::HuaweiCloud
  ##
  # Represents OpenStack manual network: where user sets VM's IP
  class ManualNetwork < PrivateNetwork
    ##
    # Creates a new manual network
    #
    # @param [String] name Network name
    # @param [Hash] spec Raw network spec
    def initialize(name, spec)
      super
    end

    ##
    # Returns the private IP address
    #
    # @return [String] ip address
    def private_ip
      @ip
    end

    def prepare(openstack, security_group_ids)
      if openstack.use_nova_networking?
        @nic['v4_fixed_ip'] = @ip
      else
        # NOTE: Port ID is not required in huaweicloud, we directly use network_id and fixed ips instead
        # here. See document: https://support.huaweicloud.com/api-ecs/zh-cn_topic_0068473331.html#ZH-CN_TOPIC_0068473331__zh-cn_topic_0057972661_table9995892105551
        @logger.debug("Port is not required for huaweicloud, ignore creating pod for ip: #{@ip}, direclty using network(subnet) #{net_id}")
        if net_id
          @nic['net_id'] = net_id
          @nic['fixed_ip'] = @ip
        elsif vpc_id
          @logger.debug("'net_id' is not configured, use vpc instead.")
          openstack.with_openstack do
            subs = openstack.network.subnets.all(vpc_id:vpc_id).body['subnets'].select do |sub|
              NetAddr::CIDR.create(sub['cidr']).matches?(@ip)
            end
            @nic['net_id'] = subs.first
            @nic['fixed_ip'] = @ip
          end
        end
        if @nic['net_id'].nil?
          error_message = "Can't find suitable network(subnet) according provided 'ip' and 'vpc_id' in the network spec."
          raise Bosh::Clouds::VMCreationFailed.new(false), error_message
        end
      end
    end

    def cleanup(openstack)
      unless openstack.use_nova_networking?
        unless @nic['port_id'].nil?
          port = openstack.network.ports.get(@nic['port_id'])
          port&.destroy
        end
      end
    end

    private

    def vrrp_port?(openstack)
      vrrp_port = openstack.with_openstack { openstack.network.ports.all(fixed_ips: "ip_address=#{@allowed_address_pairs}") }
      !(vrrp_port.nil? || vrrp_port.empty?)
    end
  end
end
