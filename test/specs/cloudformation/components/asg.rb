SparkleFormation.new('asg') do

  resources do
    test_net do
      type "AWS::EC2::Subnet"
      properties do
        cidr_block "10.20.30.0/24"
      end
    end
  end

  dynamic!(:launch_configuration, "test_lc") do
    properties do
      image_id "CentOS-6.5"
      instance_type "smem-2vcpu"
      network_interfaces array!(
        ->{ network _cf_ref("test_net".to_sym) }
      )
    end
  end

  dynamic!(:auto_scaling_group, "test_asg") do
    properties do
      min_size 3
      max_size 10
      cooldown 90
      launch_configuration_name _cf_ref("test_lc_launch_configuration".to_sym)
    end
    depends_on "test_net"
  end

end

