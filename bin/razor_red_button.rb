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
def putswarning
  '['+''.colorize('WARNING', {:foreground => :yellow, :extra => :bold})+']'
end
def putscyan(string)
  ''.colorize(string, {:foreground => :cyan, :extra => :bold})
end

def yesno
  puts "Continue? [y/n]"
  yn = STDIN.gets.chomp()
  if yn == 'y' or yn == 'Y'
    return 0
  elsif yn == 'n' or yn == 'N'
    puts "You chose '#{putscyan('n')}', nothing to do."
    exit 0
  else
    yesno
  end
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
	opts.banner = "Usage: #{$0} -f nodes.json\n\n"

	opts.on('-f', '--file FILE', 'File with nodes configuration (REQUIRED).') do |f|
		options[:file] = f
	end

  options[:dnsmasq] = '/etc/dnsmasq.hosts'
	opts.on('-d', '--dnsmasq FILE', 'Dnsmasq host file. Default: /etc/dnsmasq.hosts') do |d|
		options[:dnsmasq] = d
	end

end

begin
  optparse.parse!
  mandatory = [:file]
  missing = mandatory.select{ |param| options[param].nil? }
  if not missing.empty?
    puts putserror+" Missing options: #{missing.join(', ')}"
    exit 1 
  end
rescue OptionParser::InvalidOption, OptionParser::MissingArgument, OptionParser::InvalidArgument
  puts putserror+' '+$!.to_s
  exit 1
end

begin
  config = JSON.parse(File.open(options[:file],'r').read, :symbolize_names => true)
rescue
  puts putserror+" Can\'t parse file #{options[:file]}"
  exit 1
end

config[:nodes].each do |key,value|
  if not value[:mac] =~ /^([0-9A-F]{2}[:-]){5}([0-9A-F]{2})$/
    puts putserror+' Wrong '+putscyan(key.to_s)+' mac address format.'
    exit 1
  end
end

puts "Razor provision:"
config[:nodes].each do |key,value|
  if value[:hostname].split('.').length > 1
    print "- fqdn: #{putscyan(value[:hostname])}"
    print ", ip: #{putscyan(value[:ip])}"
    print ", mac: #{putscyan(value[:mac])}\n"
  else
    print "- fqdn: #{putscyan(value[:hostname])} - not fqdn #{putswarning}"
    print ", ip: #{putscyan(value[:ip])}"
    print ", mac: #{putscyan(value[:mac])}\n"
  end
end
puts
puts "- os: #{putscyan(config[:os])}"
puts "- chef environment: #{putscyan(config[:environment])}"
puts "- chef base role: #{putscyan(config[:baserole])}"
puts 

yesno

print 'Configure dnsmasq...'
regexp_array = []
config[:nodes].each do |key,value|
  regexp_array << value[:mac].downcase
end

if File::exists?(options[:dnsmasq])
  lines = IO.readlines(options[:dnsmasq]).map { |line| line if line !~ /#{regexp_array.join('|')}/ }
  config[:nodes].each do |key,value|
    lines << value[:mac].downcase+',set:razor,'+value[:ip]+','+value[:hostname]
  end
  File.open(options[:dnsmasq], 'w') do |file|
    file.puts lines.compact
  end
  puts 'done ' + putsok
else
  puts "...can't open file '#{putscyan(options[:dnsmasq])}' "+ putserror
  exit 1
end

print 'Checking model...'
if model_uuid = get_object_uuid(razor_api,'model','label',config[:os])
  puts '...model exists '+putsok
else
  puts "...model #{putscyan(config[:os])} doesn't exist in razor "+ putserror
  exit 1
end

#gen broker string
broker_string = "#{config[:environment]}-#{config[:baserole]}"
print 'Checking broker...'
if broker_uuid = get_object_uuid(razor_api,'broker','name',broker_string)
  puts '...broker exists '+putsok
else
  puts "...broker #{putscyan(broker_string)} doesn't exist in razor "+ putserror
  exit 1
end

config[:nodes].each do |key,value|
  if tag_uuid = get_object_uuid(razor_api,'tag','name',value[:hostname])
    # remove existing tags
    tag_uuid.each do |uuid|
      delete_object(razor_api,'tag',uuid)
    end
  end

  if policy_uuid = get_object_uuid(razor_api,'policy','label',value[:hostname])
    # delete policy
    policy_uuid.each do |uuid|
      delete_object(razor_api,'policy',uuid)
    end
  end

  if active_model_uuid = get_object_uuid(razor_api,'active_model','label',value[:hostname])
  # delete policy
    active_model_uuid.each do |uuid|
      delete_object(razor_api,'active_model',uuid)
    end
  end
   
  # create tag
  tag_name = value[:hostname].gsub(/\./,'_')
  puts
  #%w{s s_eth0 s_eth1}.each do |key|
  %w{s s_eth0 s_eth1 s_eth2 s_eth3}.each do |key|
    print "Creating tag..."
    json_hash = {"name" => value[:hostname], "tag" => tag_name }
    tag_uuid = create_object(razor_api,'tag',json_hash)
    print "...tag '#{putscyan(tag_name)}' created with UUDI '#{putscyan(tag_uuid)}'"
    json_hash = { 
      "key"     => "macaddres"+key,
      "compare" => "equal",
      "value"   => value[:mac],
      "invert"  => "false"
    }
    create_object(razor_api,"tag/#{tag_uuid}/matcher",json_hash)
    puts " and matcher '#{putscyan('macaddres'+key)}' => '#{putscyan(value[:mac])}' #{putsok}"
  end

  # create policy
  puts
  print "Creating policy..."
  json_hash = {
    "model_uuid"  => model_uuid[0],
    "broker_uuid" => broker_uuid[0],
    "label"       => value[:hostname],
    "tags"        => tag_name,
    "template"    => "linux_deploy",
    "maximum"     => "1",
    "enabled"     => "true"
  }
  policy_uuid = create_object(razor_api,'policy',json_hash)
  puts "...policy '#{putscyan(value[:hostname])}' created with UUDI '#{putscyan(policy_uuid)}' #{putsok}"
end
puts
puts "Razor prepared, please restart nodes and boot them using PXE."
puts "Dnsmasq prepared, please run: #{putscyan('dnsmasq --test && killall -SIGHUP dnsmasq')}"

exit 0
