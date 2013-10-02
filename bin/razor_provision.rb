#!/usr/bin/env ruby

require 'rubygems'
require 'net/http'
require 'json'
require 'colored'
require 'optparse'


#some configs
razor_api='127.0.0.1:8026'

#defs
def putserror
  '['+''.colorize('ERROR', {:foreground => :red, :extra => :bold})+']'
end
def putsok
  '['+''.colorize('OK', {:foreground => :green, :extra => :bold})+']'
end
def putwarning
  '['+''.colorize('WARNING', {:foreground => :yellow, :extra => :bold})+']'
end
def putscyan(string)
  ''.colorize(string, {:foreground => :cyan, :extra => :bold})
end

def get_object_uuid(razor_api,slice,resource,value)
  uri = URI "http://#{razor_api}/razor/api/#{slice}?#{resource}=#{value}"
  res = Net::HTTP.get(uri)
  response_hash = JSON.parse(res)
  return nil if response_hash['response'].empty?
  retval = []
  response_hash['response'].each do |item|
    retval += [item['@uuid']]
  end
  return retval
end

def delete_object(razor_api,slice,sliceuuid)
  http = Net::HTTP.new(razor_api.split(':')[0],razor_api.split(':')[1])
  request = Net::HTTP::Delete.new("/razor/api/#{slice}/#{sliceuuid}")
  res = http.request(request)
  response_hash = JSON.parse(res.body)
  unless res.class == Net::HTTPAccepted
    puts putserror+" Error removing #{slice} - #{sliceuuid}"
    exit 1
  end
end

def create_object(razor_api,slice,json_hash)
  uri = URI "http://#{razor_api}/razor/api/#{slice}"
  json_string = JSON.generate(json_hash)
  res = Net::HTTP.post_form(uri, 'json_hash' => json_string)
  response_hash = JSON.parse(res.body)
  unless res.class == Net::HTTPCreated
    puts putserror+" Error creating new #{slice}"
    exit 1
  end
  uuid = response_hash["response"].first["@uuid"]
  return uuid
end


#options parsing
options = {}
optparse = OptionParser.new do |opts|
	opts.banner = "Usage: #{$0} -n node -m mac [OPTIONS]\n\n"

	opts.on('-n', '--node NODE', 'Node to provision. (REQUIRED).') do |n|
		options[:node] = n
	end

  opts.on('-m', '--macaddress MAC', 'Node\'s mac address. (REQUIRED).') do |m|
    options[:mac] = m.upcase
  end
  
  options[:os] = 'centos6'
  opts.on('-o', '--os-version OS', ['centos6'], 'Operating system. Supported: centos6. Default: centos6.') do |o|
    options[:os] = o
  end

  options[:chef] = '10'
  opts.on('-c', '--chef-version CHEF', ['10'], 'Chef version. Supported: 10. Default: 10.') do |c|
    options[:chef] = c
  end
  
  options[:env] = '_default'
  opts.on('-e', '--environment ENV', ['_default'], 'Chef environment. Supported: _default. Default: _default.') do |e|
    options[:env] = e
  end

  options[:role] = 'base_reh'
  opts.on('-b', '--base-role ROLE', ['base', 'base_reh'], 'Base role to apply. Currently supported: base, base_reh. Default: base_reh.') do |r|
    options[:role] = r
  end
end

begin
  optparse.parse!
  mandatory = [:node, :mac]
  missing = mandatory.select{ |param| options[param].nil? }
  if not missing.empty?
    puts putserror+" Missing options: #{missing.join(', ')}"
    exit 1 
  end
rescue OptionParser::InvalidOption, OptionParser::MissingArgument, OptionParser::InvalidArgument
  puts putserror+' '+$!.to_s
  exit 1
end

#validate macaddress
if not options[:mac] =~ /^([0-9A-F]{2}[:-]){5}([0-9A-F]{2})$/
  puts putserror+' Wrong mac address format.'
  exit 1
end

#options.each_key do |k|
#  puts "#{k} #{options[k]}"
#end

puts "Razor provision:"
puts "- fqdn: #{putscyan(options[:node])}"
puts "- mac: #{putscyan(options[:mac])}"
puts "- os: #{putscyan(options[:os])}"
puts "- chef version: #{putscyan(options[:chef])}"
puts "- chef environment: #{putscyan(options[:env])}"
puts "- chef base role: #{putscyan(options[:role])}"
puts 
print 'Checking model...'
if model_uuid = get_object_uuid(razor_api,'model','label',options[:os])
  puts '...model exists '+putsok
else
  puts "...model #{putscyan(options[:os])} doesn't exist in razor "+ putserror
  exit 1
end

#gen broker string
broker_string = "#{options[:chef]}-#{options[:env]}-#{options[:role]}"
print 'Checking broker...'
if broker_uuid = get_object_uuid(razor_api,'broker','name',broker_string)
  puts '...broker exists '+putsok
else
  puts "...broker #{putscyan(broker_string)} doesn't exist in razor "+ putserror
  exit 1
end

if tag_uuid = get_object_uuid(razor_api,'tag','name',options[:node])
  # remove existing tags
  tag_uuid.each do |uuid|
    delete_object(razor_api,'tag',uuid)
  end
end

if policy_uuid = get_object_uuid(razor_api,'policy','label',options[:node])
  # delete policy
  policy_uuid.each do |uuid|
    delete_object(razor_api,'policy',uuid)
  end
end

if active_model_uuid = get_object_uuid(razor_api,'active_model','label',options[:node])
# delete policy
  active_model_uuid.each do |uuid|
    delete_object(razor_api,'active_model',uuid)
  end
end
 
# create tag
tag_name = options[:node].gsub(/\./,'_')
puts
#%w{s s_eth0 s_eth1}.each do |key|
%w{s s_eth0 s_eth1 s_eth2 s_eth3}.each do |key|
  print "Creating tag..."
  json_hash = {"name" => options[:node], "tag" => tag_name }
  tag_uuid = create_object(razor_api,'tag',json_hash)
  print "...tag '#{putscyan(tag_name)}' created with UUDI '#{putscyan(tag_uuid)}'"
  json_hash = { 
    "key"     => "macaddres"+key,
    "compare" => "equal",
    "value"   => options[:mac],
    "invert"  => "false"
  }
  create_object(razor_api,"tag/#{tag_uuid}/matcher",json_hash)
  puts " and matcher '#{putscyan('macaddres'+key)}' => '#{putscyan(options[:mac])}' #{putsok}"
end

# create policy
puts
print "Creating policy..."
json_hash = {
  "model_uuid"  => model_uuid[0],
  "broker_uuid" => broker_uuid[0],
  "label"       => options[:node],
  "tags"        => tag_name,
  "template"    => "linux_deploy",
  "maximum"     => "1",
  "enabled"     => "true"
}
policy_uuid = create_object(razor_api,'policy',json_hash)
puts "...policy '#{putscyan(options[:node])}' created with UUDI '#{putscyan(policy_uuid)}' #{putsok}"
puts
puts "Razor prepared, please restart node: #{putscyan(options[:node])} and boot it using PXE." 

exit 0