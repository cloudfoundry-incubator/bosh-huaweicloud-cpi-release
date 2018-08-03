module Bosh::HuaweiCloud
  ##
  # Represents HuaweiCloud manual network: where user sets VM's IP
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

    def prepare(huaweicloud, security_group_ids)
      if huaweicloud.use_nova_networking?
        @nic['v4_fixed_ip'] = @ip
      else
        # NOTE: Port ID is not required in huaweicloud, we directly use network_id and fixed ips instead
        # here. See document: https://support.huaweicloud.com/api-ecs/zh-cn_topic_0068473331.html#ZH-CN_TOPIC_0068473331__zh-cn_topic_0057972661_table9995892105551
        @logger.debug("Port is not required for huaweicloud, ignore creating pod for ip: #{@ip}, using network(subnet) #{subnet_id} directly.")
        if subnet_id
          huaweicloud.with_huaweicloud do
            subnet = huaweicloud.network.subnets.get(subnet_id, false)
            unless NetAddr::CIDR.create(subnet.cidr).matches?(@ip)
              error_message = "subnet is not compatible with fixed ip address."
              raise Bosh::Clouds::VMCreationFailed.new(false), error_message
            end
          end
          @nic['subnet_id'] = subnet_id
          @nic['v4_fixed_ip'] = @ip
        elsif vpc_id
          @logger.debug("'subnet_id' is not configured, use vpc instead.")
          huaweicloud.with_huaweicloud do
            subs = huaweicloud.network.subnets.all({vpc_id:vpc_id}, false).select do |sub|
              NetAddr::CIDR.create(sub.cidr).matches?(@ip)
            end
            @nic['subnet_id'] = subs.first
            @nic['v4_fixed_ip'] = @ip
          end
        end
        if @nic['subnet_id'].nil?
          error_message = "Can't find suitable network(subnet) according provided 'ip' and 'vpc_id' in the network spec."
          raise Bosh::Clouds::VMCreationFailed.new(false), error_message
        end
      end
    end

    def create_port_for_manual_network(huaweicloud, subnet_id, security_group_ids)
      port_properties = {
        network_id: subnet_id,
        fixed_ips: [{ ip_address: @ip }],
        security_groups: security_group_ids,
      }
      if @allowed_address_pairs
        cloud_error("Configured VRRP port with ip '#{@allowed_address_pairs}' does not exist.") unless vrrp_port?(huaweicloud)
        port_properties[:allowed_address_pairs] = [{ ip_address: @allowed_address_pairs }]
      end
      huaweicloud.with_huaweicloud { huaweicloud.network.ports.create(port_properties) }
    end

    def cleanup(huaweicloud)
      unless huaweicloud.use_nova_networking?
        unless @nic['port_id'].nil?
          port = huaweicloud.network.ports.get(@nic['port_id'])
          port&.destroy
        end
      end
    end

    private

    def vrrp_port?(huaweicloud)
      vrrp_port = huaweicloud.with_huaweicloud { huaweicloud.network.ports.all(fixed_ips: "ip_address=#{@allowed_address_pairs}") }
      !(vrrp_port.nil? || vrrp_port.empty?)
    end
  end
end
