#
# Cookbook Name:: wt_portfolio_harness
# Recipe:: default
#
# Copyright 2012, Webtrends
#
# All rights reserved - Do Not Redistribute
#

# include for the URI object
require 'uri'

# grab the zookeeper nodes that are currently available
zookeeper_quorum = Array.new
if not Chef::Config.solo
  search(:node, "role:zookeeper AND chef_environment:#{node.chef_environment}").sort{|a,b| a.name <=> b.name }.each do |n|
    zookeeper_quorum << n['fqdn']
  end
end

log_dir     = File.join(node['wt_common']['log_dir_linux'], "harness")
install_dir = File.join(node['wt_common']['install_dir_linux'], "harness")
conf_url    = File.join(install_dir, node['wt_portfolio_harness']['conf_url'])
plugin_dir  = File.join(install_dir, "plugins")
lib_dir     = File.join(install_dir, "lib")

#Set node attribute for plugins to reference
node.set['wt_portfolio_harness']['plugin_dir'] = plugin_dir
node.set['wt_portfolio_harness']['lib_dir'] = lib_dir

tarball      = node['wt_portfolio_harness']['download_url'].split("/")[-1]
download_url = node['wt_portfolio_harness']['download_url']
user         = node['wt_portfolio_harness']['user']
group        = node['wt_portfolio_harness']['group']
http_port    = node['wt_portfolio_harness']['port']
pod          = node['wt_realtime_hadoop']['pod']
datacenter   = node['wt_realtime_hadoop']['datacenter']
java_home    = node['java']['java_home']
java_opts    = node['wt_portfolio_harness']['java_opts']
auth_host     = URI(node['wt_sauth']['auth_service_url']).host
cam_host     = URI(node['wt_cam']['cam_service_url']).host
cam_port     = URI(node['wt_cam']['cam_service_url']).port



if ENV["deploy_build"] == "true" then
  directory File.join(install_dir, "lib") do
    action :delete
    recursive true
    notifies :run, "execute[delete_install_source]", :immediately
  end
end



# grab the users and passwords from the data bag
auth_data = data_bag_item('authorization', node.chef_environment)

proxy_host = ''
unless node['wt_common']['http_proxy_url'].nil? || node['wt_common']['http_proxy_url'].empty?
  proxy_uri = URI(node['wt_common']['http_proxy_url'])
  proxy_host = "#{proxy_uri.host}:#{proxy_uri.port}"
end

log "Install dir: #{install_dir}"
log "Log dir: #{log_dir}"
log "Java home: #{java_home}"

[log_dir, "#{install_dir}/bin", "#{install_dir}/conf", plugin_dir, "#{plugin_dir}/lib"].each do |dir|
  directory dir do
    owner   user
    group   group
    mode    00755
    recursive true
    action :create
  end
end

# delete the install tar ball
execute "delete_install_source" do
  user "root"
  group "root"
  command "rm -f #{Chef::Config[:file_cache_path]}/#{tarball}"
  ignore_failure true
  action :nothing
end

# download the application tarball
remote_file "#{Chef::Config[:file_cache_path]}/#{tarball}" do
  source download_url
  mode 00644
  action :create_if_missing
end

# uncompress the application tarball into the install dir
execute "Untar harness" do
  user  "root"
  group "root"
  cwd install_dir
  command "tar zxf #{Chef::Config[:file_cache_path]}/#{tarball}"
  creates "#{install_dir}/lib"
  notifies :restart, "service[harness]", :delayed
end


#Creates runit service item
template "#{install_dir}/bin/service-control" do
  source  "service-control.erb"
  owner "root"
  group "root"
  mode  00755
  variables({
    :log_dir => log_dir,
    :install_dir => install_dir,
    :conf_url => conf_url,
    :java_home => java_home,
    :java_jmx_port => node['wt_portfolio_harness']['jmx_port'],
    :java_opts => java_opts
  })
end  

# create the runit service
runit_service "harness" do
  options({
    :log_dir => log_dir,
    :install_dir => install_dir,
    :java_home => java_home,
    :user => user
  })
  action :enable
end

log "Updating the template files"
%w[application.conf logback.xml].each do | template_file|
  template "#{install_dir}/conf/#{template_file}" do
    source    "#{template_file}.erb"
    owner "root"
    group "root"
    mode  00644
    variables({
      :auth_version => node['wt_portfolio_harness']['sauth_version'],
      :proxy_host => proxy_host,
      :install_dir => install_dir,
      :http_port => http_port,
      :log_dir => log_dir,
      :log_level => node['wt_portfolio_harness']['log_level'],
      :wt_monitoring => node['wt_monitoring'],
      :graphite_enabled => node['wt_portfolio_harness']['graphite_enabled'],
      :graphite_interval => node['wt_portfolio_harness']['graphite_interval'],
      :graphite_vmmetrics => node['wt_portfolio_harness']['graphite_vmmetrics'],
      :graphite_regex => node['wt_portfolio_harness']['graphite_regex'],
      :jmx_port => node['wt_portfolio_harness']['jmx_port'],
      # streaming 0mq parameters
      :zookeeper_quorum => zookeeper_quorum * ",",
      :pod              => pod,
      :datacenter       => datacenter,
      # auth, cam parameters
      :auth_host => auth_host,
      :cam_host => cam_host,
      :cam_port => cam_port,
      :remote_address_hdr => node['wt_portfolio_harness']['remote_address_hdr'],
      :max_uri_length => node['wt_portfolio_harness']['max_uri_length']
    })
    notifies :restart, "service[harness]", :delayed
  end
end

service "harness"

if node.attribute?("nagios")
  template "#{install_dir}/bin/health-check-nagios.sh" do
    source  "health-check-nagios.sh.erb"
    owner "root"
    group "root"
    mode  00755
  end 

  #Create a nagios nrpe check for the healthcheck page
  nagios_nrpecheck "wt_portfolio_healthcheck" do
    command "#{install_dir}/bin/health-check-nagios.sh"
    parameters "5 http://#{node['fqdn']}:#{node['wt_portfolio_harness']['port']}/healthcheck?nagios"
    action :add
  end
  #Create a nagios nrpe check for the log file
  nagios_nrpecheck "wt_garbage_collection_limit_reached" do
    command "#{node['nagios']['plugin_dir']}/check_log"
    parameters "-F /var/log/webtrends/harness/service.log -O /tmp/service_old.log -q 'GC overhead limit exceeded'"
    action :add
  end
end
