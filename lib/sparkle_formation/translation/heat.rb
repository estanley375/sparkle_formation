class SparkleFormation
  class Translation
    # Translation for Heat (HOT)
    class Heat < Translation

      # Translate stack definition
      #
      # @return [TrueClass]
      # @note this is an override to return in proper HOT format
      # @todo still needs replacements of functions and pseudo-params
      def translate!
        super
        cache = MultiJson.load(MultiJson.dump(translated))
        # top level
        cache.each do |k,v|
          translated.delete(k)
          translated[snake(k).to_s] = v
        end
        # params
        cache.fetch('Parameters', {}).each do |k,v|
          translated['parameters'][k] = Hash[
            v.map do |key, value|
              if(key == 'Type')
                [snake(key).to_s, value.downcase]
              elsif(key == 'AllowedValues')
                # @todo fix this up to properly build constraints
                ['constraints', [{'allowed_values' => value}]]
              else
                [snake(key).to_s, value]
              end
            end
          ]
        end
        # resources
        cache.fetch('Resources', {}).each do |r_name, r_value|
          translated['resources'][r_name] = Hash[
            r_value.map do |k,v|
              [snake(k).to_s, v]
            end
          ]
        end
        # outputs
        cache.fetch('Outputs', {}).each do |o_name, o_value|
          translated['outputs'][o_name] = Hash[
            o_value.map do |k,v|
              [snake(k).to_s, v]
            end
          ]
        end
        translated.delete('awstemplate_format_version')
        translated['heat_template_version'] = '2013-05-23'
        # no HOT support for mappings, so remove and clean pseudo
        # params in refs
        if(translated['resources'])
          translated['resources'] = dereference_processor(translated['resources'], ['Fn::FindInMap', 'Ref'])
          translated['resources'] = rename_processor(translated['resources'])
        end
        if(translated['outputs'])
          translated['outputs'] = dereference_processor(translated['outputs'], ['Fn::FindInMap', 'Ref'])
          translated['outputs'] = rename_processor(translated['outputs'])
        end
        translated.delete('mappings')
        true
      end

      # Recursively snake case all keys
      #
      # @param thing [Object] object on which to snake case keys
      # @param exceptions [Array] list of keys to exclude from snake casing
      def snake_keys(thing, exceptions = [])
        if thing.class == Hash
          cache = MultiJson.load(MultiJson.dump(thing))
          cache.each do |k,v|
            next if exceptions.include?(k)
            thing.delete(k)
            new_key = snake(k).to_s
            thing[new_key] = v
            snake_keys(thing[new_key], exceptions)
          end
        elsif thing.class == Array
          thing.each do |e|
            snake_keys(e, exceptions)
          end
        end
      end

      # Custom mapping for block device
      #
      # @param value [Object] original property value
      # @param args [Hash]
      # @option args [Hash] :new_resource
      # @option args [Hash] :new_properties
      # @option args [Hash] :original_resource
      # @return [Array<String, Object>] name and new value
      # @todo implement
      def nova_server_block_device_mapping(value, args={})
        ['block_device_mapping', value]
      end

      # Custom mapping for server user data
      #
      # @param value [Object] original property value
      # @param args [Hash]
      # @option args [Hash] :new_resource
      # @option args [Hash] :new_properties
      # @option args [Hash] :original_resource
      # @return [Array<String, Object>] name and new value
      def nova_server_user_data(value, args={})
        args[:new_properties][:user_data_format] = 'RAW'
        args[:new_properties][:config_drive] = 'true'
        [:user_data, Hash[value.values.first]]
      end

      # Finalizer for the nova server resource. Fixes bug with remotes
      # in metadata
      #
      # @param resource_name [String]
      # @param new_resource [Hash]
      # @param old_resource [Hash]
      # @return [Object]
      def nova_server_finalizer(resource_name, new_resource, old_resource)
        if(old_resource['Metadata'])
          new_resource['Metadata'] = old_resource['Metadata']
          proceed = new_resource['Metadata'] &&
            new_resource['Metadata']['AWS::CloudFormation::Init'] &&
            config = new_resource['Metadata']['AWS::CloudFormation::Init']['config']
          if(proceed)
            # NOTE: This is a stupid hack since HOT gives the URL to
            # wget directly and if special characters exist, it fails
            if(files = config['files'])
              files.each do |key, args|
                if(args['source'])
                  if(args['source'].is_a?(String))
                    args['source'].replace("\"#{args['source']}\"")
                  else
                    args['source'] = {
                      'Fn::Join' => [
                        "", [
                          "\"",
                          args['source'],
                          "\""
                        ]
                      ]
                    }
                  end
                end
              end
            end
          end
        end
      end

      # Finalizer for translation of AWS::EC2::Subnet to OS::Neutron::Net
      def neutron_net_finalizer(resource_name, new_resource, old_resource)
        new_resource['Properties'] = {}.tap do |properties|
          # Add a uniquely named OS::Neutron::Subnet resource
          subnet_name = "#{resource_name}_OSNeutronSubnet"
          subnet_resource = MultiJson.load(MultiJson.dump(new_resource))
          subnet_resource['Type'] = 'OS::Neutron::Subnet'
          subnet_resource['Properties']['cidr'] = MultiJson.load(MultiJson.dump(old_resource['Properties']['CidrBlock']))
          subnet_resource['Properties']['network_id'] = { 'Ref' => resource_name }
          # Add an explicit dependency on the OS::Neutron::Net resource - it
          # seems to need it in some cases
          subnet_resource['depends_on'] = resource_name
          translated['Resources'][subnet_name] = subnet_resource
        end 
      end

      # Finalizer for translation of AWS::AutoScaling::AutoScalingGroup to
      # OS::Heat::AutoScalingGroup
      def asg_finalizer(resource_name, new_resource, old_resource)
        # If a dependency exists on a network resource, add a dependency for
        # the auto-generated subnet resource
        if old_resource.has_key?("DependsOn")
          new_resource['DependsOn'] = [];
          if old_resource.class == Array
            old_resource.each do |r|
              res_camel = camel(r)
              new_resource['DependsOn'].push(res_camel)
              if original['Resources'][res_camel]['Type'] == "AWS::EC2::Subnet"
                new_resource['DependsOn'].push("#{res_camel}_OSNeutronSubnet")
              end
            end
          else
            res_camel = camel(old_resource['DependsOn'])
            new_resource['DependsOn'].push(res_camel)
            if original['Resources'][res_camel]['Type'] == "AWS::EC2::Subnet"
              new_resource['DependsOn'].push("#{res_camel}_OSNeutronSubnet")
            end
          end
        end
      end

      # Finalizer applied to all new resources
      #
      # @param resource_name [String]
      # @param new_resource [Hash]
      # @param old_resource [Hash]
      # @return [TrueClass]
      def resource_finalizer(resource_name, new_resource, old_resource)
        %w(DependsOn Metadata).each do |key|
          if(old_resource[key] && !new_resource[key])
            new_resource[key] = old_resource[key]
          end
        end
        true
      end

      # Custom mapping for ASG launch configuration
      #
      # @param value [Object] original property value
      # @param args [Hash]
      # @option args [Hash] :new_resource
      # @option args [Hash] :new_properties
      # @option args [Hash] :original_resource
      # @return [Array<String, Object>] name and new value
      # @todo implement
      def autoscaling_group_launchconfig(value, args={})
        # Get the original launch configuration
        lc = original['Resources'][value['Ref']]

        # Translate it
        res = resource_translation('AWS::AutoScaling::LaunchConfiguration', lc,
            :LAUNCH_CONFIGURATION_MAP)

        # Fix the case on the resource keys
        snake_keys(res, ["Ref"])

        # Add it as a resource
        ['resource', res]
      end

      # Default keys to snake cased format (underscore)
      #
      # @param key [String, Symbol]
      # @return [String]
      def default_key_format(key)
        snake(key)
      end

      # Heat translation mapping
      MAP = {
        :resources => {
          'AWS::EC2::Instance' => {
            :name => 'OS::Nova::Server',
            :finalizer => :nova_server_finalizer,
            :properties => {
              'AvailabilityZone' => 'availability_zone',
              'BlockDeviceMappings' => :nova_server_block_device_mapping,
              'ImageId' => 'image',
              'InstanceType' => 'flavor',
              'KeyName' => 'key_name',
              'NetworkInterfaces' => 'networks',
              'SecurityGroups' => 'security_groups',
              'SecurityGroupIds' => 'security_groups',
              'Tags' => 'metadata',
              'UserData' => :nova_server_user_data
            }
          },
          'AWS::AutoScaling::AutoScalingGroup' => {
            :name => 'OS::Heat::AutoScalingGroup',
            :finalizer => :asg_finalizer,
            :properties => {
              'Cooldown' => 'cooldown',
              'DesiredCapacity' => 'desired_capacity',
              'MaxSize' => 'max_size',
              'MinSize' => 'min_size',
              'LaunchConfigurationName' => :autoscaling_group_launchconfig
            }
          },
          'AWS::EC2::Subnet' => {
            :name => 'OS::Neutron::Net',
            :finalizer => :neutron_net_finalizer,
            :properties => {
              'CidrBlock' => 'cidr'
            }
          },
          'AWS::AutoScaling::LaunchConfiguration' => :delete
        }
      }

      REF_MAPPING = {
        'AWS::StackName' => 'OS::stack_name',
        'AWS::StackId' => 'OS::stack_id',
        'AWS::Region' => 'OS::stack_id' # @todo i see it set in source, but no function. wat
      }

      FN_MAPPING = {
        'Fn::GetAtt' => 'get_attr',
        'Fn::Join' => 'list_join'  # @todo why is this not working?
      }

      # Special map for mapping AWS::AutoScaling::LaunchConfiguration
      LAUNCH_CONFIGURATION_MAP = {
        :resources => {
          'AWS::AutoScaling::LaunchConfiguration' => {
            :name => 'OS::Nova::Server',
            :properties => {
              "AssociatePublicIpAddress" => :delete, # @todo see if it is usable in network configuration
              'BlockDeviceMappings' => :nova_server_block_device_mapping,
              "EbsOptimized" => :delete,
              "IamInstanceProfile" => :delete, # @todo see if it is usable
              'ImageId' => 'image',
              "InstanceId" => :delete, # @todo verify not needed
              "InstanceMonitoring" => :delete, # @todo see how this can be used
              'InstanceType' => 'flavor',
              "KernelId" => :delete, # @todo see whether this can be used
              'KeyName' => 'key_name',
              # NetworkInterfaces is not an AWS::AutoScaling:LaunchConfiguration
              # property, but it is necessary for OS::Nova::Server resources
              'NetworkInterfaces' => 'networks',
              "RamDiskId" => :delete,
              'SecurityGroups' => 'security_groups',
              "SpotPrice" => :delete,
              'UserData' => :nova_server_user_data

              # These attributes are properties of OS::Nova::Server, but
              # are not properties AWS::AutoScaling::LaunchConfiguration
              # @todo figure out how to specify them
              #'AvailabilityZone' => 'availability_zone',
              #'SecurityGroupIds' => 'security_groups',
              #'Tags' => 'metadata',
            }
          }
        }
      }

    end
  end
end
